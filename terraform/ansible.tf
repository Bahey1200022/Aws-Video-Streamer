locals {
  ansible_dir = abspath("${path.module}/../ansible")
  # The generated inventory is deliberately excluded (it is tracked via local_file)
  ansible_sources = sort(concat(
    ["site.yml", "ansible.cfg"],
    tolist(fileset(local.ansible_dir, "templates/*")),
  ))
}

resource "local_file" "inventory" {
  filename = "${local.ansible_dir}/inventory.yml"
  content = templatefile("${path.module}/inventory.yml.tftpl", {
    key_file            = abspath(local_sensitive_file.ssh_private_key.filename)
    fqdn                = local.dns_enabled ? "${var.frontend_hostname}.${var.domain_name}" : "_"
    private_cidr        = data.aws_subnet.private.cidr_block
    vpc_cidr            = data.aws_vpc.main.cidr_block
    frontend_private_ip = aws_instance.frontend.private_ip
    frontend_public_ip  = aws_instance.frontend.public_ip
    streamer_private_ip = aws_instance.streamer.private_ip
    enable_tls          = var.enable_tls && local.dns_enabled
    letsencrypt_staging = var.letsencrypt_staging
  })
}

# Runs the Ansible playbook as part of `terraform apply`. Re-runs whenever an
# instance is replaced or the inventory/playbook/templates change.
resource "terraform_data" "ansible" {
  triggers_replace = [
    aws_instance.frontend.id,
    aws_instance.streamer.id,
    local_file.inventory.content,
    sha1(join("", [for f in local.ansible_sources : filesha1("${local.ansible_dir}/${f}")])),
  ]

  provisioner "local-exec" {
    working_dir = local.ansible_dir
    command     = "ansible-playbook site.yml"
    environment = {
      ANSIBLE_CONFIG      = "${local.ansible_dir}/ansible.cfg"
      ANSIBLE_FORCE_COLOR = "1"
      PYTHONUNBUFFERED    = "1"
    }
  }

  depends_on = [
    aws_route_table_association.private, # streamer needs the NAT route to install packages
    aws_route53_record.frontend,
  ]
}
