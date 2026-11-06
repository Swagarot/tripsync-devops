# Vault server configuration (mounted read-only by docker-compose.yml).

ui = true

# Integrated Raft storage: one node, but it supports `vault operator raft
# snapshot`, which the backup service uses. Raft recommends mlock off.
storage "raft" {
  path    = "/vault/file"
  node_id = "vault"
}
disable_mlock = true

# No TLS here: the only way in is the Tailscale device this container shares
# its network with, and Tailscale encrypts everything (WireGuard).
listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
  telemetry {
    unauthenticated_metrics_access = true   # Prometheus in k3s scrapes /v1/sys/metrics
  }
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

# Key id, region and credentials come from the environment (.env).
seal "awskms" {}

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
