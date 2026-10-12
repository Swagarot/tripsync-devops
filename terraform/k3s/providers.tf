terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

# config_context is pinned on purpose: without it Terraform uses whatever the
# current kubectl context is, which on the laptop can be a (dead or live) EKS
# cluster left over from `aws eks update-kubeconfig`.
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "default"
}

# Helm provider v3: kubernetes is an attribute (=), not a block.
provider "helm" {
  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = "default"
  }
}
