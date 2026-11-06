terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket       = "tripsync-tfstate-roye"
    key          = "vault/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "eu-central-1"
}

# Same as terraform/k3s: the homelab cluster, context pinned to "default".
variable "kubeconfig" {
  description = "kubeconfig file that has the k3s context named \"default\""
  type        = string
  default     = "~/.kube/config"
}

provider "kubernetes" {
  config_path    = var.kubeconfig
  config_context = "default"
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig
    config_context = "default"
  }
}
