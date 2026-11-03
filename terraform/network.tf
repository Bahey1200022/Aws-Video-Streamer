data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_subnet" "public" {
  vpc_id = data.aws_vpc.main.id

  filter {
    name   = "tag:Name"
    values = [var.public_subnet_name]
  }
}

data "aws_subnet" "private" {
  vpc_id = data.aws_vpc.main.id

  filter {
    name   = "tag:Name"
    values = [var.private_subnet_name]
  }
}

data "http" "my_ip" {
  count = var.admin_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  admin_cidr = coalesce(var.admin_cidr, "${trimspace(try(data.http.my_ip[0].response_body, ""))}/32")
}

# The private subnet has NO route to the internet: no NAT, no route table of
# its own. It uses the VPC's main route table, which only knows the VPC itself
# (192.168.0.0/16). The streamer can therefore only talk to the frontend.
