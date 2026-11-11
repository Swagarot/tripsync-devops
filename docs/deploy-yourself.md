# Deploying TripSync yourself (k3s)

For someone with the three repositories and their own Kubernetes cluster,
but none of our API keys or accounts. The whole stack runs without them; a
few features that depend on outside services switch themselves off.

## What needs a key, and what happens without it

| Secret | Needed? | Without it | Get your own |
|---|---|---|---|
| Postgres password, JWT signing key, Garage (photo storage) keys | made for you | nothing missing: the chart generates them on first install (`templates/secret.yaml`) | - |
| `openrouteservice` (walk/bike/drive routes) | optional | the map joins a day's stops with straight lines and shows no travel times; transit routes still work (Transitous, no key) | free key at openrouteservice.org (sign up, Dashboard, token), then `kubectl -n tripsync create secret generic openrouteservice --from-literal=api-key=<key>` and `kubectl -n tripsync rollout restart deploy/tripsync-backend` |
| `cloudflared-token` (public HTTPS URL) | optional | no public URL; open the app through your ingress (LAN / NodePort). Offline mode and "install app" need HTTPS, everything else works on http | a free Cloudflare account with a domain: create a tunnel, route its hostname to `http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80`, then `kubectl -n tripsync create secret generic cloudflared-token --from-literal=token=<tunnel token>` (the cloudflared Deployment comes from `terraform/k3s/tunnel.tf`); or skip it |
| `alertmanager-discord` (alert delivery) | optional | alerts still fire and show in Alertmanager/Grafana, they just aren't posted to Discord | a Discord channel webhook: `kubectl -n monitoring create secret generic alertmanager-discord --from-literal=webhook-url=<url>` |
| HashiCorp Vault (`vault/`, `terraform/vault`, `terraform/vault-config`) | optional | the Secrets above are created by hand, as in this table | see `vault/README.md` |
| AWS (EKS, S3, KMS) | not for k3s | - | - |

Nothing in this list is in git, and none of ours are shared: create your own
or leave the feature off.

## Before a cluster: the whole stack on a laptop

With Docker and the three repos cloned side by side, `docker compose up
--build` in `tripsync-devops` runs everything (Postgres, Garage, migrations,
backend, frontend, and an nginx gateway standing in for the Ingress) at
http://localhost:8080.

## Quickest: the app on any cluster (about 10 minutes)

Needs a cluster with an ingress-nginx controller and a default StorageClass
(k3s has `local-path`). Tested 2026-11-08 exactly as written, on a fresh
single-node k3s (v1.31) with none of our keys: all pods Running in under a
minute; register, trip, day, stop, photo upload + thumbnail all worked;
routes answered 503 "Routing isn't set up" (the map then draws straight
lines), as expected without an ORS key.

```bash
# k3s ships Traefik, which takes ports 80/443; this chart uses ingress-nginx
# annotations, so install k3s without it:
curl -sfL https://get.k3s.io | sh -s - --disable traefik

# ingress-nginx, if the cluster has none
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx -n ingress-nginx --create-namespace

kubectl create namespace tripsync
helm upgrade --install tripsync tripsync-devops/k8s-helm/tripsync -n tripsync \
  --set postgres.storageClassName=local-path
kubectl -n tripsync get pods -w      # backend waits for the migrate init container
```

Open the ingress controller's address (`kubectl -n ingress-nginx get svc`;
on k3s it is the node's IP, port 80). Right after the pods turn Running, the
ingress can answer 503 for a few seconds until it picks them up.
Defaults that matter: images are the public Docker Hub images
`swagarot/tripsync-backend` / `-frontend` (`values.yaml`); Garage stores
photos inside the cluster; the nightly backup is off (it needs an
`nfs-client` StorageClass, see `backup:` in `values.yaml`). The chart's
monitoring objects (ServiceMonitor, alert rules, Grafana dashboard) and
ExternalSecrets are only created when the cluster has their CRDs
(Prometheus Operator, External Secrets Operator), so on a plain cluster they
are skipped and nothing fails.

## The full homelab setup (what we run)

In order; each part is described in `docs/final/` and in the files' comments.

1. **k3s** cluster, with ingress-nginx and (for backups) an NFS provisioner
   giving the `nfs-client` StorageClass. Longhorn needs a disk mounted at
   `/var/lib/longhorn` and `open-iscsi` on each worker.
2. **`terraform/k3s`**: Longhorn, kube-prometheus-stack, Loki + Alloy,
   cloudflared, Argo CD and the TripSync Application. Before `init`, change
   the S3 state backend in `backend.tf` (our bucket is private) or delete the
   `backend` block to keep the state locally. Set the kubeconfig context name
   (`default`) or pass `-var kubeconfig=...`.
3. **Argo CD** deploys `k8s-helm/tripsync` with `values-k3s.yaml` from git
   (`argocd/apps.yaml`). Point `repoURL` at your own copy of
   `tripsync-devops`. A public copy needs nothing more; for a private one,
   add a read-only GitHub deploy key and give Argo CD its private half:
   ```bash
   kubectl -n argocd create secret generic repo-tripsync-devops      --from-literal=type=git      --from-literal=url=git@github.com:<you>/tripsync-devops.git      --from-file=sshPrivateKey=<path to the private key>
   kubectl -n argocd label secret repo-tripsync-devops argocd.argoproj.io/secret-type=repository
   ```
4. **Jenkins** (optional, CI): two pipeline jobs from the app repos'
   `Jenkinsfile`s. Credentials they expect: Docker Hub (push), a GitHub token
   with write access to tripsync-devops (the "Deploy ..." commits); AWS keys
   only for `TARGET=eks`. Push to your own Docker Hub and change the image
   repositories in `values.yaml`.
5. Optional: Vault (`vault/README.md`), the Secrets in the table above.

## Checks that it works

- `kubectl -n tripsync get pods`: backend, frontend, postgres, garage Running.
- `curl http://<ingress>/api/health/ready` -> `{"status": "ready"}`.
- Register, make a trip, add a stop and a photo.
- Argo CD UI (`https://<node>:30443`): Application `tripsync` Synced / Healthy.
- Grafana (`http://<node>:30300`): the TripSync dashboard has data.
- Tests without a cluster: `python -m pytest` in tripsync-backend,
  `npm ci && npm test` in tripsync-frontend.
