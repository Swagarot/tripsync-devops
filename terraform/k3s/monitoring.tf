# Prometheus, Alertmanager and Grafana (plus node-exporter and
# kube-state-metrics). Settings live in monitoring/ so they read as plain Helm
# values; Terraform only pins the chart and installs it.
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "92.3.0"
  namespace        = "monitoring"
  create_namespace = true

  values = [file("${path.module}/../../monitoring/kube-prometheus-stack.yaml")]

  wait    = true
  timeout = 900

  # Prometheus and Alertmanager volumes use the longhorn StorageClass.
  depends_on = [helm_release.longhorn]
}
