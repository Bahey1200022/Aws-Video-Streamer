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

  ingress {
    description = "WireGuard tunnel from the streamer (carries the RTMP ingest)"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = [data.aws_subnet.private.cidr_block]
  }

  # Phone camera (enable_phone_camera): the phone's address changes with the
  # network (4G, Wi-Fi), so WireGuard is open to the internet. WireGuard
  # never answers a packet that isn't signed with a known key, so to anyone
  # else the port looks closed
  dynamic "ingress" {
    for_each = var.enable_phone_camera ? [1] : []
    content {
      description = "WireGuard tunnel from the phone camera (any network)"
      from_port   = 51820
      to_port     = 51820
      protocol    = "udp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # The streamer has no internet access: it gets Ubuntu packages and security
  # updates from the package proxy (apt-cacher-ng) running on the frontend
  ingress {
    description = "Package proxy (apt-cacher-ng) for the streamer"
    from_port   = 3142
    to_port     = 3142
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

  # WebRTC media (enable_webrtc): phones and viewers are anywhere, so this
  # is open to the internet. Only encrypted media flows here (DTLS-SRTP), and
  # only after a handshake over HTTPS (443) that nginx forwards to MediaMTX
  dynamic "ingress" {
    for_each = var.enable_webrtc ? [1] : []
    content {
      description = "WebRTC media (MediaMTX): phone camera and real-time viewers"
      from_port   = 8189
      to_port     = 8189
      protocol    = "udp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # Monitoring (only when enable_monitoring = true): Prometheus scrapes
  # node_exporter here; Alloy pushes this server's logs to Loki
  dynamic "ingress" {
    for_each = local.monitoring_sg_ids
    content {
      description     = "node_exporter scraped by Prometheus (monitoring server)"
      from_port       = 9100
      to_port         = 9100
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  # MediaMTX's metrics (WebRTC sessions, bytes), scraped by Prometheus
  dynamic "ingress" {
    for_each = var.enable_webrtc ? local.monitoring_sg_ids : []
    content {
      description     = "MediaMTX metrics scraped by Prometheus (monitoring server)"
      from_port       = 9998
      to_port         = 9998
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  # Egress is limited to what the frontend needs, so a compromised process
  # can't reach out on arbitrary ports. Amazon DNS, NTP and the metadata
  # service are not filtered by security groups.
  egress {
    description = "HTTP out: apt, and the package proxy fetching for the streamer"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS out: apt, Lets Encrypt, and the package proxy"
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

  dynamic "egress" {
    for_each = local.monitoring_sg_ids
    content {
      description     = "Logs pushed to Loki (monitoring server)"
      from_port       = 3100
      to_port         = 3100
      protocol        = "tcp"
      security_groups = [egress.value]
    }
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

  dynamic "ingress" {
    for_each = local.monitoring_sg_ids
    content {
      description     = "node_exporter scraped by Prometheus (monitoring server)"
      from_port       = 9100
      to_port         = 9100
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  egress {
    description = "WireGuard tunnel to the frontend"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = [data.aws_subnet.public.cidr_block]
  }

  # The streamer may only talk to the frontend (and send its logs to the
  # monitoring server): no internet at all
  egress {
    description = "Package proxy on the frontend (apt-cacher-ng)"
    from_port   = 3142
    to_port     = 3142
    protocol    = "tcp"
    cidr_blocks = [data.aws_subnet.public.cidr_block]
  }

  dynamic "egress" {
    for_each = local.monitoring_sg_ids
    content {
      description     = "Logs pushed to Loki (monitoring server)"
      from_port       = 3100
      to_port         = 3100
      protocol        = "tcp"
      security_groups = [egress.value]
    }
  }
}
