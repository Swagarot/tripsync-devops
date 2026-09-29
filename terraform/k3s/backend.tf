terraform {
  backend "s3" {
    bucket         = "tripsync-tfstate-roye"
    key            = "k3s/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "tripsync-tfstate-lock"
    encrypt        = true
  }
}