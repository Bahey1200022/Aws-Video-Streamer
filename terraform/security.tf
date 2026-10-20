resource "aws_security_group" "frontend" {
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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
