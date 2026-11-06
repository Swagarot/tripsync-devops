# Logs: Loki stores them, Alloy (one pod per node) collects them, Grafana
# (from kube-prometheus-stack) queries them. Settings live in monitoring/.
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "7.3.0"
  namespace  = "monitoring"

  values = [file("${path.module}/../../monitoring/loki.yaml")]

  wait    = true
  timeout = 600

  # The monitoring namespace comes from kube-prometheus-stack, and the volume
  # uses the longhorn StorageClass.
  depends_on = [helm_release.kube_prometheus_stack, helm_release.longhorn]
}

resource "helm_release" "alloy" {
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  # 1.15.0 = Alloy v1.21.3 (was 1.13.1 = v1.20.1). Upgraded 2026-11-06 after
  # the second runaway-read incident: one Alloy pod re-reading from disk at
  # ~900 MB/s saturated the shared Proxmox storage (k3s SQLite "database is
  # locked", all Longhorn volumes degraded). Only the images change.
  version   = "1.15.0"
  namespace = "monitoring"

  values = [file("${path.module}/../../monitoring/alloy.yaml")]

  wait    = true
  timeout = 300

  depends_on = [helm_release.loki]
}
