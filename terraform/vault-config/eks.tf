# EKS login, only while an EKS cluster exists. Apply with its issuer:
#   terraform apply -var eks_oidc_issuer=$(terraform -chdir=../aws output -raw oidc_issuer)
# and plain `terraform apply` after the EKS teardown removes it again.
#
# JWT auth instead of the homelab's Kubernetes auth: Vault doesn't need any
# credentials for EKS's API. It downloads the cluster's public signing keys
# from the OIDC issuer URL and checks the operator's ServiceAccount token
# itself (signature, audience "vault", exact ServiceAccount).

variable "eks_oidc_issuer" {
  description = "terraform/aws output oidc_issuer; empty = no EKS login"
  type        = string
  default     = ""
}

locals {
  eks = var.eks_oidc_issuer == "" ? 0 : 1
}

resource "vault_jwt_auth_backend" "eks" {
  count              = local.eks
  path               = "jwt-eks"
  oidc_discovery_url = var.eks_oidc_issuer
  bound_issuer       = var.eks_oidc_issuer
}

# Least privilege: EKS only gets the ORS key.
resource "vault_policy" "eso_eks" {
  name   = "eso-eks"
  policy = <<-EOT
    path "secret/data/tripsync/openrouteservice" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "eso_eks" {
  count           = local.eks
  backend         = vault_jwt_auth_backend.eks[0].path
  role_name       = "eso-eks"
  role_type       = "jwt"
  user_claim      = "sub"
  bound_audiences = ["vault"]
  bound_subject   = "system:serviceaccount:external-secrets:external-secrets"
  token_policies  = [vault_policy.eso_eks.name]
  token_ttl       = 3600
}
