output "frontend_public_ip" {
  value = local.frontend_public_ip
}

output "streamer_private_ip" {
  value = aws_instance.streamer.private_ip
}

output "frontend_fqdn" {
  value = try(aws_route53_record.frontend[0].fqdn, null)
}

output "ssh_frontend" {
  value = "ssh -i ${local_sensitive_file.ssh_private_key.filename} ubuntu@${local.frontend_public_ip}"
}

output "stream_key" {
  value     = random_password.stream_key.result
  sensitive = true
}

output "phone_stream_key" {
  value     = var.enable_phone_camera ? random_password.phone_stream_key.result : null
  sensitive = true
}

output "stream_url" {
  value = "${var.enable_tls && local.dns_enabled ? "https" : "http"}://${try(aws_route53_record.frontend[0].fqdn, local.frontend_public_ip)}/"
}

# The phone app's WHIP address (user "phone"; password below)
output "webrtc_whip_url" {
  value = var.enable_webrtc ? "https://${try(aws_route53_record.frontend[0].fqdn, local.frontend_public_ip)}/phone/whip" : null
}

output "webrtc_password" {
  value     = var.enable_webrtc ? random_password.webrtc_publish.result : null
  sensitive = true
}

output "monitoring_private_ip" {
  value = try(aws_instance.monitoring[0].private_ip, null)
}

# Opens Grafana on http://localhost:3000 through the frontend (jump host)
output "grafana_tunnel" {
  # ProxyCommand rather than -J: -J would not use the key for the hop
  # through the frontend
  value = try("ssh -i ${local_sensitive_file.ssh_private_key.filename} -o ProxyCommand=\"ssh -i ${local_sensitive_file.ssh_private_key.filename} -W %h:%p ubuntu@${local.frontend_public_ip}\" -N -L 3000:localhost:3000 ubuntu@${aws_instance.monitoring[0].private_ip}", null)
}

output "grafana_admin_password" {
  value     = local.monitoring_enabled ? local.grafana_admin_password : null
  sensitive = true
}

# Lookups the DNS Firewall alerted on or blocked, in the last hour (needs the
# AWS CLI with this account's credentials)
output "dns_firewall_log" {
  value = local.dns_firewall_on ? "aws logs tail /mss/dns-queries --region ${var.aws_region} --since 1h --format short --filter-pattern '{ $.firewall_rule_action = \"ALERT\" || $.firewall_rule_action = \"BLOCK\" }'" : null
}

# The CloudFront address the site's name points to (var.waf)
output "cloudfront_domain" {
  value = try(aws_cloudfront_distribution.site[0].domain_name, null)
}

# The name that points straight at the frontend (phone WireGuard endpoint)
output "frontend_direct_fqdn" {
  value = try(aws_route53_record.frontend_direct[0].fqdn, null)
}

# Requests the WAF counted or blocked, in the last hour: which rule matched
# (terminatingRuleId / nonTerminatingMatchingRules), the client IP and the URI
output "waf_log" {
  value = local.cloudfront_on ? "aws logs tail aws-waf-logs-mss --region ${var.aws_region} --since 1h --format short" : null
}
