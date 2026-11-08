# Deploying TripSync yourself (k3s)

For someone with the three repositories and their own Kubernetes cluster,
but none of our API keys or accounts. The whole stack runs without them; a
few features that depend on outside services switch themselves off.

## What needs a key, and what happens without it

| Secret | Needed? | Without it | Get your own |
|---|---|---|---|
| Postgres password, JWT signing key, Garage (photo storage) keys | made for you | nothing missing: the chart generates them on first install (`templates/secret.yaml`) | - |
| `openrouteservice` (walk/bike/drive routes) | optional | the map joins a day's stops with straight lines and shows no travel times; transit routes still work (Transitous, no key) | free key at openrouteservice.org (sign up, Dashboard, token), then `kubectl -n tripsync create secret generic openrouteservice --from-literal=api-key=<key>` and restart the backend |
| `cloudflared-token` (public HTTPS URL) | optional | no public URL; open the app through your ingress (LAN / NodePort). Offline mode and "install app" need HTTPS, everything else works on http | a free Cloudflare account with a domain; or skip it |
| `alertmanager-discord` (alert delivery) | optional | alerts still fire and show in Alertmanager/Grafana, they just aren't posted to Discord | a Discord channel webhook, as Secret `webhook-url` in `monitoring` |
| HashiCorp Vault (`terraform/vault`) | optional | the Secrets above are created by hand, as in this table | see `vault/README.md` |
| AWS (EKS, S3, KMS) | not for k3s | - | - |

Nothing in this list is in git, and none of ours are shared: create your own
or leave the feature off.

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
`nfs-client` StorageClass, see `backup:` in `values.yaml`).

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
   `tripsync-devops` and give Argo CD read access to it (a deploy key, Secret
   `repo-tripsync-devops` in `argocd`; see CLAUDE.md "Argo CD sprint").
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
- Argo CD UI (NodePort 30443): Application `tripsync` Synced / Healthy.
- Grafana (NodePort 30300): the TripSync dashboard has data.
