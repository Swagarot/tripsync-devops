# Replicated block storage for stateful workloads (Prometheus, Loki, later
# Postgres). Each volume keeps a full copy on both workers, so losing one worker
# loses no data. Prerequisites done by hand on each worker: a dedicated disk
# mounted at /var/lib/longhorn (Longhorn's default data path) and open-iscsi.
resource "helm_release" "longhorn" {
  name       = "longhorn"
  repository = "https://charts.longhorn.io"
  chart      = "longhorn"
  version    = "1.12.1"
  # Longhorn expects to live in this namespace.
  namespace        = "longhorn-system"
  create_namespace = true

  values = [yamlencode({
    persistence = {
      # local-path stays the cluster default; workloads opt in with
      # storageClassName: longhorn, so nothing moves here by accident.
      defaultClass = false
      # Only 2 schedulable workers. The default of 3 would leave every volume
      # degraded, since two replicas may never share a node.
      defaultClassReplicaCount = 2
    }
    defaultSettings = {
      # Same count for volumes created from the Longhorn UI.
      defaultReplicaCount = "{\"v1\":\"2\",\"v2\":\"2\"}"
      # /var/lib/longhorn is a dedicated disk, so no space needs to be held
      # back for the OS. Longhorn still stops scheduling replicas when a disk
      # drops below 25% free (storageMinimalAvailablePercentage default).
      storageReservedPercentageForDefaultDisk = 0
    }
  })]

  wait    = true
  timeout = 600
}
