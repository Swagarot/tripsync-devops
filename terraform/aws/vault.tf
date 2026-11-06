# OPTIONAL: EKS reads the ORS key (routes) from the homelab's Vault, so both
# clusters share one source of secrets (hybrid). Off by default; then EKS
# works as before, with straight lines instead of routes.
#
# Turn on (after the homelab Vault is set up, vault/README.md):
#   export TF_VAR_vault_enabled=true
#   export TF_VAR_vault_tailnet_host=<homelab node>.<tailnet>.ts.net
#   export TF_VAR_tailscale_oauth_client_id=... TF_VAR_tailscale_oauth_client_secret=...
#   terraform apply
# then give Vault this cluster's login (terraform/vault-config, variable
# eks_oidc_issuer = the output below).
#
# The Tailscale OAuth client is the one secret EKS needs up front (it can't
# come from Vault: it is how EKS reaches Vault). It comes from the shell, is
# kept in the Terraform state (private, encrypted bucket), and is never in git.

variable "vault_enabled" {
  description = "Install the External Secrets Operator + Tailscale egress to the homelab Vault"
  type        = bool
  default     = false
}

variable "vault_tailnet_host" {
  description = "MagicDNS name of a homelab node (Vault's NodePort 30820 listens on every node)"
  type        = string
  default     = ""
}

variable "tailscale_oauth_client_id" {
  type      = string
  default   = ""
  sensitive = true
}

variable "tailscale_oauth_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

# Tailscale's Kubernetes operator: makes the egress proxy pod that joins the
# tailnet (tagged tag:k8s, ephemeral: it disappears from the tailnet when
# destroyed).
resource "helm_release" "tailscale_operator" {
  count            = var.vault_enabled ? 1 : 0
  name             = "tailscale-operator"
  repository       = "https://pkgs.tailscale.com/helmcharts"
  chart            = "tailscale-operator"
  version          = "1.104.4"
  namespace        = "tailscale"
  create_namespace = true

  set_sensitive = [
    { name = "oauth.clientId", value = var.tailscale_oauth_client_id },
    { name = "oauth.clientSecret", value = var.tailscale_oauth_client_secret },
  ]
  set = [
    { name = "operatorConfig.hostname", value = "tripsync-eks-operator" },
  ]

  wait       = true
  depends_on = [module.eks]
}

resource "helm_release" "external_secrets" {
  count            = var.vault_enabled ? 1 : 0
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.14.0"
  namespace        = "external-secrets"
  create_namespace = true

  values = [file("${path.module}/../../vault/external-secrets.yaml")]

  wait       = true
  depends_on = [module.eks]
}

# The egress Service and the ClusterSecretStore (vault/eks-store).
resource "helm_release" "vault_store" {
  count     = var.vault_enabled ? 1 : 0
  name      = "vault-store"
  chart     = "${path.module}/../../vault/eks-store"
  namespace = "external-secrets"

  set = [
    { name = "vaultTailnetHost", value = var.vault_tailnet_host },
  ]

  depends_on = [helm_release.tailscale_operator, helm_release.external_secrets]
}

# Vault checks EKS tokens against this issuer's public keys.
output "oidc_issuer" {
  value = module.eks.cluster_oidc_issuer_url
}
