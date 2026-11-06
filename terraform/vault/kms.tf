# Auto-unseal. Vault keeps everything encrypted with a key that is itself
# encrypted ("sealed"); after every restart it must be unsealed before it
# answers. With the awskms seal, Vault asks AWS KMS to decrypt that key, so it
# comes back by itself after a restart or reboot. Nobody types unseal keys.
#
# Hybrid on purpose: the homelab Vault (a container, vault/compose) depends on
# AWS for this one thing. If AWS is unreachable, a restarted Vault stays sealed
# (alert VaultSealed), but every Secret ESO already made keeps working, so the
# apps don't notice.
#
# This key is permanent (about $1/month) and NOT part of the EKS environment:
# destroying EKS never touches it. Deleting it makes Vault's data unreadable
# forever, so deletion waits 30 days (the maximum) and Terraform refuses to
# destroy it (prevent_destroy).

resource "aws_kms_key" "vault_unseal" {
  description             = "TripSync homelab Vault auto-unseal"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Project = "TripSync"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/tripsync-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

# The homelab isn't in AWS, so the container can't get a role the way EKS pods
# do (Pod Identity): it needs an access key. Its own IAM user, allowed exactly the
# three KMS calls the seal makes, on this one key. Leaked, it can't read any
# secret: it only helps someone who also has a copy of Vault's disk.
resource "aws_iam_user" "vault_unseal" {
  name = "tripsync-vault-unseal"
  tags = {
    Project = "TripSync"
  }
}

resource "aws_iam_user_policy" "vault_unseal" {
  name = "kms-unseal"
  user = aws_iam_user.vault_unseal.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
      Resource = aws_kms_key.vault_unseal.arn
    }]
  })
}

# Rotate: terraform apply -replace=aws_iam_access_key.vault_unseal, put the
# new pair into vault/compose/.env, `docker compose up -d`. The key is in the
# Terraform state (private, encrypted S3 bucket) and in that .env, nowhere else.
resource "aws_iam_access_key" "vault_unseal" {
  user = aws_iam_user.vault_unseal.name
}

# For vault/compose/.env (terraform output -raw <name>).
output "unseal_access_key_id" {
  value = aws_iam_access_key.vault_unseal.id
}

output "unseal_secret_access_key" {
  value     = aws_iam_access_key.vault_unseal.secret
  sensitive = true
}

output "kms_key_id" {
  value = aws_kms_key.vault_unseal.key_id
}
