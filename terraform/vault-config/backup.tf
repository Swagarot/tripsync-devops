# Nightly Vault backup to the NFS server, next to the TripSync backups.
# Longhorn's two copies protect against a dead disk, not against a mistake
# (a deleted secret is deleted on both copies), so Vault needs a backup too.
#
# A Raft snapshot is the whole Vault, still encrypted: restoring it
# (`vault operator raft snapshot restore`) needs the same KMS key to unseal, so
# a stolen snapshot is useless on its own.

resource "vault_policy" "backup" {
  name   = "raft-snapshot"
  policy = <<-EOT
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }
  EOT
}

resource "kubernetes_service_account_v1" "backup" {
  metadata {
    name      = "vault-backup"
    namespace = "vault"
  }
}

resource "vault_kubernetes_auth_backend_role" "backup" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "vault-backup"
  bound_service_account_names      = [kubernetes_service_account_v1.backup.metadata[0].name]
  bound_service_account_namespaces = ["vault"]
  token_policies                   = [vault_policy.backup.name]
  token_ttl                        = 600
}

resource "kubernetes_persistent_volume_claim_v1" "backup" {
  metadata {
    name      = "vault-backup"
    namespace = "vault"
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "nfs-client"
    resources {
      requests = { storage = "1Gi" }
    }
  }
}

resource "kubernetes_cron_job_v1" "backup" {
  metadata {
    name      = "vault-backup"
    namespace = "vault"
  }
  spec {
    schedule                      = "45 3 * * *" # 03:45, after the TripSync backup (03:30)
    timezone                      = "Asia/Jerusalem"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account_v1.backup.metadata[0].name
            restart_policy       = "OnFailure"
            security_context {
              run_as_non_root = true
              run_as_user     = 100
            }
            container {
              name  = "snapshot"
              image = "hashicorp/vault:2.0.4" # same version as the server
              # Log in with this pod's ServiceAccount token, save a snapshot,
              # keep 14 days.
              command = ["sh", "-c", <<-EOT
                set -e
                export VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login \
                  role=vault-backup jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)
                vault operator raft snapshot save /backups/vault-$(date +%F).snap
                find /backups -name 'vault-*.snap' -mtime +14 -delete
                ls -l /backups
              EOT
              ]
              env {
                name  = "VAULT_ADDR"
                value = "http://vault.vault.svc:8200"
              }
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "128Mi" }
              }
              volume_mount {
                name       = "backups"
                mount_path = "/backups"
              }
            }
            volume {
              name = "backups"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim_v1.backup.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}
