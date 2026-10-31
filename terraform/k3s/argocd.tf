# Argo CD (GitOps) and the TripSync Application. Settings live in argocd/ as
# plain Helm values; Terraform only pins the charts and installs them.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.11.6"
  namespace        = "argocd"
  create_namespace = true

  values = [file("${path.module}/../../argocd/argocd.yaml")]

  wait    = true
  timeout = 600

  # Its ServiceMonitor and PrometheusRule need the monitoring CRDs.
  depends_on = [helm_release.kube_prometheus_stack]
}

# A separate chart for the Application itself: it needs Argo CD's CRDs, which
# exist only after the release above, and keeping it apart means changing the
# Application never upgrades Argo CD.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.7"
  namespace  = "argocd"

  values = [file("${path.module}/../../argocd/apps.yaml")]

  depends_on = [helm_release.argocd]
}
