# DNS Firewall: the servers may only look up the domain names they need.
#
# Security groups don't filter the Amazon DNS resolver, so before this a
# compromised server could still leak data by hiding it in DNS lookups
# ("<secret>.attacker.example" reaches the attacker's DNS server). These rules
# run inside the VPC's resolver: names on the allowlist resolve, everything
# else is logged ("alert") or refused ("block"). See var.dns_firewall.
#
# The rules apply to the whole VPC, so the allowlist covers the frontend too.

locals {
  dns_firewall_on = var.dns_firewall != "off"

  dns_allowed_domains = concat(
    [
      # Ubuntu packages, security updates, NTP (ntp.ubuntu.com). The private
      # servers don't resolve these themselves (the package proxy on the
      # frontend does), but the frontend does
      "ubuntu.com",
      "*.ubuntu.com",
      # Let's Encrypt (certbot on the frontend)
      "*.letsencrypt.org",
      # MediaMTX releases, downloaded by the frontend
      "github.com",
      "*.githubusercontent.com",
      # AWS endpoints: the Route 53 API (certbot DNS-01) and other services.
      # Nobody outside AWS controls these names' DNS servers, so they can't
      # be used to smuggle data out
      "*.amazonaws.com",
      # The VPC's own host names (ip-192-168-x-x.ec2.internal) and reverse
      # lookups of private addresses
      "*.internal",
      "*.in-addr.arpa",
    ],
    # The site's own name
    local.dns_enabled ? [var.domain_name, "*.${var.domain_name}"] : [],
  )
}

resource "aws_route53_resolver_firewall_domain_list" "allowed" {
  count   = local.dns_firewall_on ? 1 : 0
  name    = "mss-allowed"
  domains = local.dns_allowed_domains
}

# "*" matches every name: the catch-all for whatever isn't allowed above
resource "aws_route53_resolver_firewall_domain_list" "everything" {
  count   = local.dns_firewall_on ? 1 : 0
  name    = "mss-everything"
  domains = ["*"]
}

resource "aws_route53_resolver_firewall_rule_group" "mss" {
  count = local.dns_firewall_on ? 1 : 0
  name  = "mss-dns-allowlist"
}

# Rules run in priority order, lowest first; the first match wins
resource "aws_route53_resolver_firewall_rule" "allow" {
  count                   = local.dns_firewall_on ? 1 : 0
  name                    = "allow-needed-domains"
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.mss[0].id
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.allowed[0].id
  priority                = 100
  action                  = "ALLOW"
}

resource "aws_route53_resolver_firewall_rule" "everything_else" {
  count                   = local.dns_firewall_on ? 1 : 0
  name                    = "everything-else"
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.mss[0].id
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.everything[0].id
  priority                = 200
  # ALERT: answer normally, but log the lookup. BLOCK: answer "no such data"
  action         = var.dns_firewall == "block" ? "BLOCK" : "ALERT"
  block_response = var.dns_firewall == "block" ? "NODATA" : null
}

resource "aws_route53_resolver_firewall_rule_group_association" "mss" {
  count                  = local.dns_firewall_on ? 1 : 0
  name                   = "mss-vpc"
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.mss[0].id
  vpc_id                 = data.aws_vpc.main.id
  priority               = 101
}

# ---- Query log: every lookup and what the firewall did with it ----
# Needed to see what "alert" mode would have blocked before switching to
# "block". Read it with the command in `terraform output dns_firewall_log`.

resource "aws_cloudwatch_log_group" "dns" {
  # checkov:skip=CKV_AWS_158: encrypted by CloudWatch Logs' own keys; using our KMS key would mean adding the Logs service to the EBS key's policy for a 7-day lab log
  # checkov:skip=CKV_AWS_338: a 7-day troubleshooting log for the allowlist, not an audit record that must be kept for a year
  count             = local.dns_firewall_on ? 1 : 0
  name              = "/mss/dns-queries"
  retention_in_days = 7
}

resource "aws_route53_resolver_query_log_config" "dns" {
  count           = local.dns_firewall_on ? 1 : 0
  name            = "mss-dns-queries"
  destination_arn = aws_cloudwatch_log_group.dns[0].arn
}

resource "aws_route53_resolver_query_log_config_association" "dns" {
  count                        = local.dns_firewall_on ? 1 : 0
  resolver_query_log_config_id = aws_route53_resolver_query_log_config.dns[0].id
  resource_id                  = data.aws_vpc.main.id
}
