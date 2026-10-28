terraform {
  backend "s3" {
    bucket = "tripsync-tfstate-roye"
    key    = "k3s/terraform.tfstate"
    region = "eu-central-1"
    # Locking with a lock file next to the state in S3 (S3 conditional writes,
    # Terraform >= 1.10): replaces the separate DynamoDB lock table, which
    # Terraform has deprecated. Two applies at once: the second one waits.
    use_lockfile = true
    encrypt      = true
  }
}