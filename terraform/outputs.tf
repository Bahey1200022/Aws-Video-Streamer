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

output "stream_url" {
  value = "${var.enable_tls && local.dns_enabled ? "https" : "http"}://${try(aws_route53_record.frontend[0].fqdn, local.frontend_public_ip)}/"
}
