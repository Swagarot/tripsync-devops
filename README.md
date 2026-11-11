# tripsync-devops

Infrastructure, deployment and operations for **TripSync**, an offline-first,
map-first trip planner (installable web app): trips → days → stops on a map,
routes between stops, shared trips (owner / editor / viewer), expense
splitting, photos, PDF export, and full editing while offline.

The app runs on a homelab **k3s** cluster (public over HTTPS through a
Cloudflare Tunnel), and the same images and Helm chart deploy to **AWS EKS**.
Deploys on k3s are GitOps: Jenkins builds and tests, then commits the new image
tag to this repo, and Argo CD rolls it out.

## The three repositories

| Repo | Contents |
|---|---|
| [tripsync-backend](https://github.com/Swagarot/tripsync-backend) | Flask API, migrations, tests, Dockerfile, Jenkinsfile |
| [tripsync-frontend](https://github.com/Swagarot/tripsync-frontend) | React + Vite PWA, nginx config, tests, Dockerfile, Jenkinsfile |
| **tripsync-devops** (this one) | Helm chart, Argo CD, Terraform (k3s + AWS), monitoring, Vault, docker-compose, docs |

Clone all three side by side; local compose builds from the sibling folders.

## Architecture

```
                 GitHub (3 repos)
                   │  polls
                   ▼
               Jenkins ──push image :<sha>──▶ Docker Hub
                   │                              │ pull
                   │ commit "Deploy backend <sha>" │
                   ▼                              ▼
          tripsync-devops ──polls──▶ Argo CD ──▶ k3s cluster (homelab)
                                                  │
 Browser ─HTTPS─▶ Cloudflare ─tunnel─▶ cloudflared ─▶ ingress-nginx
                                                  ├─ /api ─▶ backend (Flask, Gunicorn)
                                                  │            ├─▶ PostgreSQL (StatefulSet)
                                                  │            └─▶ Garage, photos (StatefulSet)
                                                  └─ /    ─▶ frontend (nginx, static build)

 Storage: Longhorn (2 replicas per volume) · nightly backup CronJob → NFS server
 Secrets: HashiCorp Vault (outside the cluster) → External Secrets → k8s Secrets
 Monitoring: Prometheus · Grafana · Loki + Alloy · Alertmanager → Discord
 AWS: the same chart on EKS (Terraform), deployed by Jenkins with helm upgrade
```

## Repository layout

| Path | What |
|---|---|
| `k8s-helm/tripsync/` | Helm chart: Deployments (frontend, backend), StatefulSets (Postgres, Garage), Services, two Ingresses, generated Secrets, probes, resource requests/limits, backup CronJob, ServiceMonitor, alert rules, Grafana dashboard |
| `k8s-helm/tripsync/values-k3s.yaml` | The homelab deployment; Jenkins changes only the image tags here |
| `k8s-helm/tripsync/values-eks.yaml` | The AWS differences (EBS storage, S3 for photos) |
| `argocd/` | Argo CD and the `tripsync` Application (auto-sync, prune, self-heal) |
| `terraform/k3s/` | Cluster add-ons: Longhorn, kube-prometheus-stack, Loki + Alloy, cloudflared, Argo CD |
| `terraform/aws/` | VPC (own module), EKS, ingress-nginx, IAM for Jenkins, S3 + Pod Identity |
| `terraform/vault/`, `terraform/vault-config/` | KMS auto-unseal key, External Secrets Operator, Vault policies, logins, backups |
| `vault/` | Vault's docker-compose (runs outside the cluster) and its runbook |
| `monitoring/` | Helm values for Prometheus/Grafana/Alertmanager, Loki, Alloy, Longhorn alerts |
| `docker-compose.yml`, `compose/` | The whole stack on a laptop |
| `docs/` | Deploy-it-yourself guide, backup and restore, the final documentation and slides |

## Run it

**On a laptop** (Docker only), with the three repos side by side:

```sh
cd tripsync-devops
docker compose up --build        # http://localhost:8080
```

Compose mirrors the cluster: a `migrate` service plays the init containers,
a `gateway` nginx plays the Ingress (`/api` → backend, the rest → frontend).
Its passwords are throwaway local-dev values; the cluster's are generated.

**On any Kubernetes cluster** (needs ingress-nginx and a default StorageClass):

```sh
kubectl create namespace tripsync
helm upgrade --install tripsync k8s-helm/tripsync -n tripsync \
  --set postgres.storageClassName=local-path
```

Step by step, tested on a fresh k3s with no keys:
[docs/deploy-yourself.md](docs/deploy-yourself.md). It also lists every
optional secret (routes, the public tunnel, Discord alerts) and what works
without it.

**The full homelab setup:** `terraform/k3s` installs the add-ons and Argo CD,
and Argo CD deploys the chart from this repo. **AWS:** `terraform/aws` builds
the EKS environment from nothing; the Jenkins jobs deploy to it with the
`TARGET=eks` parameter; `terraform destroy` removes all of it.

## CI/CD

Each app repo has its own Jenkinsfile with the same stages:

1. **Checkout** the app repo and this one.
2. **Lint**: `helm lint` on the chart, plus flake8 (backend) or ESLint (frontend).
3. **Unit tests**: backend pytest against a throwaway Postgres (every migration
   runs), frontend Vitest; results published as JUnit.
4. **Build** the image, tagged with the short commit SHA.
5. **Push** to Docker Hub.
6. **Deploy**: on k3s, commit the new tag to `values-k3s.yaml` (Argo CD rolls it
   out); on EKS, `helm upgrade --install`.

Credentials (GitHub token, Docker Hub token, AWS key) live in Jenkins'
credential store and are used without being echoed to logs. Rollback on k3s is
`git revert` of a "Deploy …" commit.

## Secrets

Nothing secret is in git. The chart generates the database password, JWT key
and photo-storage keys on first install and keeps them on upgrades. The
optional external keys (OpenRouteService, Cloudflare Tunnel token, Discord
webhook) live in HashiCorp Vault and are synced into Kubernetes by the
External Secrets Operator; without Vault they can be created by hand
(see [docs/deploy-yourself.md](docs/deploy-yourself.md)).

## Test and check

```sh
# backend (in tripsync-backend)
python -m pytest
# frontend (in tripsync-frontend)
npm ci && npm run lint && npm test
# chart
helm lint k8s-helm/tripsync -f k8s-helm/tripsync/values-k3s.yaml
# a running deployment
curl http://<ingress address>/api/health/ready     # {"status": "ready"}
```

## Docs

- [docs/deploy-yourself.md](docs/deploy-yourself.md): deploy on your own cluster
- [docs/backup-restore.md](docs/backup-restore.md): nightly backup and how to restore
- [vault/README.md](vault/README.md): the Vault setup and runbook
- [docs/final/](docs/final/): the project documentation (PDF) and presentation
