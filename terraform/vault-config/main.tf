# Vault's configuration as code: where secrets live, who may read them, and
# how the clusters log in. Applied after terraform/vault and `vault operator
# init` (vault/README.md), with an admin token in the environment:
#   export VAULT_ADDR=http://<homelab node>:30820 VAULT_TOKEN=<root or admin token>
#   terraform apply
#
# Secret layout (KV version 2, mounted at "secret/"):
#   secret/tripsync/openrouteservice   api-key   (both clusters)
#   secret/tripsync/cloudflared        token     (homelab tunnel)
#   secret/monitoring/discord          url       (Alertmanager webhook)
# The values are never in git or Terraform: vault/import-from-k8s.sh copies
# today's hand-made Secrets in, or `vault kv put` by hand.

resource "vault_mount" "kv" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" } # keeps old versions: a bad edit can be undone
  description = "TripSync secrets"
}

# --- Homelab: Kubernetes login ------------------------------------------------
# A pod proves who it is with its ServiceAccount token; Vault asks the k3s API
# (TokenReview) whether the token is real. Vault runs inside this cluster, so
# it uses its own ServiceAccount for that (the chart grants it
# system:auth-delegator) and the in-cluster API address.
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "k3s" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc"
}

# ESO on the homelab reads everything under secret/ (read only).
resource "vault_policy" "eso_homelab" {
  name   = "eso-homelab"
  policy = <<-EOT
    path "secret/data/*" {
      capabilities = ["read"]
    }
    path "secret/metadata/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "eso_homelab" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "external-secrets"
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = [vault_policy.eso_homelab.name]
  token_ttl                        = 3600
}

# The one ClusterSecretStore every ExternalSecret on the homelab points at.
resource "kubernetes_manifest" "secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "vault" }
    spec = {
      provider = {
        vault = {
          server  = "http://vault.vault.svc:8200"
          path    = vault_mount.kv.path
          version = "v2"
          auth = {
            kubernetes = {
              mountPath = vault_auth_backend.kubernetes.path
              role      = vault_kubernetes_auth_backend_role.eso_homelab.role_name
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  }
}

# Alertmanager's Discord webhook. Lives here, not in the TripSync chart,
# because the monitoring namespace belongs to terraform/k3s. Orphan: if the
# hand-made Secret is already there it is taken over and updated, and
# deleting this never deletes the Secret (Alertmanager keeps working).
resource "kubernetes_manifest" "discord" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "alertmanager-discord", namespace = "monitoring" }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { kind = "ClusterSecretStore", name = "vault" }
      target          = { name = "alertmanager-discord", creationPolicy = "Orphan" }
      data = [{
        secretKey = "webhook-url"
        remoteRef = { key = "monitoring/discord", property = "url" }
      }]
    }
  }
  depends_on = [kubernetes_manifest.secret_store]
}
