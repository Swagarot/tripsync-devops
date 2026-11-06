# TripSync walkthrough

Roye's full pass over the project, from small to big, one topic at a time
(decided 2026-11-03, started 2026-11-06). Each topic: Claude explains, Roye
answers check questions, gaps get corrected here. Every topic also says what is
different on AWS (EKS) compared to the homelab (k3s).

This file is committed: no secrets, tokens, account IDs or internal IPs.

## Status

| # | Topic | Status |
|---|---|---|
| 1 | The app and the 3 repos | done 2026-11-06 |
| 2 | Docker images + compose | next |
| 3 | Kubernetes basics: Pod / ReplicaSet / Deployment / Service / Ingress, probes | |
| 4 | Helm chart, template by template | |
| 5 | Jenkins pipelines, stage by stage | |
| 6 | GitOps with Argo CD | |
| 7 | Networking: Cloudflare Tunnel, Tailscale, NodePorts, Grafana | |
| 8 | Storage: Longhorn, replica vs backup, backup CronJob + restore | |
| 9 | Observability: Prometheus, ServiceMonitor, rules, Alertmanager, Loki/Alloy | |
| 10 | Terraform: k3s + AWS (VPC module, EKS, IAM access entry, state lock) | |
| 11 | Security + tests (access.py 404 vs 403, isolation tests) | |
| 12 | The incidents | |

## AWS state and changes

Current state: **nothing running.** The EKS environment was last brought up
2026-10-28, smoke-tested, and destroyed the same day; AWS verified empty
afterwards (0 volumes, 0 load balancers, 0 non-default VPCs, 0 EIPs,
0 instances). What still exists on purpose: the Terraform state bucket and the
`jenkins-eks` IAM user. The DynamoDB lock table was deleted 2026-10-31.

Log any change to AWS here (date, what, why):
- (none applied since the walkthrough started)

Planned 2026-11-06 (Roye's decisions, see CLAUDE.md "Sprint in progress"):
- S3 bucket for photos on EKS + IAM role via **EKS Pod Identity** (no keys).
  Code written 2026-11-06 (`terraform/aws/photos.tf`, `values-eks.yaml`),
  not applied: it's created with the cluster and destroyed with it.
- AWS KMS key + IAM user for **Vault auto-unseal**; lives permanently,
  ~$1/month. Vault itself is a container on a homelab machine outside k3s,
  Tailscale only (Roye's call 2026-11-06: in-cluster Vault is weak
  security-wise; Cloudflare exposure rejected, Vault has no public users).
- EKS joins Tailscale to reach Vault through the External Secrets Operator,
  which also brings the ORS key (real routes on EKS).

## 1. The app and the 3 repos (2026-11-06)

**Covered.** What TripSync does (trips -> days -> stops, invites as
editor/viewer, expense splitting, photos, exports, offline on a phone). The four
runtime pieces: frontend (React built by Vite into static files, served by
nginx), backend (Flask API under Gunicorn, port 5000), Postgres (data), Garage
(photo files, S3 API). `/api/...` goes to the backend, everything else to the
frontend. Three repos: backend and frontend (code, tests, Dockerfile,
Jenkinsfile each) and devops (Helm chart, Argo CD, Terraform, monitoring,
compose, docs). Jenkins commits "Deploy ..." changes into devops; Argo CD rolls
them out.

**Roye's answers and corrections.**
1. *Request path for a trip with photos.* Right: frontend -> backend ->
   Postgres; photos: backend -> Garage. Addition: the frontend files load once,
   then the **browser itself** calls `/api/...` (the frontend container never
   talks to the backend). The backend checks the login token and membership
   (`access.py`) before touching Postgres. Photos use **signed URLs** because a
   plain `<img src>` can't send the login token; the backend checks the
   signature, fetches the file from Garage and returns it. Garage is never
   reachable from outside.
2. *Why nginx and not Node for the frontend.* Unsure; guessed "because our
   ingress is nginx". Not the reason: they are two different nginx's (the
   frontend container's own nginx, and the cluster's ingress-nginx controller).
   Real reason: after `vite build` the frontend is just static files (HTML, JS,
   CSS). Node is only needed to **build** them, so the Dockerfile is
   multi-stage: `node:24-alpine` builds, `nginx:alpine` serves. A Node server
   would add a runtime with nothing to run. nginx is small, fast, and its
   config (`nginx.conf`) handles the SPA fallback (unknown paths -> index.html
   so React's router handles them), cache headers for `/assets/`, and no
   caching for the service worker.
3. *Why not one repo.* Right: update and deploy each part on its own. More
   reasons: each app has its own pipeline and builds only when it changes;
   deploy config lives apart from code, so its git log **is** the deploy
   history (every "Deploy backend abc123" commit) and Argo CD watches only it;
   different access (app developers don't need cluster config, Jenkins writes
   only to devops). Cost: a change across repos needs several commits, and
   local compose expects the repos cloned side by side.
4. *The `migrate` service.* Partly right. It migrates the **database schema**
   (tables and columns) when the backend's models change, with
   `flask db upgrade` (Flask-Migrate / Alembic, files in
   `tripsync-backend/migrations/`). The data stays in Postgres the whole time;
   only its structure is updated. Nothing to do with the frontend. It also
   runs `flask storage-init` (Garage layout, bucket and key). It runs once,
   exits, and the backend starts only after it succeeded. In the cluster the
   same two commands are **init containers** of the backend pod (topic 4).

**Follow-ups Roye asked (2026-11-06).**
- *How the browser calls the backend.* The page's JavaScript runs in the
  browser; `api.js` is the one place that sends requests, always to a
  relative path `/api/...`, so they go to the same site the page came from.
  The Ingress sends `/api` to the backend (stripping `/api`), the rest to the
  frontend. Same origin = no CORS. Login: `POST /api/auth/login` returns a JWT,
  stored in localStorage and sent as `Authorization: Bearer ...` on every
  request; the backend checks its signature (no session lookup) and
  `access.py` checks membership. Expired/invalid token -> 401 -> login page.
- *Photos, corrected picture.* The browser never talks to Garage. Trip data
  from the backend includes each photo's URL, e.g.
  `/api/photos/42/thumb?exp=...&sig=...`, signed by the backend with an HMAC
  of (id, size, expiry) using a server secret. The browser loads it with
  `<img src>`; the backend checks expiry + signature, reads the bytes from
  Garage (S3 API, inside the cluster) and returns them. Expiry = end of next
  month, so the URL stays stable and the service worker can cache it offline.
  Why signed: `<img src>` can't send the Authorization header.
- *Build vs run (Roye's Java comparison).* Right: Node is like the JDK, only
  needed to compile; the output (static files) doesn't need it. nginx isn't a
  JRE (the browser runs the JS); it's just a file server, closer to "the
  website hosting".
- *Does Flask control the DB?* Postgres is its own server and owns the data.
  The backend talks to it through SQLAlchemy (an ORM: Python classes in
  `models.py` <-> tables). Flask-Migrate (Alembic) keeps versioned migration
  scripts in `migrations/`; `flask db upgrade` applies the ones the DB hasn't
  had yet (Alembic records the current version in table `alembic_version`).
- *Argo CD setup:* short preview given; full topic is #6.
- *"Jenkins listens on each repo, but how does Argo deploy?"* (2026-11-06)
  Jenkins **polls** (every ~5 min; GitHub can't reach the homelab, so no
  webhooks). Jenkins never deploys on k3s: its Deploy stage changes one line
  (`backend.image.tag`) in `tripsync-devops/k8s-helm/tripsync/values-k3s.yaml`
  and pushes a "Deploy backend <sha>" commit. Argo CD (a pod in k3s) polls
  tripsync-devops (~60 s), renders the chart with values.yaml +
  values-k3s.yaml, diffs it against the cluster, and applies the difference
  (the Deployment's image tag); Kubernetes then does the rolling update
  (migrate init container, readiness, old pod removed). Seen live
  2026-11-06: `955164c Deploy backend ad67625` -> live a minute later.
  Why: Jenkins holds no cluster credentials; the cluster pulls; git log =
  deploy history, git revert = rollback. EKS stays push (Jenkins runs
  `helm upgrade`) for contrast.
- *"So on k3s we don't really use Helm?"* Right: Argo CD only uses Helm as
  a template engine (`helm template` in its repo-server), then owns the YAML;
  no Helm release, history or rollback (git does that). Effects: `lookup`
  returns nothing (generated-Secret workaround), `.Release.Name` from
  apps.yaml, `.Capabilities` from the real cluster, Helm hooks -> Argo hooks.
- *"Does anyone use Helm like this, is it prod-ready?"* Yes: standard Argo CD
  behaviour, widely used in production. Alternatives: Flux helm-controller
  (real Helm releases), "rendered manifests" (CI commits the helm template
  output). Our homelab-sized gaps to name in the defense: generated secrets
  in the chart (prod: External Secrets/Vault or Sealed Secrets - started),
  one environment straight to prod (prod: staging + promotion,
  ApplicationSets), Argo UI on http NodePort (prod: TLS + SSO + RBAC).
- *Straight lines on AWS.* Routes between a day's stops (walk/bike/drive)
  come from OpenRouteService, which needs an API key (a k8s Secret on k3s,
  created by hand, not in git). EKS has no such Secret, so `/routes` answers
  503 and the map draws straight lines between stops, without travel times.
  Transit uses Transitous (no key). Deliberate: one less secret to manage for
  a test environment.
- *Photos on AWS.* Same as the homelab: Garage runs in the cluster from the
  same chart; its volume is EBS `gp3` instead of Longhorn. Differences: one
  EBS volume in one AZ (no replica across nodes; EBS itself is replicated
  inside its AZ), no nightly backup (needs the homelab's NFS), and teardown
  deletes the volume, so photos on EKS are throwaway. The "real" AWS answer
  would be S3 itself (the backend already speaks S3, so it'd be config:
  endpoint, bucket, credentials), not done.

**Second check (2026-11-06).**
1. *Change `exp` on a photo URL to 10 years ahead.* Roye: "nothing, once
   they get the photo it's already out of Garage, read only". Wrong reason:
   the signature is an HMAC over `id:size:exp`, so a changed `exp` no longer
   matches `sig` -> **403**, and nothing is read from Garage. Computing a new
   `sig` needs the server secret (`JWT_SECRET_KEY` + ":photos"). What IS true:
   anyone holding a still-valid link can open that one photo (size) until it
   expires, without logging in; that's the accepted trade-off.
2. *Stolen token.* Right: full access as that user. Details: it works
   **online, from any device** (it's just a header), for up to **7 days** from
   when it was issued. No refresh tokens (deliberate: offline for days must
   not lock you out, `config.py`). Each login issues a new token, but older
   ones stay valid until they expire: there is no logout-everywhere /
   revocation. Emergency fix: rotate `JWT_SECRET_KEY`, which invalidates every
   token and every photo link for all users. Defense: React escapes rendered
   text, so injecting a script to steal it is hard (XSS is what reads
   localStorage).

**On AWS.** Same app, same images, same chart. Different underneath: EKS
instead of k3s; storage is EBS `gp3` instead of Longhorn; traffic comes in
through an AWS load balancer in front of ingress-nginx instead of the
Cloudflare Tunnel; Jenkins deploys with `helm upgrade` (parameter
`TARGET=eks`) instead of Argo CD; no ORS key there, so routes are straight
lines. Details in topics 5, 6 and 10.

**Doc fixes found:** none yet.
