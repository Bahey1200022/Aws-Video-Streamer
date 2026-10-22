# Customer-managed KMS key for the servers' disks (encryption at rest).
# The key material never leaves KMS; EC2 asks KMS to decrypt each disk's
# data key at boot, which IAM authorizes and CloudTrail logs.
resource "aws_kms_key" "ebs" {
  description             = "MSS project - EBS volume encryption"
  enable_key_rotation     = true # new key material every year
  deletion_window_in_days = 7    # a deleted key can be recovered for 7 days

  tags = { Name = "mss-ebs" }
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/mss-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}
