# Customer-managed KMS key for the servers' disks (encryption at rest).
# The key material never leaves KMS; EC2 asks KMS to decrypt each disk's
# data key at boot, which IAM authorizes and CloudTrail logs.
data "aws_caller_identity" "current" {}

resource "aws_kms_key" "ebs" {
  description             = "MSS project - EBS volume encryption"
  enable_key_rotation     = true # new key material every year
  deletion_window_in_days = 7    # a deleted key can be recovered for 7 days

  # Explicit key policy (same access as AWS's default, but visible and
  # reviewable in code): the account administers the key, and IAM policies in
  # this account decide who may use it
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdministersKeyViaIAM"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = { Name = "mss-ebs" }
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/mss-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}
