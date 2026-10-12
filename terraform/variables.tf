variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_id" {
  description = "ID of the existing VPC to deploy into"
  type        = string
}

variable "public_subnet_name" {
  description = "Name tag of the existing public subnet"
  type        = string
  default     = "bahey-subnet-public"
}

variable "private_subnet_name" {
  description = "Name tag of the existing private subnet"
  type        = string
  default     = "bahey-subnet-private"
}

variable "domain_name" {
  description = "Existing Route 53 hosted zone name, e.g. example.com. Leave null to skip DNS/TLS."
  type        = string
  default     = null
}

variable "frontend_hostname" {
  description = "Record to create in the hosted zone for the web frontend"
  type        = string
  default     = "devops"
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH to the frontend. Leave null to auto-detect this machine's public IP."
  type        = string
  default     = null
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "frontend_instance_profile" {
  description = "Existing IAM instance profile giving the frontend Route 53 access for certbot"
  type        = string
  default     = "r53-devops"
}

variable "enable_tls" {
  description = "Request a Let's Encrypt certificate via DNS-01. Needs the instance profile to allow changes in the hosted zone."
  type        = bool
  default     = false
}

variable "letsencrypt_staging" {
  description = "Use the Let's Encrypt staging CA (untrusted certs, but no rate limits) - useful while rebuilding often"
  type        = bool
  default     = false
}
