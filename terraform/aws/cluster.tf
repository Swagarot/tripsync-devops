# In-cluster platform pieces that a fresh EKS cluster needs before Jenkins can
# deploy. Jenkins only has Edit inside 'tripsync', so anything cluster-scoped
# (namespaces, ingress-nginx's IngressClass/ClusterRoles/webhook) lives here.

# Owned by Terraform, same as terraform/k3s. The chart must never create it.
resource "kubernetes_namespace" "tripsync" {
  metadata {
    name = "tripsync"
  }

  # The provider's credentials only work once the cluster creator's access
  # entry exists, which is inside module.eks. Also makes destroy remove this
  # before the cluster.
  depends_on = [module.eks]
}

# Creates a Service of type LoadBalancer, so AWS builds a load balancer in the
# public subnets (elb=1 tag). On destroy, Terraform uninstalls this before the
# cluster, which deletes that load balancer too.
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.15.1"
  namespace        = "ingress-nginx"
  create_namespace = true

  # Wait until the controller is ready and the load balancer has an address,
  # so the first pipeline run doesn't race the admission webhook.
  wait    = true
  timeout = 600

  # Nodes must exist before pods can schedule. module.eks finishes only after
  # the node group, so depending on the whole module covers that.
  depends_on = [module.eks]
}
