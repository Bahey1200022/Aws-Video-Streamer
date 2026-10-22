locals {
  ansible_dir = abspath("${path.module}/../ansible")
  studio_dir  = abspath("${path.module}/../studio")
  studio_sources = sort([
    for f in fileset(local.studio_dir, "**") : f if !strcontains(f, "__pycache__")
  ])
  # The generated inventory is deliberately excluded (it is tracked via local_file)
  ansible_sources = sort(concat(
    ["site.yml", "ansible.cfg"],
    tolist(fileset(local.ansible_dir, "templates/*")),
    tolist(fileset(local.ansible_dir, "group_vars/*")),
  ))
}

resource "local_file" "inventory" {
  filename = "${local.ansible_dir}/inventory.yml"
  content = templatefile("${path.module}/inventory.yml.tftpl", {
    key_file              = abspath(local_sensitive_file.ssh_private_key.filename)
    fqdn                  = local.dns_enabled ? "${var.frontend_hostname}.${var.domain_name}" : "_"
    private_cidr          = data.aws_subnet.private.cidr_block
    vpc_cidr              = data.aws_vpc.main.cidr_block
    frontend_private_ip   = aws_instance.frontend.private_ip
    frontend_public_ip    = local.frontend_public_ip
    streamer_private_ip   = aws_instance.streamer.private_ip
    enable_tls            = var.enable_tls && local.dns_enabled
    letsencrypt_staging   = var.letsencrypt_staging
    stream_key            = random_password.stream_key.result
    studio_admin_password = random_password.studio_admin.result
    studio_secret_key     = random_password.studio_secret_key.result
    link_secret           = random_password.link_secret.result
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
    sha1(join("", [for f in local.studio_sources : filesha1("${local.studio_dir}/${f}")])),
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
    aws_ec2_instance_state.streamer,
    aws_route53_record.frontend,
  ]
}
