resource "aws_security_group" "frontend" {
  # checkov:skip=CKV_AWS_260: public website - port 80 must stay open: it redirects to HTTPS and serves Let's Encrypt HTTP-01 challenges
  name        = "mss-frontend"
  description = "Web frontend"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Camera ingest: the phone pushes RTMP over TLS from any network (its public
  # IP changes constantly on mobile data). Only the "camera" channel with its
  # key is accepted; TLS uses the site's Let's Encrypt certificate.
  dynamic "ingress" {
    for_each = var.camera_enabled ? [1] : []
    content {
      description = "RTMPS camera ingest (TLS, camera stream key required)"
      from_port   = 1936
      to_port     = 1936
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  ingress {
    description = "WireGuard tunnel from the streamer (carries the RTMP ingest)"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = [data.aws_subnet.private.cidr_block]
  }

  # The frontend is the streamer's NAT: its outbound web traffic (apt) passes
  # through here, so these rules are about forwarded traffic, not services
  ingress {
    description = "Streamer HTTP via NAT"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_subnet.private.cidr_block]
  }

  ingress {
    description = "Streamer HTTPS via NAT"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_subnet.private.cidr_block]
  }

  ingress {
    description = "SSH from admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  # Egress is limited to what the frontend needs, so a compromised process
  # can't reach out on arbitrary ports. Amazon DNS, NTP and the metadata
  # service are not filtered by security groups.
  egress {
    description = "HTTP out: apt, plus forwarded (NAT) traffic of the streamer"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS out: apt, Lets Encrypt, plus forwarded (NAT) traffic of the streamer"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "SSH to the streamer (Ansible jump host)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [data.aws_subnet.private.cidr_block]
  }
}

resource "aws_security_group" "streamer" {
  name        = "mss-streamer"
  description = "Video streamer (private)"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "SSH from frontend (jump host)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  egress {
    description = "WireGuard tunnel to the frontend"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = [data.aws_subnet.public.cidr_block]
  }

  egress {
    description = "HTTP out via the frontend NAT (apt)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS out via the frontend NAT (apt)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
