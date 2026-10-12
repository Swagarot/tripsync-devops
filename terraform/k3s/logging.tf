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
  version    = "1.13.1"
  namespace  = "monitoring"

  values = [file("${path.module}/../../monitoring/alloy.yaml")]

  wait    = true
  timeout = 300

  depends_on = [helm_release.loki]
}
