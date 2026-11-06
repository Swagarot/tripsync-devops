# Secrets for TripSync from HashiCorp Vault. Vault itself runs OUTSIDE the
# cluster, as a container on its own homelab machine (vault/compose), reachable
# only over Tailscale. This root makes what Vault needs in AWS (the KMS
# auto-unseal key, kms.tf) and installs the External Secrets Operator (ESO) in
# k3s, which copies secrets from Vault into ordinary Kubernetes Secrets.
#
# OPTIONAL layer, applied after terraform/k3s. Without it everything still
# works with Secrets created by hand (docs/deploy-yourself.md).
#
# Order (details in vault/README.md):
#   1. this root: KMS key + unseal user, ESO
#   2. vault/compose on the Vault machine, then `vault operator init` once
#   3. terraform/vault-config: mounts, policies, logins, ClusterSecretStore
#   4. vault/import-from-k8s.sh: copy today's hand-made Secrets into Vault

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
