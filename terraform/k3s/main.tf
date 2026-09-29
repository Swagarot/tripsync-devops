resource "kubernetes_namespace" "tripsync" {
  metadata {
    name = "tripsync"
  }
}