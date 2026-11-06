terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }

  backend "s3" {
    bucket       = "tripsync-tfstate-roye"
    key          = "vault-config/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Address and token come from VAULT_ADDR and VAULT_TOKEN in the environment,
# never from a file.
provider "vault" {}

variable "kubeconfig" {
  description = "kubeconfig file that has the k3s context named \"default\""
  type        = string
  default     = "~/.kube/config"
}

provider "kubernetes" {
  config_path    = var.kubeconfig
  config_context = "default"
}
