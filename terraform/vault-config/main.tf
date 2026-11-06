# Vault's configuration as code: where secrets live, who may read them, and
# how the clusters log in. Applied after `vault operator init`
# (vault/README.md), with an admin token in the environment:
#   export VAULT_ADDR=http://<vault machine>.<tailnet>.ts.net:8200 VAULT_TOKEN=<admin token>
#   terraform apply -var vault_addr=... -var k3s_api_url=...
# (or put the two in a terraform.tfvars, which .gitignore keeps out of git:
# they are internal addresses).
#
# Secret layout (KV version 2, mounted at "secret/"):
#   secret/tripsync/openrouteservice   api-key   (both clusters)
#   secret/tripsync/cloudflared        token     (homelab tunnel)
#   secret/monitoring/discord          url       (Alertmanager webhook)
# The values are never in git or Terraform: vault/import-from-k8s.sh copies
# today's hand-made Secrets in, or `vault kv put` by hand.

variable "vault_addr" {
  description = "Vault as pods in k3s reach it: http://<Vault's Tailscale IP>:8200 (pods can't resolve MagicDNS names)"
  type        = string
}

variable "k3s_api_url" {
  description = "The k3s API as the Vault container reaches it, e.g. https://<control node LAN IP>:6443 (an address in the API certificate)"
  type        = string
}

resource "vault_mount" "kv" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" } # keeps old versions: a bad edit can be undone
  description = "TripSync secrets"
}

# --- Homelab: Kubernetes login ------------------------------------------------
# A pod (ESO) proves who it is with its ServiceAccount token. Vault runs
# outside the cluster, so to check that token it calls the k3s API
# (TokenReview) with a token of its own: the vault-auth ServiceAccount below,
# which may do nothing but review tokens (system:auth-delegator).
resource "kubernetes_service_account_v1" "vault_auth" {
  metadata {
    name      = "vault-auth"
    namespace = "external-secrets"
  }
}

resource "kubernetes_cluster_role_binding_v1" "vault_auth" {
  metadata {
    name = "vault-auth-tokenreview"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.vault_auth.metadata[0].name
    namespace = "external-secrets"
  }
}

# A long-lived token for it (Kubernetes only makes these on request now).
# Rotate: delete the Secret, terraform apply.
resource "kubernetes_secret_v1" "vault_auth" {
  metadata {
    name      = "vault-auth-token"
    namespace = "external-secrets"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.vault_auth.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# The cluster's CA certificate, so Vault can verify the API's TLS certificate.
data "kubernetes_config_map_v1" "root_ca" {
  metadata {
    name      = "kube-root-ca.crt"
    namespace = "external-secrets"
  }
}

resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "k3s" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = var.k3s_api_url
  kubernetes_ca_cert = data.kubernetes_config_map_v1.root_ca.data["ca.crt"]
  token_reviewer_jwt = kubernetes_secret_v1.vault_auth.data["token"]
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
          server  = var.vault_addr
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
