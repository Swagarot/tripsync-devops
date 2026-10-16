# TripSync DevOps — Project Context

> Committed to the `tripsync-devops` repo. Any Claude session (Claude Code or a
> fresh chat) should read this first. **This file is committed: never put
> secrets, tokens, keys, account IDs or internal IP addresses in it.**

## What this is

Solo Technion DevOps course final project: **TripSync**, a single-user,
offline-first trip planner (installable PWA) that is genuinely hosted. Owner:
Roye. Teachers approved the custom idea ("broadly it fits") and asked for:
separate frontend and backend repos, a Jenkinsfile in each app repo (two
independent pipelines), and this `CLAUDE.md` in the devops repo.

Roye works in short sessions and is using AI assistance, but must **understand**
what gets built well enough to debug and defend it. Explain the why, not just
the what.

## Repositories (GitHub user `Swagarot`)

| Repo | Contents |
|---|---|
| `tripsync-backend` | Flask API, Dockerfile, tests, **Jenkinsfile** |
| `tripsync-frontend` | Vite + React PWA, Dockerfile, `nginx.conf`, tests, **Jenkinsfile** |
| `tripsync-devops` (this repo) | `k8s-helm/tripsync/` chart, `terraform/k3s`, `terraform/aws`, `docker-compose.yml` + `compose/gateway.conf`, `monitoring/` values, this file |

`tripsync-app` is the old combined repo, now **archived** (read-only). Backend
and frontend were split out of it with `git subtree split` (history kept). The
legacy single-pipeline `Jenkinsfile` that lived at the root of this repo has
been removed; it is still in git history.

## Status

Done: local Docker/compose skeleton; Terraform k3s namespace; Helm chart
(deployments, services, split ingress, probes, resource limits); ingress-nginx on
k3s; Jenkins controller + agent; a single combined pipeline (lint, build, push,
deploy with commit-SHA tags), since replaced by the two per-repo pipelines; Terraform for AWS applied and proven end to end: EKS cluster,
ingress-nginx, and both pipelines deployed to EKS through the `TARGET` parameter,
with the app loading through the AWS load balancer. **EKS is destroyed between
sessions** and must be rebuilt for each test (see the Week 4 list below).

Week 3 done: backend and frontend Jenkinsfiles, two Jenkins jobs triggered by
SCM polling (verified), shared deploy lock, compose moved here, old single job
disabled, root `Jenkinsfile` removed, `tripsync-app` archived.

Compose (`docker-compose.yml`, local dev only, not used by any pipeline):
builds from the sibling repos (`../tripsync-backend`, `../tripsync-frontend`)
and adds a `gateway` nginx (`compose/gateway.conf`) on `localhost:8080` that
mimics the two Ingresses: `/api/` to the backend with the prefix stripped,
everything else to the frontend. Without it the frontend's relative `/api` calls
hit `try_files` and get `index.html`. **Not yet tested** (no Docker on the
laptop at the time); tested end to end 2026-10-16 with postgres + migrate added.

Week 4 done (2026-10-10), clean-slate test passed: `terraform apply` (54
resources), then both pipelines with `TARGET=eks`, app served through the ELB,
then `terraform destroy` (54 destroyed, no `DependencyViolation`, AWS verified
empty). No manual steps.
1. Own minimal VPC module (spec below) replaced the community VPC module.
2. Terraform owns the `tripsync` namespace, ingress-nginx (`helm_release`, chart
   4.15.1, in `terraform/aws/cluster.tf`) and the Jenkins access entry. The
   `kubernetes`/`helm` providers connect via EKS module outputs +
   `aws eks get-token` (`terraform/aws/providers.tf`).
3. Jenkinsfiles use `helm upgrade --install` and push `:latest` next to the SHA
   tag. `latest` is only the other service's fallback on the very first install
   of a fresh cluster; every deploy still uses SHA tags. (A stale `latest` already
   existed on Docker Hub; Roye questioned pushing it, kept for now. Alternative:
   pass both SHA tags on first install.)
Optional: move EKS images to ECR.
**Flag:** the ingress-nginx project was retired in March 2026 (last chart 4.15.1,
2026-03-19; no further security fixes). Fine for now, but consider Gateway API or
another controller later, and be ready to explain the choice.

Week 5 (started 2026-10-12): observability on **k3s only** (EKS is ephemeral and
its 4 GiB node is too small). Plan: Longhorn first, then kube-prometheus-stack
(Prometheus, Alertmanager, Grafana) via `helm_release` in `terraform/k3s`,
Grafana dashboards/datasources as code (no Grafana PVC), backend `/metrics` +
`ServiceMonitor`, Loki + Grafana Alloy for logs (Promtail is EOL, verify), a few
alert rules. Retention about 7 days.
- **Scope addition (deliberate, 2026-10-12): Longhorn** replicated block storage
  (`terraform/k3s/longhorn.tf`, chart 1.12.1, `longhorn-system`), 2 replicas (only
  2 schedulable workers; the control node has the `NoSchedule` taint), NOT the
  default class (`local-path` stays default; workloads opt in with
  `storageClassName: longhorn`). Each worker has a dedicated 100 GB disk mounted
  at `/var/lib/longhorn` (`LABEL=longhorn`, `nofail`) and `open-iscsi`. Why: survive
  losing a worker for Prometheus, Loki and later Postgres.
- Storage reasoning to defend: Prometheus docs say NFS is unsupported (corruption
  risk); a shared (RWX) volume is NFS underneath and Prometheus allows only one
  writer anyway (lock file). Replicated RWO block storage is the right fit. The
  NFS server is a good target for backups (Week 6 Postgres dumps).
- `terraform/k3s` providers now pin `config_context = "default"`: the laptop's
  current kubectl context was a stale EKS entry.
- Workers raised from ~3.3 to 6 GiB RAM (~5.3 GiB allocatable). Done 2026-10-12.
- Longhorn applied 2026-10-12: both 98 GiB disks Ready, ~263 MiB RAM idle. Node
  prep done by hand on both workers: `multipathd` (service + socket) disabled
  (it grabs Longhorn's /dev/sdX devices, mounts then fail "already mounted";
  longhorn.io/kb/troubleshooting-volume-with-multipath), `dm_crypt` loaded (only
  for encrypted volumes). Longhorn's node conditions still showed both as stale
  (it hadn't re-checked); skipped a manager restart. A test PVC mounted fine.
  Drain-a-worker failover test still to do.
- kube-prometheus-stack applied 2026-10-12 (`terraform/k3s/monitoring.tf`, chart
  92.3.0, namespace `monitoring`, settings in `monitoring/kube-prometheus-stack.yaml`).
  Prometheus 8Gi + Alertmanager 1Gi on Longhorn (both healthy); 7d / 6GB
  retention; selectors pick up ServiceMonitors from any release; k3s's
  controller-manager/scheduler/proxy/etcd scraping disabled (localhost-only in
  k3s). All 21 targets up, only `Watchdog` firing. Stack uses ~965 MiB.
- Grafana: no PVC, served at `/grafana` via ingress-nginx (host-less, like the
  app). Because of the sub-path its own metrics are at `/grafana/metrics`
  (`grafana.serviceMonitor.path`). Admin password is chart-generated in Secret
  `kube-prometheus-stack-grafana`, never in git. Reach the app and Grafana from
  the laptop via the control node's Tailscale IP (the 10.10.60.x LAN IPs are not
  reachable from it). Grafana restarted twice on first install: liveness probe
  failed while it was still starting. Then its 384Mi memory limit was too low:
  it sat at ~372Mi, `/api/health` timed out, pod stayed not-ready, ingress gave
  503 and no dashboards showed. Limit raised to 768Mi (request 256Mi); it uses
  ~320Mi, 25 dashboards load. Stack total now ~1.1 GiB.
- Backend (2026-10-12, `9f4856a`): runs Gunicorn (1 worker, 4 threads: the
  prometheus-flask-exporter counters are per-process, so scale with pods, not
  workers) instead of the Flask debug server; `/metrics` via
  `PrometheusMetrics(app)` (cluster-internal only, not on the Ingress);
  requirements.txt trimmed from a ~50-package laptop freeze (UTF-16) to 4 pinned
  packages. Later (Week 6): container runs as root, switch to a non-root user.
- Chart: `backend-servicemonitor.yaml` wrapped in
  `.Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor"` so
  EKS (no Prometheus Operator) still installs. Backend Service needs
  `metadata.labels.app: tripsync-backend` and port name `http` (both Services
  now labeled). Verified 2026-10-12: backend target up, 22/22 targets up.
  Chart-only changes deploy on the next app pipeline run (the devops repo
  isn't polled). The Ingress strips `/api`, so paths in metrics have no prefix.
- EKS has no monitoring (by design). **Stretch item (decided 2026-10-12):**
  Amazon Managed Service for Prometheus for EKS, app metrics only:
  `aws_prometheus_workspace` + `aws_prometheus_scraper` (scrape config filtered
  to backend pods, needs an access entry), a read-only IAM user
  (`aps:QueryMetrics`) whose keys go in a k3s Secret, and a SigV4 datasource in
  the k3s Grafana. Cost reasoning: k3s Prometheus ingests ~4,350 samples/s (mostly
  cluster metrics), which would be ~$1,000/month at $0.90 per 10M samples if sent
  24/7; app-only while EKS is up fits the free tier. Do it in a future EKS session.
- Logs (2026-10-12, built by Claude at Roye's request, explanation pending):
  `terraform/k3s/logging.tf`. Loki chart 7.3.0 (Loki 3.6) in SingleBinary mode,
  filesystem storage on a 5Gi Longhorn volume, 7d retention (compactor), caches/
  gateway/canary off (`monitoring/loki.yaml`). Alloy chart 1.13.1 as a DaemonSet
  incl. the control node, tails /var/log/pods for its own node (HOSTNAME = node
  name), labels namespace/pod/container/app/node, strips the CRI wrapper, pushes
  to `loki:3100` (`monitoring/alloy.yaml`). Promtail is deprecated (chart marked
  deprecated, last release 2025-10). Grafana gets a Loki datasource via
  `grafana.additionalDataSources`. On first start each Alloy pod had one batch
  rejected as "too old" (old lines in existing files, older than 7d): expected,
  one-time. Monitoring namespace now ~1.8 GiB.
- Alerts + dashboard (2026-10-12, built by Claude, commented for later reading):
  `k8s-helm/tripsync/templates/prometheus-rules.yaml` (PrometheusRule, gated on the
  CRD like the ServiceMonitor): TripsyncBackendDown (up==0 or absent, 2m,
  critical), TripsyncFrontendDown (kube-state-metrics available==0, 2m, critical),
  TripsyncHighErrorRate (5xx >5% for 5m, warning), TripsyncSlowResponses (p95 of
  non-health paths >1s for 10m, warning). Generic failures (crash loops, not
  ready, target down, volumes filling) are left to the chart's ~134 built-in rules.
  Prometheus `{{ $value }}` is escaped for Helm. Dashboard: `dashboards/tripsync.json`
  + `templates/grafana-dashboard.yaml` (ConfigMap labeled grafana_dashboard=1, loaded
  by the Grafana sidecar from any namespace; UI edits are not saved back).
- Alertmanager -> **Discord** (`alertmanager.config` in kube-prometheus-stack.yaml):
  everything except Watchdog/InfoInhibitor goes to Discord, grouped by namespace +
  alertname, send_resolved. The webhook URL lives only in the Secret
  `alertmanager-discord` (key `webhook-url`, monitoring ns, created by hand with
  kubectl; must exist before Alertmanager starts), read via `webhook_url_file`
  from /etc/alertmanager/secrets/alertmanager-discord/. Config checked with
  `amtool check-config`; a hand-posted test alert routed to discord.
- **Session end 2026-10-12: Week 5 core done** (metrics, logs, alerts, dashboard).
  Open at the start of next session:
  1. ~~Discord delivery~~: confirmed by Roye 2026-10-14, the test alert arrived.
  2. ~~Explain what Claude built~~: done 2026-10-14 (Longhorn, Prometheus stack,
     Loki/Alloy, rules, Alertmanager, dashboard, Grafana's no-volume design).
     Roye wants a full end-to-end overview again when the project is finished.
  3. ~~Longhorn failover test~~: passed 2026-10-14. Cordoned k8sworker1 and deleted
     the Prometheus + Alertmanager pods (instead of a full drain, which would
     also evict the cluster's Zabbix stack, the single ingress-nginx controller
     and Longhorn components). Both came back Ready on k8sworker2 in <50s, Longhorn
     reattached their volumes there (healthy, 2 replicas), Prometheus's oldest
     sample (2026-10-12) and backend sample count were intact, 22/22 targets up.
     Worker uncordoned. Not tested: a hard worker loss (power off).
  4. ~~End-to-end alert test~~: done 2026-10-14. Backend scaled to 0 at 15:19:11
     UTC; TripsyncBackendDown active in Alertmanager at 15:22:18 (target gone,
     then the 2m `for:`), 1 Discord notification sent, 0 failures. Scaled back
     to 1 at 15:22:44; alert cleared at 15:23:34; resolved message sent ~15:28
     (2 sends, 0 failures). The resolved message waits for the group's next
     `group_interval` (5m after the first send), so a ~5 min lag is expected.
  **Week 5 closed 2026-10-14.** Stretch: managed Prometheus for EKS (above). Next: Week 6.

Week 6 + the online half of Week 7 (2026-10-16, built by Claude in one session,
**explanation to Roye pending**; tested locally, NOT yet pushed or deployed):
- Scope change: multi-account (see Scope). Data model Trip -> Days -> Stops.
- Backend restructured into a `tripsync/` package with `create_app()`; `app.py`
  only builds the app (Gunicorn still runs `app:app`). Flask-SQLAlchemy +
  Flask-Migrate (Alembic), psycopg 3, flask-jwt-extended (one 7-day access token,
  no refresh token: offline use), Flask-Limiter (login 10/min, register 10/h,
  per IP, in-memory, so it's per pod), Werkzeug scrypt password hashes.
  `flask-cors` removed: same origin everywhere (Ingress, compose gateway, Vite proxy).
- Offline-sync-ready model: UUID PKs the client may choose (create with an
  existing own ID returns 200 = idempotent retry; someone else's ID -> 409),
  `updated_at` on every row, soft delete (`deleted_at`). Every lookup goes through
  owner-checked helpers in `trips.py`; foreign rows are 404.
- ProxyFix `x_for=1` so rate limits see the client IP behind ingress-nginx.
  **Week 7 Cloudflare Tunnel adds a hop**: then the client IP is in
  `CF-Connecting-IP`; revisit ProxyFix/key_func then.
- Metrics: the exporter's `path` label is now the route template
  (`/trips/<uuid:trip_id>`) via a function named `path`, so no per-ID series and
  the existing rules/dashboard still match. Only the duration histogram has `path`.
- Readiness `/health/ready` now runs `SELECT 1`; liveness stays shallow.
- Image runs as uid 10001; the chart sets `runAsNonRoot`. `FLASK_APP` set in the image.
- Tests: 61 pytest (auth, CRUD, validation, metrics label, and `test_isolation.py`
  covering every ID-taking endpoint). Jenkins "Unit tests" stage: throwaway
  `postgres:18-alpine` on a per-build Docker network, `flask db upgrade`, then
  pytest with JUnit XML (needs the JUnit plugin). Passed locally on SQLite, on
  Postgres, and in a local run of the same commands on python:3.11-slim.
- Chart: `postgres.yaml` (headless Service + 1-replica StatefulSet,
  `postgres:18.6-alpine`, PVC 2Gi via volumeClaimTemplates, mounted at
  `/var/lib/postgresql` per the PG18 image layout), `secret.yaml` (Postgres
  password + JWT key generated once by Helm, kept via `lookup`, annotated
  `helm.sh/resource-policy: keep`), `_helpers.tpl` (backend env), backend
  `migrate` init container (`flask db upgrade` with retries; advisory lock in
  `migrations/env.py`), alert `TripsyncDatabaseDown`. Server-side dry run against
  k3s passed.
- **Deploy order matters**: push devops first (chart; not polled), then backend
  (its image has the migrations), then frontend. A frontend deploy that runs the
  new chart with an old backend image fails the init container (atomic rollback).
- EKS (untested, no cluster up): `aws-ebs-csi-driver` add-on, node role gets
  `AmazonEBSCSIDriverPolicy` (IRSA/Pod Identity would be stricter), Terraform
  `gp3` StorageClass (WaitForFirstConsumer, Delete, encrypted); both
  Jenkinsfiles' EKS branch sets `postgres.storageClassName=gp3`. `terraform
  validate` passes. Next EKS session: verify the PVC binds, and after destroy
  verify `aws ec2 describe-volumes` is empty (namespace deletion should delete the
  PVC, and the CSI driver the volume, before the cluster goes).
- Compose now has postgres + a one-shot `migrate` service; gateway forwards
  `X-Forwarded-For`. **Compose tested end to end 2026-10-16** (Docker Desktop is
  now on the laptop).
- Frontend: react-router 8 (declarative `BrowserRouter`), pages Login/Trips/Trip,
  token in localStorage (XSS trade-off noted in `api.js`), every change = one
  API call + re-fetch of the trip. Up/down reorder buttons, move stop to another
  day, coordinates pasted as "lat, lng", Google Maps link per stop. Node 20 ->
  24 in the Dockerfile and the ESLint stage (20 is EOL), Dockerfile uses `npm ci`.
  Verified with headless Chrome: full flow, light/dark, 390px and desktop, no
  console errors.

Next: Week 7 offline (service worker, local cache + sync queue using the
client IDs, Leaflet map for picking coordinates, Cloudflare Tunnel for HTTPS,
Jest stage); Week 8 export (PDF + Google Maps link), polish, final review.

## Scope (locked, do not silently re-expand)

**Multi-account** (changed from single-user on 2026-10-16, Roye's decision):
open sign-up, every trip private to its owner, no trip sharing, no email
verification or password reset (no mail provider). Every query is scoped to the
logged-in user, with a pytest per endpoint proving user A can't reach user B's
data (404, not 403, so IDs don't leak). Rate limits on login/sign-up. No Google Places API (stops entered manually); no full offline
tile prefetch (Workbox opportunistic caching only); export is PDF + Google Maps
link only (no GPX/KML); Jenkins stays outside Kubernetes by design. GitOps with
Argo CD is an **optional ~4h stretch sprint** after the core plan (it can be pulled
forward after Week 4); until then Jenkins deploys directly.

## Pipelines (design)

Each app repo has its own Jenkinsfile running on the agent labeled `k3s-agent`:

1. Checkout its own repo, plus this repo (for the chart)
2. Lint in throwaway containers, in parallel: `helm lint`, flake8 or ESLint
3. Unit tests: pytest against a throwaway Postgres (backend, done); Jest (Week 7)
4. Build the image, tag = short Git SHA of **that app repo**
5. Push to Docker Hub (`swagarot/tripsync-backend`, `swagarot/tripsync-frontend`)
6. Deploy: `helm upgrade tripsync k8s-helm/tripsync --atomic
   --set-string <service>.image.tag=$IMAGE_TAG`, branching on the `TARGET`
   parameter (choices `k3s` default, `eks`; polling builds always use k3s):
   - `k3s`: release in namespace `default`, using the agent's own kubeconfig.
   - `eks`: AWS credentials injected with `withCredentials`, a **separate**
     kubeconfig written into the workspace (`aws eks update-kubeconfig
     --kubeconfig "$WORKSPACE/kubeconfig-eks"`), release in namespace `tripsync`.

**Important:** `helm upgrade` recomputes values from `values.yaml` plus the
`--set` flags of that one command. A backend deploy that only sets the backend
tag would reset the frontend tag to `latest`. The planned fix is
`--reset-then-reuse-values` (needs Helm 3.14+, verify with `helm version`), so
each pipeline changes only its own tag. Tested and working: after a backend
deploy then a frontend deploy, both pods kept their own SHA tags. The two tags
differ by design (each is the SHA of its own repo).

Both Deploy stages wrap `helm upgrade` in `lock('tripsync-release') { ... }`
(Lockable Resources plugin), because the two jobs share one Helm release and a
concurrent upgrade fails with "another operation is in progress".

Lint gotchas: run containers as `-u $(id -u):$(id -g) -e HOME=/tmp` so files
aren't root-owned in the workspace. flake8 uses `--max-line-length=120`; files
must end with exactly one newline (W292/W391) and blank lines must be truly empty
(W293).

Jenkins is reachable only over Tailscale, so GitHub webhooks can't reach it. Use
SCM polling.

## Kubernetes and Helm facts

- Cluster: homelab k3s, one control node and two workers. **Traefik is
  disabled**; ingress-nginx is installed via its own Helm chart in namespace
  `ingress-nginx`.
- The cluster also runs a **Zabbix** stack in `default` (not part of TripSync; its
  Postgres uses the `nfs-client` StorageClass). Keep it in mind before draining
  a worker.
- The laptop's kubectl current context may still be a stale EKS entry; pass
  `--context default` for k3s.
- Namespace `tripsync` is owned by **Terraform** (`terraform/k3s`). The chart
  must never create it, and never use `--create-namespace` for TripSync.
- The Helm release `tripsync` is registered in the **`default`** namespace (first
  install had no `-n`), while the resources live in `tripsync`. Upgrade with
  `-n default`. `-n` is where Helm stores release metadata, not where resources go.
- Only resource manifests go in `templates/`; `Chart.yaml` and `values.yaml` stay
  at the chart root. Stray files outside `templates/` are silently ignored.
- **Two Ingress objects, on purpose.** ingress-nginx annotations apply to the
  whole Ingress object. One `rewrite-target: /$2` on a combined Ingress also
  rewrote asset requests to `/`, so nginx served `index.html` with `text/html`
  for JS files (white screen + MIME error). The fix is `tripsync-api-ingress`
  (`/api(/|$)(.*)`, regex + rewrite, `ImplementationSpecific`) and
  `tripsync-ingress` (plain `/`, Prefix, no annotations).
- When replacing an Ingress with a split pair, delete the old one first, or the
  ingress-nginx admission webhook rejects the duplicate path.
- Probes: liveness `/health/live` stays shallow (never checks the DB, or a DB
  outage would cause restart loops); readiness `/health/ready` checks the DB
  (`SELECT 1`). Frontend probes hit `/` on nginx.
- Flask must bind `0.0.0.0` in containers. Frontend nginx needs
  `try_files $uri $uri/ /index.html;`. The frontend calls the relative
  `/api/...` path (same origin through the Ingress, so no CORS in production).
- Image tags must be unique per build. With `latest`, Kubernetes sees no spec
  change and won't re-pull.

## Jenkins

- Controller: LXC `jenkins-controller` (Debian 13), port 8080, installed from the
  Jenkins apt repo using the **2026** signing key (the 2023 key no longer works).
- Agent: full VM `jenkins-agent`, node name and label `k3s-agent`, runs as the
  systemd service `jenkins-agent` under the unprivileged user `jenkins` (no sudo).
  Has Java 21, Docker, kubectl, helm, git and Tailscale. Its kubeconfig is at
  `/home/jenkins/.kube/config`. Admin work uses a separate sudo user.
- Credentials in the Jenkins store: the GitHub token, whose ID is an
  auto-generated UUID (not `github-creds`; copy it from the existing
  Jenkinsfiles; fine-grained tokens must be granted **each repo** the pipelines
  read), `dockerhub-creds` (Docker Hub access token), and `aws-access-key-id` /
  `aws-secret-access-key` (secret text, for the separate `jenkins-eks` IAM user,
  injected only in the EKS deploy branch). Reference them by ID, never inline.
- Use `--password-stdin` for `docker login`, triple-single-quote `sh` blocks that
  touch secrets, and `docker logout` in `post { always }`.
- Controller needs git installed (the job config's repo check runs there); the
  agent needs git for checkout.
- Built-in node executors should be 0 so nothing builds on the controller.

## EKS facts (learned the hard way)

- Cluster `tripsync-cluster`, region `eu-central-1`, Kubernetes **1.37** (bumped from
  1.35 on 2026-10-10; EKS GA October 2026, standard support until about December 2027; versions past standard support bill $0.60/hr for the
  control plane instead of $0.10, so check the EKS version calendar before bumping).
- The AWS account is on the **Free Plan**: EC2 instance types are restricted.
  `t3.medium` is NOT allowed (the node group just sat in "creating" with no
  instance). Use `c7i-flex.large` (2 vCPU, 4 GiB) or another type listed by
  `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`.
- Jenkins deploys with a **separate IAM user** (`jenkins-eks`, `eks:DescribeCluster`
  only) plus an EKS **access entry** (namespace-scoped `AmazonEKSEditPolicy` on
  `tripsync`). The user and its key are made by hand and stay outside Terraform
  (keeps the secret out of state, survives destroy); the access entry is in
  Terraform (`access_entries`, ARN via `data "aws_iam_user"`).
- A fresh cluster gets the `tripsync` namespace and ingress-nginx from
  `terraform apply`; the first pipeline run installs the app release.
- ingress-nginx's `type: LoadBalancer` Service gets a **Classic ELB**
  (internet-facing, in the 2 public subnets) on EKS 1.37, since the AWS Load
  Balancer Controller isn't installed. Nodes sit in the private subnet, no public IP.
- EKS pulls the public Docker Hub images (no ECR yet) through the NAT gateway.
- **Teardown:** `terraform destroy` alone works now: it uninstalls ingress-nginx
  first (which deletes the ELB), then the cluster and VPC. Verified 2026-10-10.
  Afterwards check `aws elb` / `aws elbv2 describe-load-balancers`, NAT gateways
  and EIPs are empty. The app release creates no AWS resources (ClusterIP
  Services, Ingresses only), so uninstalling it first is optional. **Since Week 6**
  the Postgres PVC is an EBS volume (EBS CSI add-on + gp3 class in Terraform);
  after destroy check `aws ec2 describe-volumes` too, a leftover volume keeps billing.
- Cost: the control plane, NAT gateway, node and load balancer all bill hourly.
  Never leave EKS running unattended.

## Minimal VPC module (`terraform/aws/modules/vpc`)

Written by Roye step by step (coached; route tables/associations with Copilot's
help), applied and proven 2026-10-10. Design decision:
**2 public subnets + 1 private subnet** (cheaper and simpler than 2 private).

Resources (about 14): `aws_vpc` (enable BOTH `enable_dns_support` and
`enable_dns_hostnames`), `aws_internet_gateway`, 2 public `aws_subnet`
(`count = length(var.zones)`, `map_public_ip_on_launch = true`), 1 private
`aws_subnet` in `zones[0]`, `aws_eip`, `aws_nat_gateway` (in public subnet 0),
2 `aws_route_table` (public, private), 2 `aws_route` (public 0.0.0.0/0 to the IGW;
private 0.0.0.0/0 to the NAT gateway), 3 `aws_route_table_association`. Tag public
subnets `kubernetes.io/role/elb = 1` and the private subnet
`kubernetes.io/role/internal-elb = 1` (verified in the EKS network-reqs docs; the
old `kubernetes.io/cluster/<name>` subnet tag is not needed since EKS 1.19).
With `enable_nat_gateway = false`, the EIP, NAT gateway and private default route
must not be created (use `count`), and the private subnet has no internet access.

Variables: `project_name`, `vpc_cidr`, `zones` (list), `public_subnet_cidrs`
(list, same order as `zones`), `private_subnet_cidr` (string),
`enable_nat_gateway` (bool, default true; the "size down" switch), `tags`
(map, default `{}`). Outputs: `vpc_id`, `public_subnets`, `private_subnets`
(a list of one), the same names as the community module, so the EKS block's
`module.vpc.vpc_id` / `module.vpc.private_subnets` references still work.

EKS consequence (verified in the EKS network-reqs docs): cluster subnets must be in
at least two AZs (public or private both allowed), and nodes may use subnets not
given to the cluster. So the plan is `control_plane_subnet_ids` = the 2 public
subnets and `subnet_ids` = the private subnet (nodes). All nodes then run in one AZ, which is acceptable here.

Things Roye should be able to explain: traffic path (ELB in public subnets, VPC
`local` route to NodePorts on private nodes, NAT is outbound only); why the NAT
needs an EIP and sits in a public subnet; `count` as the NAT switch; separate
`aws_route` vs inline routes; splat `[*]`; required vs defaulted variables;
outputs as a module's return values; no SGs in the VPC module (EKS module and
the cloud provider create them).

Open items:
- Backend `dynamodb_table` is deprecated, switch to `use_lockfile`.
- Cosmetic: NAT EIP/gateway Name tags use underscores, others use hyphens.
