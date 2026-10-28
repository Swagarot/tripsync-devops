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
# The kubeconfig file itself can be swapped too (another course's tools
# replaced ~/.kube/config on the laptop once): -var kubeconfig=<path>.
variable "kubeconfig" {
  description = "kubeconfig file that has the k3s context named \"default\""
  type        = string
  default     = "~/.kube/config"
}

provider "kubernetes" {
  config_path    = var.kubeconfig
  config_context = "default"
}

# Helm provider v3: kubernetes is an attribute (=), not a block.
provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig
    config_context = "default"
  }
}
