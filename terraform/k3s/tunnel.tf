# Cloudflare Tunnel: public HTTPS for the homelab app without opening any port
# on the home router.
#
# How it works: cloudflared runs inside the cluster and makes OUTBOUND
# connections to Cloudflare's edge. Browsers connect to
# https://<hostname> at Cloudflare (which holds the TLS certificate), and
# Cloudflare sends each request back down those existing connections. Nothing
# reaches in from the internet, so there's no port forward and no public IP.
#
# Why we need it: browsers only run service workers (offline mode, "install
# app") on HTTPS. The Tailscale/LAN addresses are plain http.
#
# The tunnel is "remotely managed": its routes are set in the Cloudflare
# dashboard (public hostname -> service), and this pod only needs the token.
# Route to set there:
#   http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80
# so requests go through ingress-nginx like all other traffic (/api split etc.).
#
# The token is a secret, so it is NOT in Terraform or git. Create it by hand
# before applying (same pattern as the Alertmanager Discord webhook):
#   kubectl --context default -n tripsync create secret generic cloudflared-token \
#     --from-literal=token='<token from the dashboard>'
#
# A DaemonSet: one connector on every worker (the control node's NoSchedule
# taint keeps it off there, so 2 today). Cloudflare spreads requests over all
# connectors of a tunnel, so losing a worker doesn't take the site offline.
# It used to be a Deployment with 2 replicas and *preferred* anti-affinity:
# after node trouble both pods ended up on one worker (2026-11-12), and that
# worker was then a single point of failure. A DaemonSet can't do that.
# Updates replace one node's pod at a time, so the other keeps serving.
resource "kubernetes_daemon_set_v1" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace.tripsync.metadata[0].name
    labels    = { app = "cloudflared" }
  }

  spec {
    selector {
      match_labels = { app = "cloudflared" }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 1
      }
    }

    template {
      metadata {
        labels = { app = "cloudflared" }
      }

      spec {
        container {
          name  = "cloudflared"
          image = "cloudflare/cloudflared:2026.10.1"
          # --no-autoupdate: the image tag decides the version, not the pod.
          # --metrics: health (/ready) and Prometheus metrics on port 2000.
          args = ["tunnel", "--no-autoupdate", "--metrics", "0.0.0.0:2000", "run"]

          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = "cloudflared-token"
                key  = "token"
              }
            }
          }

          port {
            name           = "metrics"
            container_port = 2000
          }

          # /ready is 200 only while this connector has a live connection to
          # Cloudflare. If it stays down, restart the pod.
          liveness_probe {
            http_get {
              path = "/ready"
              port = 2000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 3
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }

          # The image already runs as an unprivileged user; also make the
          # filesystem read-only and drop all Linux capabilities.
          security_context {
            run_as_non_root            = true
            read_only_root_filesystem  = true
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }
}
