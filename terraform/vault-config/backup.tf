# Nightly Raft snapshots: the whole Vault, still encrypted (restoring it
# needs the same KMS key). Two copies, each with its own token that may do
# nothing else:
#   1. next to Vault (the backup service in vault/compose/docker-compose.yml),
#      a local folder in the LXC: undoes a wrong delete, not a lost machine;
#   2. this CronJob in k3s, onto the NFS server (`nfs-client`, like the
#      TripSync backup). An unprivileged LXC can't mount NFS (the kernel
#      refuses NFS mounts inside a user namespace), so k3s, which already
#      has NFS, pulls the snapshot over Tailscale instead.
#
# Each token:
#   vault token create -policy=raft-snapshot -period=768h -orphan
# Periodic: each nightly run renews it, so it never expires while the backups
# keep running, and dies 32 days after they stop. The CronJob's token lives in
# Vault itself (secret/vault/backup, field token) and External Secrets brings
# it here; k3s may read all of secret/ anyway, so this adds no exposure.
resource "vault_policy" "backup" {
  name   = "raft-snapshot"
  policy = <<-EOT
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }
  EOT
}

resource "kubernetes_namespace_v1" "vault_backup" {
  metadata {
    name = "vault-backup"
  }
}

# Snapshots are small (KBs to a few MB); 14 nights kept.
resource "kubernetes_persistent_volume_claim_v1" "vault_backup" {
  metadata {
    name      = "vault-backups"
    namespace = kubernetes_namespace_v1.vault_backup.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "nfs-client"
    resources {
      requests = { storage = "1Gi" }
    }
  }
  wait_until_bound = false
  lifecycle {
    prevent_destroy = true # the backups outlive a terraform destroy
  }
}

resource "kubernetes_manifest" "backup_token" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "vault-backup-token", namespace = kubernetes_namespace_v1.vault_backup.metadata[0].name }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { kind = "ClusterSecretStore", name = "vault" }
      target          = { name = "vault-backup-token" }
      data = [{
        secretKey = "token"
        remoteRef = { key = "vault/backup", property = "token" }
      }]
    }
  }
  depends_on = [kubernetes_manifest.secret_store]
}

resource "kubernetes_cron_job_v1" "vault_backup" {
  metadata {
    name      = "vault-backup"
    namespace = kubernetes_namespace_v1.vault_backup.metadata[0].name
  }
  spec {
    # After the TripSync backup (03:30), away from the local copy (03:45 UTC).
    schedule                      = "15 4 * * *"
    timezone                      = "Asia/Jerusalem"
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 3600
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit           = 1
        active_deadline_seconds = 600
        template {
          metadata {
            labels = { app = "vault-backup" }
          }
          spec {
            restart_policy = "Never"
            security_context {
              run_as_non_root = true
              run_as_user     = 1000
              run_as_group    = 1000
            }
            container {
              name    = "snapshot"
              image   = "hashicorp/vault:2.0.4" # the same version as the server
              command = ["sh", "-c"]
              # The token is trimmed first: pasting or piping it into
              # `vault kv put` (PowerShell adds \r\n) leaves a line ending,
              # which Vault rejects ("non-printable characters"). Written to
              # .tmp first, so a failed snapshot never replaces a good one.
              args = [<<-EOT
                set -eu
                VAULT_TOKEN=$(printf %s "$VAULT_TOKEN" | tr -d '\r\n ')
                export VAULT_TOKEN
                vault token renew >/dev/null
                file=/backups/vault-$(date +%F).snap
                vault operator raft snapshot save "$file.tmp"
                mv "$file.tmp" "$file"
                find /backups -name 'vault-*.snap' -mtime +14 -delete
                ls -lh /backups | tail -3
              EOT
              ]
              env {
                name  = "VAULT_ADDR"
                value = var.vault_addr
              }
              env {
                name = "VAULT_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "vault-backup-token"
                    key  = "token"
                  }
                }
              }
              env {
                name  = "HOME"
                value = "/tmp"
              }
              volume_mount {
                name       = "backups"
                mount_path = "/backups"
              }
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { cpu = "500m", memory = "128Mi" }
              }
            }
            volume {
              name = "backups"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim_v1.vault_backup.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}
