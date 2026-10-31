aws_region = "us-east-1"
vpc_id     = "vpc-078f4e15dadc5b2ee"

# Lab-provided hosted zone (shared with other students, so keep the hostname unique)
domain_name       = "devops.gin-telecom.ovh"
frontend_hostname = "bahey"

# HTTPS: DNS-01 (the lab design) is blocked by the lab's IAM policy, so use
# HTTP-01. (Set letsencrypt_staging = true to test without rate limits.)
enable_tls          = true
acme_challenge      = "http"
letsencrypt_staging = false
