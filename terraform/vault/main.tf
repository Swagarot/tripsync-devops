# HashiCorp Vault on the homelab: the one place every hand-made secret lives
# (OpenRouteService key, Cloudflare tunnel token, Discord webhook, ...).
# The External Secrets Operator (ESO) copies them from Vault into ordinary
# Kubernetes Secrets, so the apps don't change. Both clusters read the same
# Vault: k3s directly, EKS over Tailscale.
#
# OPTIONAL layer, applied after terraform/k3s. Without it everything still
# works with Secrets created by hand (the teacher's deploy, docs/deploy-yourself.md).
#
# Order (details in vault/README.md):
#   1. this root: KMS key, Vault, External Secrets Operator
#   2. once: vault operator init (keep the recovery keys + root token safe)
#   3. terraform/vault-config: mounts, policies, auth, ClusterSecretStore
#   4. vault/import-from-k8s.sh: copy today's hand-made Secrets into Vault

resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
  }
}

# Vault server: one pod (StatefulSet), integrated Raft storage on a Longhorn
# volume, auto-unseal with AWS KMS (kms.tf). Settings in vault/vault.yaml.
resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.34.1" # Vault 2.0.4
  namespace  = kubernetes_namespace.vault.metadata[0].name

  values = [file("${path.module}/../../vault/vault.yaml")]

  # The pod starts sealed and uninitialized on the very first install, so it
  # is never "ready" until step 2: don't wait for it.
  wait    = false
  timeout = 600

  depends_on = [kubernetes_secret_v1.vault_kms]
}

# External Secrets Operator: ExternalSecret objects say "make Secret X from
# Vault path Y"; it keeps them in sync (refresh interval per ExternalSecret).
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.14.0"
  namespace        = "external-secrets"
  create_namespace = true

  values = [file("${path.module}/../../vault/external-secrets.yaml")]

  wait    = true
  timeout = 600
}
