# Monitoring server: Prometheus (metrics), Loki (logs) and Grafana (dashboards
# and alerts). Private subnet, no public IP, no internet: Grafana is reached
# through an SSH tunnel via the frontend. See docs/MONITORING-PLAN.md.

locals {
  monitoring_enabled = var.enable_monitoring
  # 0 or 1 security-group IDs, for the rules the frontend and streamer groups
  # add toward the monitoring server (dynamic blocks in security.tf)
  monitoring_sg_ids = aws_security_group.monitoring[*].id
}

# This group only refers to subnet ranges, never to the other security groups,
# so the frontend and streamer groups can refer to it without a dependency loop
resource "aws_security_group" "monitoring" {
  count       = local.monitoring_enabled ? 1 : 0
  name        = "mss-monitoring"
  description = "Monitoring server (private): Prometheus, Loki, Grafana"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "SSH from the frontend (Ansible jump host, Grafana tunnel)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [data.aws_subnet.public.cidr_block]
  }

  ingress {
    description = "Loki: logs pushed by the agents on the frontend and streamer"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [data.aws_subnet.public.cidr_block, data.aws_subnet.private.cidr_block]
  }

  egress {
    description = "Prometheus scrapes node_exporter on the frontend and streamer"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [data.aws_subnet.public.cidr_block, data.aws_subnet.private.cidr_block]
  }

  egress {
    description = "Blackbox probes of the website (HTTPS, over the private network)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_subnet.public.cidr_block]
  }

  egress {
    description = "Package proxy (apt-cacher-ng) on the frontend"
    from_port   = 3142
    to_port     = 3142
    protocol    = "tcp"
    cidr_blocks = [data.aws_subnet.public.cidr_block]
  }
}

resource "aws_instance" "monitoring" {
  # checkov:skip=CKV2_AWS_41: the monitoring server needs no AWS API access - attaching a role would add privilege (least privilege)
  # checkov:skip=CKV_AWS_126: detailed (1-minute) monitoring is a paid CloudWatch feature not needed for this lab
  # checkov:skip=CKV_AWS_135: t3 instances are EBS-optimized by default (Nitro); setting the flag forces a stop/start
  count                  = local.monitoring_enabled ? 1 : 0
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.monitoring_instance_type
  subnet_id              = data.aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.monitoring[0].id]
  key_name               = aws_key_pair.mss.key_name

  # IMDSv2 only, as on the other servers
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # 20 GB for 15 days of metrics and logs, encrypted with our KMS key
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.ebs.arn
  }

  tags = { Name = "mss-monitoring" }

  lifecycle {
    # A newer Ubuntu image must not rebuild a running server
    ignore_changes = [ami]
  }
}

# Started again after the lab's nightly shutdown, like the other servers
resource "aws_ec2_instance_state" "monitoring" {
  count       = local.monitoring_enabled ? 1 : 0
  instance_id = aws_instance.monitoring[0].id
  state       = "running"
}

# Grafana's admin password: generated, never written by hand or stored in git
resource "random_password" "grafana_admin" {
  count   = local.monitoring_enabled ? 1 : 0
  length  = 24
  special = false
}
