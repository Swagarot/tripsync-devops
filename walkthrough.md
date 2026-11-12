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
| 2 | Docker images + compose | done 2026-11-08 |
| 3 | Kubernetes basics: Pod / ReplicaSet / Deployment / Service / Ingress, probes | mostly done 2026-11-08 (re-ask rollback/hashes) |
| 4 | Helm chart, template by template | next |
| 5 | Jenkins pipelines, stage by stage | |
| 6 | GitOps with Argo CD | |
| 7 | Networking: Cloudflare Tunnel, Tailscale, NodePorts, Grafana | |
| 8 | Storage: Longhorn, replica vs backup, backup CronJob + restore | |
| 9 | Observability: Prometheus, ServiceMonitor, rules, Alertmanager, Loki/Alloy | |
| 10 | Terraform: k3s + AWS (VPC module, EKS, IAM access entry, state lock) | |
| 11 | Security + tests (access.py 404 vs 403, isolation tests, token rotation) | |
| 11b | Secrets: Vault outside k3s, KMS auto-unseal, External Secrets, Tailscale-only (built 2026-11-06) | |
| 12 | The incidents | |

## AWS state and changes

Current state: **nothing running.** The EKS environment was last brought up
2026-10-28, smoke-tested, and destroyed the same day; AWS verified empty
afterwards (0 volumes, 0 load balancers, 0 non-default VPCs, 0 EIPs,
0 instances). What still exists on purpose: the Terraform state bucket and the
`jenkins-eks` IAM user. The DynamoDB lock table was deleted 2026-10-31.

Log any change to AWS here (date, what, why):
- **2026-11-06, terraform/vault applied by Roye:** KMS key
  `alias/tripsync-vault-unseal` (permanent, ~$1/month, prevent_destroy,
  30-day deletion window, rotation on), IAM user `tripsync-vault-unseal`
  (only kms Encrypt/Decrypt/DescribeKey on that key) + one access key (for
  the Vault container's .env). Why: Vault auto-unseal. Same apply installed
  the External Secrets Operator in k3s (chart 2.14.0).

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

## 2. Docker images + compose (2026-11-08)

**Covered.** Image (read-only package: OS userland + runtime + code + start
command) vs container (a running instance). Layers and the build cache: a step
is reused if it and everything before it are unchanged, hence "copy the
dependency list, install, then copy the code" in both Dockerfiles. Backend:
`python:3.11-slim`, `.dockerignore` (no tests, .env, .git), user UID 10001,
Gunicorn 1 worker x 4 threads (Prometheus counters live in process memory;
scale with pods). Frontend: multi-stage, `node:24-alpine` builds (`npm ci` =
exact lockfile versions), `nginx:alpine` serves `dist/` + `nginx.conf`.
Compose = the stack on a laptop, each service standing in for a cluster
piece: healthcheck = readiness probe, `migrate` = init containers,
`gateway` = Ingress, service names = Services, named volumes = PVCs.

**Side question: why do we need the root token / how does Vault work?**
Secrets are encrypted on disk; that key is encrypted by the AWS KMS key
(auto-unseal at start). Every access needs a token whose policies say what it
may do (ESO: 1 h, read-only on `secret/`; backup tokens: snapshot only). The
root token (made once by `vault operator init`) may do everything and never
expires: needed only for setup (Terraform's mounts/policies/logins, the
import). Normal practice: revoke after setup, regenerate from the recovery
keys when needed (`vault operator generate-root`). Details in 11b.

**Roye's answers and corrections.**
1. *One line changed in app.py: what rebuilds?* "Only the code copy." Right
   idea; precisely `COPY . .` **and every step after it** (a changed layer
   invalidates all later ones), so also the `useradd` RUN, which could move
   above the COPY. A changed `requirements.txt` re-runs `pip install` and
   everything after it (the slow case).
2. *What's in the frontend image?* Right: only the built HTML/JS/CSS (plus
   nginx itself and `nginx.conf`); no Node, `node_modules`, source. Why it
   matters: size (faster pulls on every node) and attack surface (fewer
   programs and fewer CVEs for an attacker to use).
3. *Why SHA tags, not just `latest`?* Roye: single source of truth, knew we
   know which commit runs, wanted the full explanation. `latest` is a
   **mutable** label: it points at a different image after every build, so
   (a) Kubernetes rolls out only when the pod spec changes; same tag `latest`
   = no change = no rollout; (b) nodes cache images, so two nodes can run two
   different "latest"s; (c) no way back: the old `latest` is gone. A SHA tag
   is **immutable** and maps pod -> image -> commit. Rollback = put the old
   tag back: that is exactly what `git revert` of a "Deploy backend <sha>"
   commit does (values-k3s.yaml gets the previous tag, Argo CD rolls it out:
   Roye's live demo). `latest` is still pushed, only for a first install from
   values.yaml defaults.
4. *How does the backend find "postgres"?* Right: compose puts the project's
   services on one network and Docker's built-in DNS resolves service names.
   In k3s, CoreDNS resolves Service names (full name
   `<name>.tripsync.svc.cluster.local`): a normal Service (backend,
   frontend, garage) -> its stable ClusterIP, which keeps working when pods
   are replaced and get new IPs. *Correction (found in topic 3):*
   `tripsync-postgres` is **headless** (`clusterIP: None`), so its name
   resolves straight to the pod's current IP; the name stays stable, DNS
   follows the pod.
5. *What user does the frontend run as?* Roye: "the same, probably". No:
   `nginx:alpine` starts its master process as **root** (workers as user
   `nginx`), and the chart's frontend Deployment has no `securityContext`.
   A real gap (found 2026-11-08). Fix option: `nginxinc/nginx-unprivileged`
   (runs as UID 101, listens on 8080) + chart port + `runAsNonRoot`.

**Side question: what is Flask?** A Python package (`pip install Flask`,
pinned in `requirements.txt`): a web *framework*, it maps URLs to Python
functions (`@bp.get("/trips/<id>")`), parses requests, returns JSON. It is
not the server: Gunicorn (also a package) is the production server that
listens on port 5000 and calls the Flask app (`app:app`, via WSGI). Java
comparison: Flask ~ a light Spring Boot / Javalin, Gunicorn ~ Tomcat. Flask
is small on purpose; the rest are extensions: Flask-SQLAlchemy (ORM),
Flask-Migrate (Alembic migrations), Flask-JWT-Extended (tokens),
Flask-Limiter (rate limits), prometheus-flask-exporter (/metrics).

**Fix from Q5, done 2026-11-08 (3 steps, so the site never broke):**
non-root nginx. Linux lets only root bind ports < 1024; instead of moving
nginx to 8080 (image + nginx.conf + chart + compose), the frontend pod got
the safe sysctl `net.ipv4.ip_unprivileged_port_start=0` (only inside its own
network namespace). (1) devops 932a0ea: sysctl (old root image unaffected);
(2) frontend 1a41f04: `nginxinc/nginx-unprivileged:alpine` (uid 101), still
port 80; (3) devops d70a805: `runAsNonRoot` (first would have refused the old root
image). Proven: without the sysctl, non-root nginx fails `bind() to
0.0.0.0:80 (Permission denied)`. Also backend 16b59c8: `useradd` moved
above the COPYs (cached layer).

**Quiz round 1 (2026-11-08).**
1. *`latest` and the revert demo.* Right: nothing changes in git's file, so
   Argo sees no diff and nothing happens. Plus: even a restarted pod would
   pull the newest `latest`, not the old version.
2. *Why copy requirements.txt first?* Unsure. Re-explained: Docker runs the
   steps top to bottom and caches each result; at the first step whose input
   changed it redoes that step and everything below. Code changes every
   commit, dependencies rarely; dependencies first = a code edit reuses the
   cached `pip install` (seconds instead of a minute).
3. *Flask vs Gunicorn.* Right: Flask = the framework the code is written
   with; Gunicorn = the running server, listens on 5000 and calls the app.
4. *Why non-root can't use 80.* Guessed "taken/default port". Re-explained:
   ports 0-1023 are privileged in Linux (only root or CAP_NET_BIND_SERVICE),
   historically so a normal user on a shared server couldn't pose as the web
   server. Not "taken": every container has its own network namespace and
   its own port 80. Order: each step must work with both the old and new
   image.
5. *Compose roles.* Unsure. Re-explained: `gateway` = Ingress; `migrate` =
   init containers (same backend image, `flask db upgrade` + `storage-init`,
   exits); `service_completed_successfully` = the backend starts only if
   migrate exited 0.
6. *Where images go.* Partly: Argo CD never watches Docker Hub. Chain:
   Jenkins builds -> pushes to Docker Hub -> commits the new tag to
   values-k3s.yaml -> Argo CD sees **git** -> updates the Deployment ->
   new pod -> the node's **kubelet** pulls the image. EKS: Jenkins runs
   `helm upgrade`, nodes pull from Docker Hub via the NAT gateway; proper
   AWS = ECR.

**Quiz round 2 (2026-11-08).**
- *a. Only trips.py changed / Pillow bumped.* Right both: no pip; then pip
  and every step after it.
- *b. Two containers on port 80.* Right: each has its own network namespace
  (its own network stack and ports; not a whole machine, the kernel is
  shared). Correction: being on the same Docker network is fine, each
  container has its own IP. The only clash is **publishing** the same host
  port (`ports: "8080:80"` twice): the host has one 8080.
- *c. Broken migration.* Partly. Compose: migrate exits non-zero, the backend
  never starts. k3s: the new pod's init container fails (`Init:Error` /
  `Init:CrashLoopBackOff`), it never becomes Ready, so the rolling update
  never finishes and the **old pod keeps serving: site up**. Postgres runs
  each migration in a transaction, so a failed one leaves no half-changed
  schema. Fix the GitOps way: `git revert` the "Deploy backend" commit (or
  fix forward with a new commit).
- *d. Order.* Push and commit swapped: Jenkins **pushes the image first**,
  then commits the tag (the other way, Argo could deploy a tag that doesn't
  exist yet -> `ImagePullBackOff`). And the pod object exists before the
  pull: Argo syncs -> Deployment changes -> new pod created and scheduled ->
  that node's kubelet pulls -> container starts.

**Final check (2026-11-08).** Both right: (1) Argo CD changes the
Deployment as soon as it sees the commit, so an image not yet on Docker Hub
-> the kubelet can't pull -> `ErrImagePull` / `ImagePullBackOff`. (2) Old
pod keeps serving, new pod's migrate init container errors; fix with `git
revert <the bad Deploy commit>`. Precision: revert adds a **new** commit
undoing that one (history intact, Argo sees a normal commit); going back to
an old hash would be `git reset`, which rewrites history: not on main.
**Topic 2 done.**

## 3. Kubernetes basics (2026-11-08)

**Covered.** Pod (containers sharing an IP + volumes; disposable: new
name/IP each time; backend pod = init containers `migrate`, `storage-init`,
then `backend`). ReplicaSet (keeps N identical pods). Deployment (manages
ReplicaSets: each new pod template = a new RS; live example: today's 3
non-root steps = 3 frontend RSs, old ones kept at 0, `revisionHistoryLimit:
3`). Default rolling update: maxSurge/maxUnavailable 25% -> with 1 replica,
surge 1 / unavailable 0: new pod first, old removed only once the new one is
Ready. Probes: liveness `/health/live` (stuck? -> restart; deliberately no DB
check), readiness `/health/ready` (`SELECT 1`; fail -> out of the Service,
no restart). StatefulSet (Postgres, Garage: fixed name `-0`, own PVC, never
two copies). Service (label selector; ClusterIP vs headless). Ingress (two
objects because rewrite-target applies to all paths; `/api/metrics` blocked).
AWS: same objects; EC2 node group, VPC CNI pod IPs, EBS gp3 via CSI,
ingress-nginx Service type LoadBalancer -> AWS ELB.

**Roye's answers and corrections.**
1. *Delete the backend pod.* Mostly: a new pod, not the same one, same
   image. Precision: the **ReplicaSet** notices (0 of 1 running) and makes
   it, not the Deployment directly. New name and IP, same template; the init
   containers run again (`flask db upgrade` is then a no-op).
2. *Postgres down 2 min.* Right: liveness keeps passing (no restart),
   readiness fails (pod out of the Service; the ingress answers 503 fast).
   Roye's question: *Postgres has its own readiness probe (`pg_isready`), why
   does the backend check too?* Each probe describes **its own pod**:
   Postgres's decides whether the Postgres Service sends to it; it tells
   nothing to the backend. The backend's answers "can THIS pod serve
   requests", which also fails on backend-side problems (wrong password,
   network, connection pool). Without it the ingress keeps sending users to a
   backend that answers 500s.
3. *Why a new RS per deploy?* Misconception: "the new RS comes from a new
   Deployment". There is **one Deployment** all along (tripsync-backend, 37
   days old); a deploy changes its pod template, and it makes a new RS for
   the new template. Roye's question: *on revert, old RS or new?* The **old
   RS**: the Deployment finds the RS whose template matches
   (`pod-template-hash`) and scales it back up, if it's still kept (3). Live:
   reverting "Deploy backend 16b59c8" would scale
   `tripsync-backend-58cff9668` (192bf28) from 0 to 1. Demo tip: run
   `kubectl -n tripsync get rs -w` during the revert to show it.
4. *How a Service finds pods.* Right: label selector; not-Ready pods get no
   traffic (Kubernetes keeps the endpoint list, EndpointSlice, up to date).
5. *Why StatefulSet.* Right: stable storage + only one at a time.
   Correction: one **in total** (replicas 1), not "per worker".
6. *A deploy step by step.* Right; plus: the new pod must finish its init
   containers and pass readiness before the old pod gets SIGTERM (grace
   period), and the Service moves traffic once the new pod is Ready.

**Round 2 (2026-11-08).**
- *a. A revert, git to pod.* Right outline, Roye unsure of the middle.
  Full chain: (1) `git revert` makes a **new** devops commit (its own hash)
  whose only change is `backend.image.tag: 16b59c8` -> `192bf28` in
  values-k3s.yaml (192bf28 = a backend-repo commit = the image tag); (2)
  Argo CD **polls** git (nothing is sent to it), renders the chart, diffs:
  only the backend Deployment's image differs; (3) it patches that
  Deployment's pod template; (4) the Deployment hashes the template (label
  `pod-template-hash`), finds RS `58cff9668` with the same hash and scales it
  0 -> 1 instead of making a new RS (same template = same RS); (5) that RS
  creates a **new pod** from the old template; (6) kubelet pulls (probably
  cached), init containers, readiness; (7) the Deployment scales the current
  RS 1 -> 0 and the old pod gets SIGTERM.
- *b. Wrong DB password.* Right: backend readiness fails (Postgres's own
  passes). Users: the frontend still loads (its own pod), but every `/api`
  call gets 503 from the ingress (no Ready backend); the app shows what the
  phone has cached offline; login fails.
- *c. Delete postgres-0.* Right: the StatefulSet recreates `-0` and
  re-attaches **its** PVC `data-tripsync-postgres-0` (from
  volumeClaimTemplates), same data. A Deployment's pods have random names
  and all share whatever claim the template names, so no per-pod volume, and
  a rolling update would mount it twice (a Longhorn RWO volume can't even
  attach on a second node).

**Rollbacks and hashes (2026-11-08; Roye: "mostly got it, keep asking").**
- *Does the old RS store the git hash?* No: the RS knows nothing about git.
  Three different hashes: the **devops commit** (git's ID for a change;
  Argo CD records the last one it synced in `status.sync.revision`); the
  **image tag** (`192bf28`, a backend-repo SHA that Jenkins uses as the
  image name; stored in the RS's frozen pod template as
  `image: swagarot/tripsync-backend:192bf28`, in `migrate`, `storage-init`
  and `backend`); the **pod-template-hash** (`58cff9668`, Kubernetes' own
  hash of the template's contents, the RS's label and name suffix). To
  Kubernetes the tag is just text; it means "commit" only because Jenkins
  names images that way. Revert brings back the same text -> same template
  -> same hash -> the same RS.
- *`--no-edit`?* Only skips the editor for the commit message (uses
  `Revert "Deploy backend ..."`). And `git revert X` **undoes X**, it doesn't
  "go back to X": later commits (e.g. the frontend deploy after it) stay.
  Going back to an old state (`git reset`) would take every difference since,
  both apps and chart changes.
- *Revert to a very old version with no RS left?* (1) Kubernetes just makes a
  new RS (reuse is only a shortcut), as long as the image is still on Docker
  Hub. (2) git: reverting an old deploy commit **conflicts**, every later
  deploy edited the same line; for an old version write the old tag and
  commit "Roll back backend to X". (3) The real limit, the **database**:
  migrations only go forward. Rolling back past one (e.g. before ad67625,
  which added `sessions`) -> old code's `flask db upgrade` fails ("Can't
  locate revision a7d2e5f8c9b1") -> init container fails -> old pod keeps
  serving, rollback doesn't happen. Code rolls back freely, schema doesn't.
  Demo: revert the latest backend deploy (16b59c8 -> 192bf28, no migration).
- Roye wants to try the revert himself (practice for the demo; steps were
  given: watch `kubectl -n tripsync get rs -l app=tripsync-backend -w`,
  `git revert --no-edit <Deploy commit>`, push, then revert the revert).

**To re-ask next session (Roye's request):** the three hashes and which one
picks the RS; why a revert reuses an RS but a new deploy makes one; revert vs
reset; why rollback can't cross a migration; what `kubectl get rs` shows
during a revert.

## Presentation prep (2026-11-12, talk on Friday 2026-11-13, 10 minutes)

**Deck:** claude.ai Slides artifact "TripSync – Infrastructure"
(https://claude.ai/artifact/EN832Ca6Z3pjyFS69wXSkB, private; downloads as
.pptx/PDF; speaker notes with timings on every slide). Roye: general
structure OK, refine tomorrow. Order: cover · the app (1-2 min live demo) ·
three repos · the whole platform (infra map) · inside the k3s cluster ·
CI/CD (Jenkins builds, Argo CD deploys) · GitOps statement · homelab stack ·
hybrid k3s vs EKS · **closing live demo: Argo CD rollback with git revert**.
Roye's changes: no incidents in the talk (not relevant); closing = rollback
demo, not "Questions?"; more Kubernetes detail (Deployments, StatefulSets,
DaemonSets) -> the "Inside the k3s cluster" slide. Open: maybe switch the
demo's revert line to the simpler `git log --oneline -3` + `git revert
--no-edit <hash>` (offered, not decided). Caveat in the hybrid slide's
notes: S3 + Pod Identity and EKS -> Vault are coded but not yet run on EKS.
Roye practiced the revert himself (8e13e51 Revert, 26febfb "Reapply" =
git's name for a revert of a revert); production back on 16b59c8.

**Questions Roye asked while building it (answers to remember).**
- *Does Longhorn only hold Garage?* No: every volume the cluster needs to
  run: Postgres (2 Gi), Garage (10 Gi), Prometheus (8 Gi), Loki (5 Gi),
  Alertmanager (1 Gi), each as 2 copies, one per worker. Only the backups
  (TripSync 30 Gi, Vault 1 Gi) are on the NFS server (`nfs-client`), on
  purpose outside Longhorn.
- *How does cloudflared reach the ingress?* The 2 cloudflared pods open
  **outbound** connections to Cloudflare and keep them open; a browser
  connects to Cloudflare (which holds the HTTPS certificate), Cloudflare
  sends the request down those connections, and cloudflared forwards it to
  `ingress-nginx-controller.ingress-nginx.svc:80` (route set in the
  Cloudflare dashboard); then the normal path (/api -> backend, rest ->
  frontend). Nothing connects in: no open ports.
- *Why `--no-edit`?* It only skips the editor for the revert commit's
  message (on Windows often Vim: getting stuck in it live is the classic
  demo failure); the default message `Revert "Deploy backend ..."` is used.
  It changes nothing about what gets reverted.
- *Why `$(git log -1 --format=%h --grep="Deploy backend")`?* To avoid typing
  a hash live: `--grep` keeps commits whose message contains "Deploy
  backend", `-1` the newest, `--format=%h` prints only its short hash, `$()`
  puts it into the revert command. It also matches "Revert ..."/"Reapply
  ..." commits, which is fine: it always undoes the latest backend change.
- *"Isn't there one Postgres on each worker, 2 total?"* No: **one Postgres
  pod** (StatefulSet, replicas 1; on k8sworker2 at the time). What's on both
  workers is its **volume**: 2 Longhorn replicas, every write goes to both.
  Worker dies -> Kubernetes restarts `tripsync-postgres-0` on the other
  worker, Longhorn attaches the copy already there, ~1 min downtime, no data
  lost. Two Postgres processes can't share a data directory (corruption);
  2 real instances = database replication (primary + standby, own data each,
  e.g. CloudNativePG): listed, deliberately not built.
- *"So if worker1 needs the DB it goes through worker2?"* Pods need it, not
  nodes. A pod connects to the name `tripsync-postgres`, DNS gives the pod's
  current IP, and pod IPs are reachable from every node (k3s's flannel
  overlay network): same node = local, else across the LAN (well under a
  millisecond). A user request already crosses nodes (cloudflared on worker1
  -> backend and Postgres on worker2), and Longhorn sends every write to the
  replica on the other worker too. Nodes are just capacity; Services and the
  pod network hide where things run.
- *"So the Postgres pod and volume don't matter, everything's in Longhorn?"*
  Half right. The pod barely matters (disposable, recreated in ~1 min). The
  Postgres volume **is** a Longhorn volume (not "also saved to" it); losing
  one copy doesn't matter. But a bad DELETE, a broken migration or
  corruption hits **both** copies instantly: that's what the nightly NFS
  backup is for (14 days). Line for the talk: "replicas protect against
  losing a machine, the backup protects against losing the data itself."
- Noticed: both cloudflared pods were on k8sworker1 (anti-affinity is only
  *preferred*). **Fixed 2026-11-12 by making cloudflared a DaemonSet**
  (Roye: "much easier to explain, it makes more sense"). A DaemonSet runs
  one pod on every eligible node; the control node's NoSchedule taint keeps
  it off there, so exactly one connector per worker (2 today; a 3rd worker =
  a 3rd pod = a 3rd connector, since each pod is one connector). Applied in
  two steps (DaemonSet first, then remove the Deployment) so the tunnel
  never dropped. Talk answer: "a DaemonSet, because I want one connector
  per worker; a Deployment's spreading is only a preference, and I saw both
  pods land on the same node."

## Collected for later topics

Things that happened between sessions, to go through when we reach the topic.

### For 11b (Vault): backups to NFS (2026-11-08)

- **Two snapshot copies, each with its own token** (policy `raft-snapshot`:
  take a snapshot + renew itself, nothing else; periodic 768h, so each run
  renews it and it dies 32 days after backups stop):
  1. the `backup` service in `vault/compose/docker-compose.yml`, into
     `./backups` on the LXC (undoes a deleted secret, not a lost machine);
  2. the `vault-backup` CronJob in k3s (`terraform/vault-config/backup.tf`),
     04:15 Israel time onto the NFS server, 14 kept, alert
     `VaultBackupMissing` (>26 h, or never succeeded).
- **Why k3s pulls instead of the LXC mounting NFS:** an unprivileged LXC
  can't mount NFS: the kernel refuses NFS mounts inside a user namespace
  (which is what "unprivileged" means), and a Docker NFS volume asks the same
  kernel. `features: nfs=1` only works for privileged LXCs, which would undo
  the isolation. Mounting on the Proxmox host and bind-mounting wasn't an
  option for Roye's setup. k3s already writes to NFS (`nfs-client`), so it
  fetches the snapshot over Tailscale.
- **Its token lives in Vault** (`secret/vault/backup`) and External Secrets
  syncs it in: no new exposure, k3s's policy can already read all of
  `secret/`. The snapshot is encrypted by Vault itself, so it is safe on NFS;
  restoring needs the AWS KMS key.
- Verified live 2026-11-08: `vault-2026-11-08.snap` (40.7 KB) on NFS, job 6 s.

### For 12 (incidents): three bugs getting that CronJob to run (2026-11-08)

1. **Token with a line ending.** Piping `vault token create` into
   `vault kv put` in PowerShell added `\r\n` -> Vault: "contains
   non-printable characters". Fix: the job trims the token.
2. **The 513 MB binary thrash.** The job used the `hashicorp/vault` image;
   its `vault` binary is 513 MB, the pod limit was 128 MiB, so the kernel kept
   evicting the binary's pages and reading them back (13k major page faults
   in ~3 min, `vault token renew` "hanging" with no logs). The same pattern
   as the Alloy incident (2026-11-06): a memory limit smaller than what the
   process needs resident = disk reads, not an OOM kill. Caught and stopped
   within minutes. Fix: `curlimages/curl` (about 10 MB) calling the two API
   endpoints the CLI uses (`POST /v1/auth/token/renew-self`,
   `GET /v1/sys/storage/raft/snapshot`). Lesson: a memory limit must cover
   the binary's resident size too; check `pgmajfault` in
   `/sys/fs/cgroup/memory.stat` when a pod is slow without being OOM-killed.
3. **HTTP 500 "no namespace".** A still-malformed token (Windows
   PowerShell 5.1 re-encodes text piped between programs). Vault answers 500
   for a token it can't even parse (a valid token without permission would be
   403). Fix: make the token and store it inside the Vault container in one
   `sh -c '... | vault kv put ...'`, PowerShell never touching it, then force
   an ESO refresh (`kubectl annotate externalsecret ... force-sync=...`). The
   broken token never worked and expires by itself in 32 days.
   Lesson: pipe secrets between programs in bash, not PowerShell 5.1.
4. **Same 500 with the root token, during the import.** Pasting the token
   into `read` in bash inside a Windows console left a trailing `` (Enter
   sends 
 there). Fix that worked: `unset VAULT_TOKEN`, so the CLI uses
   the token `vault login` saved in `~/.vault-token`. The script now trims
   the token anyway. Then all 4 ExternalSecrets synced; the routes key
   verified working (ORS 200).
