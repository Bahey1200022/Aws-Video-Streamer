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

# The private subnet reaches the internet through the frontend instance (NAT instance)
resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.main.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.frontend.primary_network_interface_id
  }

  tags = { Name = "mss-private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = data.aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
