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

output "stream_url" {
  value = "${var.enable_tls && local.dns_enabled ? "https" : "http"}://${try(aws_route53_record.frontend[0].fqdn, local.frontend_public_ip)}/"
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
  value     = try(random_password.grafana_admin[0].result, null)
  sensitive = true
}
