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
  description = "Request a Let's Encrypt certificate and serve the site over HTTPS (see acme_challenge)"
  type        = bool
  default     = false
}

variable "acme_challenge" {
  description = <<-EOT
    How Let's Encrypt verifies we control the domain:
    "dns"  - DNS-01: a TXT record in Route 53 (the lab design; needs the instance profile to allow changes in the hosted zone)
    "http" - HTTP-01: a file served by nginx on port 80 (no AWS permissions needed)
  EOT
  type        = string
  default     = "dns"

  validation {
    condition     = contains(["dns", "http"], var.acme_challenge)
    error_message = "acme_challenge must be \"dns\" or \"http\"."
  }
}

variable "letsencrypt_staging" {
  description = "Use the Let's Encrypt staging CA (untrusted certs, but no rate limits) - useful while rebuilding often"
  type        = bool
  default     = false
}

# ---- IP camera (phone pushing RTMPS, e.g. Larix Broadcaster) ----
variable "camera_enabled" {
  description = "Accept a camera pushing RTMPS on port 1936 and publish it as the password-protected 'camera' channel (needs enable_tls)"
  type        = bool
  default     = false
}

# ---- Live weather next to the video (OpenWeatherMap) ----
variable "openweather_api_key" {
  description = "OpenWeatherMap API key - put it in the git-ignored secrets.auto.tfvars. Empty disables the weather widget."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.openweather_api_key == "" || can(regex("^[0-9a-f]{32}$", var.openweather_api_key))
    error_message = "An OpenWeatherMap API key is 32 lowercase hex characters."
  }
}
