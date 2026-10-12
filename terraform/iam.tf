locals {
  dns_enabled = var.domain_name != null
}

data "aws_route53_zone" "main" {
  count        = local.dns_enabled ? 1 : 0
  name         = var.domain_name
  private_zone = false
}

# The lab account cannot create IAM roles, so the frontend uses the
# lab-provided profile that grants certbot its Route 53 permissions.
data "aws_iam_instance_profile" "frontend" {
  name = var.frontend_instance_profile
}
