# The nightly Raft snapshot runs next to Vault (the backup service in
# vault/compose/docker-compose.yml) with a token that may do nothing else:
#   vault token create -policy=raft-snapshot -period=768h -orphan
# Periodic: each nightly run renews it, so it never expires while the backups
# keep running, and dies 32 days after they stop.
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
