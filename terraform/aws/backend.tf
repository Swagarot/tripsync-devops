terraform {
  backend "s3" {
    bucket         = "tripsync-tfstate-roye"
    key            = "aws/terraform.tfstate" # path within the bucket
    region         = "eu-central-1"
    dynamodb_table = "tripsync-tfstate-lock"
    encrypt        = true
  }
}