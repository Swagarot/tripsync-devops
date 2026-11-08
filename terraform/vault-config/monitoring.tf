# Vault is outside the cluster, so there is no Service for a ServiceMonitor:
# Prometheus scrapes it directly over Tailscale (/v1/sys/metrics, allowed
# without a token in vault.hcl). The release label is what this Prometheus
# selects ScrapeConfigs by (only ServiceMonitors/PodMonitors/rules are opened
# to all in monitoring/kube-prometheus-stack.yaml).

locals {
  vault_hostport = trimprefix(var.vault_addr, "http://")
}

resource "kubernetes_manifest" "vault_scrape" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1alpha1"
    kind       = "ScrapeConfig"
    metadata = {
      name      = "vault"
      namespace = "monitoring"
      labels    = { release = "kube-prometheus-stack" }
    }
    spec = {
      metricsPath    = "/v1/sys/metrics"
      params         = { format = ["prometheus"] }
      scrapeInterval = "30s"
      staticConfigs = [{
        targets = [local.vault_hostport]
        labels  = { job = "vault" }
      }]
    }
  }
}

resource "kubernetes_manifest" "vault_rules" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata   = { name = "vault", namespace = "monitoring" }
    spec = {
      groups = [{
        name = "vault"
        rules = [
          {
            alert  = "VaultSealed"
            expr   = "vault_core_unsealed == 0"
            for    = "5m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "Vault is sealed"
              description = "Vault restarted and could not auto-unseal: is AWS KMS reachable, and is the unseal access key in vault/compose/.env still valid? Apps keep their current Secrets, but nothing new syncs."
            }
          },
          {
            # up == 0: Prometheus can't reach it (container down, machine off,
            # Tailscale broken). Then VaultSealed can't fire either.
            alert  = "VaultDown"
            expr   = "up{job=\"vault\"} == 0 or absent(up{job=\"vault\"})"
            for    = "10m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "Vault is unreachable"
              description = "Prometheus can't scrape Vault over Tailscale for 10 minutes. Is the container running (docker compose ps on the Vault machine) and the vault device online in Tailscale? Apps keep their current Secrets."
            }
          },
          {
            # The NFS copy (backup.tf) hasn't succeeded for over a day. A
            # single failed Job is also reported by the built-in KubeJobFailed;
            # this catches "silently not running" (and a never-run CronJob).
            alert  = "VaultBackupMissing"
            expr   = "time() - kube_cronjob_status_last_successful_time{namespace=\"vault-backup\", cronjob=\"vault-backup\"} > 26 * 3600 or absent(kube_cronjob_status_last_successful_time{namespace=\"vault-backup\", cronjob=\"vault-backup\"})"
            for    = "30m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "Vault backup is overdue"
              description = "No Vault snapshot reached the NFS server for over 26 hours. Check the Jobs in namespace vault-backup (an expired token or an unreachable Vault are the usual causes)."
            }
          },
        ]
      }]
    }
  }
}
