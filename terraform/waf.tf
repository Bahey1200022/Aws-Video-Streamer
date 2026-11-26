# CloudFront + AWS WAF in front of the website.
#
#   viewer --HTTPS--> CloudFront (edge) + WAF --HTTPS--> frontend nginx
#
# AWS WAF can't be attached to an EC2 instance, only to CloudFront, a load
# balancer or API Gateway, so the site's name now points at a CloudFront
# distribution and the WAF checks every web request there. See var.waf and
# docs/CLOUDFRONT-WAF.md.
#
# Only HTTP(S) goes through CloudFront. WebRTC media (UDP 8189), WireGuard
# (UDP 51820) and SSH still go straight to the frontend, through a second name
# that always points at its IP (local.direct_fqdn).
#
# The frontend's ports 80/443 then only accept CloudFront's addresses, and
# nginx also requires a secret header that only our distribution adds:
# otherwise anyone could reach the server through their own CloudFront
# distribution and skip our WAF.

locals {
  waf_block = var.waf == "block"
  # Let's Encrypt HTTP-01 challenges reach the frontend through CloudFront on
  # plain HTTP (port 80); with DNS-01 port 80 isn't needed at all
  cloudfront_acme_http = local.cloudfront_on && var.acme_challenge == "http"
}

# ---- Who may reach the frontend's web ports ----

# CloudFront's origin-facing addresses, kept up to date by AWS
data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = local.cloudfront_on ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

# The prefix list counts as ~52 rules, and a security group holds 60, so each
# port gets a group of its own (an instance can have 5 groups)
resource "aws_security_group" "cloudfront_https" {
  count       = local.cloudfront_on ? 1 : 0
  name        = "mss-frontend-cloudfront-https"
  description = "HTTPS from CloudFront only (the website, after the WAF)"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "HTTPS from CloudFront"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront[0].id]
  }
  # No egress rules: replies are allowed anyway (security groups are
  # stateful), and the frontend group keeps deciding what may go out
}

resource "aws_security_group" "cloudfront_http" {
  count       = local.cloudfront_acme_http ? 1 : 0
  name        = "mss-frontend-cloudfront-http"
  description = "HTTP from CloudFront only (Lets Encrypt HTTP-01 challenges)"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "HTTP from CloudFront (Lets Encrypt challenges)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront[0].id]
  }
}

# Sent by CloudFront to the frontend on every request; nginx refuses requests
# without it (except from inside the VPC, e.g. the monitoring probes)
resource "random_password" "origin_verify" {
  count   = local.cloudfront_on ? 1 : 0
  length  = 32
  special = false
}

# ---- HTTPS certificate for CloudFront (ACM, free, renewed by AWS) ----
# The frontend keeps its Let's Encrypt certificate for the CloudFront ->
# frontend leg; CloudFront checks it against the site's name (Host header)

resource "aws_acm_certificate" "site" {
  count             = local.cloudfront_on ? 1 : 0
  domain_name       = local.frontend_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "site_cert_validation" {
  for_each = {
    for o in flatten(aws_acm_certificate.site[*].domain_validation_options) : o.domain_name => o
  }
  zone_id         = data.aws_route53_zone.main[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  count                   = local.cloudfront_on ? 1 : 0
  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.site_cert_validation : r.fqdn]
}

# ---- The CloudFront distribution ----

# AWS-managed policies: no caching, and forward everything the viewer sent
# (including Host, which nginx and the certificate check need)
data "aws_cloudfront_cache_policy" "disabled" {
  count = local.cloudfront_on ? 1 : 0
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  count = local.cloudfront_on ? 1 : 0
  name  = "Managed-AllViewer"
}

# Live video: playlists change every few seconds, so keep copies for 1 second
# unless nginx says otherwise (DASH sends no-cache, which CloudFront obeys).
# Even 1 second turns many viewers into one request to the frontend
resource "aws_cloudfront_cache_policy" "live_media" {
  count       = local.cloudfront_on ? 1 : 0
  name        = "mss-live-media"
  comment     = "MSS HLS/DASH: very short cache for live playlists and segments"
  min_ttl     = 0
  default_ttl = 1
  max_ttl     = 60

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_distribution" "site" {
  # checkov:skip=CKV_AWS_86: CloudFront access logs need an S3 bucket; the WAF log below records the requests that matter (counted/blocked) for this lab
  # checkov:skip=CKV_AWS_310: there is a single frontend server, so there is no second origin to fail over to
  # checkov:skip=CKV_AWS_374: viewers may watch from any country
  # checkov:skip=CKV2_AWS_32: nginx already sets the security headers (HSTS kept to one day on purpose, see streamer.site.j2)
  count               = local.cloudfront_on ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  comment             = "MSS website (AWS WAF in front of the frontend)"
  aliases             = [local.frontend_fqdn]
  default_root_object = "index.html"
  web_acl_id          = aws_wafv2_web_acl.site[0].arn
  # Edge locations in North America and Europe only: the cheapest class
  price_class = "PriceClass_100"

  origin {
    origin_id   = "frontend"
    domain_name = local.direct_fqdn

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify[0].result
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Same server, plain HTTP: only for Let's Encrypt's HTTP-01 challenges,
  # which must be answered on port 80
  dynamic "origin" {
    for_each = local.cloudfront_acme_http ? [1] : []
    content {
      origin_id   = "frontend-acme"
      domain_name = local.direct_fqdn

      custom_header {
        name  = "X-Origin-Verify"
        value = random_password.origin_verify[0].result
      }

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  # Everything else (player page, WebRTC handshakes): never cached, every
  # method allowed (WHIP/WHEP use POST, PATCH and DELETE)
  default_cache_behavior {
    target_origin_id         = "frontend"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
    compress                 = true
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.cloudfront_acme_http ? [1] : []
    content {
      path_pattern             = "/.well-known/acme-challenge/*"
      target_origin_id         = "frontend-acme"
      viewer_protocol_policy   = "allow-all"
      allowed_methods          = ["GET", "HEAD"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = data.aws_cloudfront_cache_policy.disabled[0].id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = ["/hls/*", "/dash/*"]
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = "frontend"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = aws_cloudfront_cache_policy.live_media[0].id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
      compress                 = true
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ---- The WAF ----
# Rules run in priority order, lowest first. In "count" mode a matching rule
# only logs the request; in "block" mode it answers 403

resource "aws_wafv2_web_acl" "site" {
  count       = local.cloudfront_on ? 1 : 0
  name        = "mss-site"
  description = "MSS website: AWS managed rules and per-IP rate limits"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Addresses AWS has seen attacking (botnets, scanners)
  rule {
    name     = "ip-reputation"
    priority = 10

    override_action {
      dynamic "none" {
        for_each = local.waf_block ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.waf_block ? [] : [1]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "mss-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # A WebRTC handshake is 1-3 requests: 100 in 5 minutes from one address is
  # someone hammering the publish/watch endpoints (e.g. guessing the password)
  rule {
    name     = "rate-limit-handshakes"
    priority = 20

    action {
      dynamic "block" {
        for_each = local.waf_block ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.waf_block ? [] : [1]
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/phone/"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "mss-rate-limit-handshakes"
      sampled_requests_enabled   = true
    }
  }

  # A video player makes about one request a second (playlist + segment), so
  # 3000 in 5 minutes leaves room for ~10 viewers behind one address
  rule {
    name     = "rate-limit-all"
    priority = 30

    action {
      dynamic "block" {
        for_each = local.waf_block ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.waf_block ? [] : [1]
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = 3000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "mss-rate-limit-all"
      sampled_requests_enabled   = true
    }
  }

  # OWASP-style attacks: cross-site scripting, path traversal, local file
  # inclusion, requests for the metadata service (SSRF)...
  rule {
    name     = "common"
    priority = 40

    override_action {
      dynamic "none" {
        for_each = local.waf_block ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.waf_block ? [] : [1]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        # This rule refuses bodies over 8 KB, and a WebRTC offer (SDP) can be
        # bigger. nginx already caps the handshake body at 64 KB
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "mss-common"
      sampled_requests_enabled   = true
    }
  }

  # Payloads of known exploits (Log4Shell, Java deserialization...)
  rule {
    name     = "known-bad-inputs"
    priority = 50

    override_action {
      dynamic "none" {
        for_each = local.waf_block ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = local.waf_block ? [] : [1]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "mss-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "mss-site"
    sampled_requests_enabled   = true
  }
}

# ---- WAF log: the requests a rule counted or blocked ----
# Read it with the command in `terraform output waf_log`. Allowed requests
# aren't logged (that would be every video segment)

resource "aws_cloudwatch_log_group" "waf" {
  # checkov:skip=CKV_AWS_158: encrypted by CloudWatch Logs' own keys; using our KMS key would mean adding the Logs service to the EBS key's policy for a 7-day lab log
  # checkov:skip=CKV_AWS_338: a 7-day log for tuning the WAF rules, not an audit record that must be kept for a year
  count = local.cloudfront_on ? 1 : 0
  # WAF only writes to log groups whose name starts with aws-waf-logs-
  name              = "aws-waf-logs-mss"
  retention_in_days = 7
}

# Lets the AWS log delivery service write the WAF's records into the group
resource "aws_cloudwatch_log_resource_policy" "waf" {
  count       = local.cloudfront_on ? 1 : 0
  policy_name = "mss-waf-logs"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.waf[0].arn}:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })
}

resource "aws_wafv2_web_acl_logging_configuration" "site" {
  count                   = local.cloudfront_on ? 1 : 0
  resource_arn            = aws_wafv2_web_acl.site[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # The phone's WebRTC password travels in this header: keep it out of logs
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  logging_filter {
    default_behavior = "DROP"

    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"
      condition {
        action_condition {
          action = "BLOCK"
        }
      }
      condition {
        action_condition {
          action = "COUNT"
        }
      }
      condition {
        action_condition {
          action = "EXCLUDED_AS_COUNT"
        }
      }
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}
