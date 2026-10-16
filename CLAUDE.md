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

- **Deployed to k3s 2026-10-16** (backend `ccd241f`, release rev 46): Postgres on
  Longhorn, tables migrated by the init container, readiness green. Rev 44 had
  failed first: an upgrade ran the new chart with the OLD backend image (tag
  9f4856a) about 5 min before the new image existed; its migrate init container
  hit `runAsNonRoot` (old image runs as root), helm --atomic rolled back (rev 45).
  Origin of rev 44 unknown (a manual build?). Ask Roye.

Week 7 (2026-10-16, built by Claude, **explanation pending**), frontend `dd96e9b`:
- Offline-first store (`src/store/`): every edit is an "op" (`ops.js`, pure,
  idempotent apply + `toRequest`). `store.js` keeps base copies (last server
  list / trips) and an outbox in IndexedDB (idb-keyval); the screen shows
  base + pending ops (`hooks.js`, useSyncExternalStore). The sync loop sends the
  outbox in order. Retry on no network / 5xx / 429 / 401; drop + show a message
  on other 4xx; DELETE 404 = done. After syncing it refreshes from the server.
  Logout wipes the device copy (with a warning if changes are unsynced); a 401
  keeps it, and a different user logging in clears it.
  Refreshes wait for the store to load (`loaded` promise; a race found over http).
  `newId()` falls back to `crypto.getRandomValues` on plain http (randomUUID needs
  a secure context). Auth works offline (user cached; only 401 logs out).
- PWA: vite-plugin-pwa 2 (generateSW, registerType `prompt` + update banner),
  manifest + icons (`public/`), navigateFallback to index.html except `/api/`,
  OSM tiles CacheFirst (1000 tiles / 30 d, opportunistic only per scope).
  nginx: no-cache for index.html / sw.js / manifest, immutable for `/assets/`,
  manifest MIME type set.
- Leaflet 1.9 + react-leaflet 5 (lazy-loaded chunk): trip map (pins per day,
  colours shared with day badges, lines in visit order), "Pick on map" in the stop
  form. divIcon pins (default marker images break under bundlers).
- **Vitest instead of Jest** (Roye's decision 2026-10-16): 34 tests (ops,
  sync queue against a fake server, storage per user, start-up race, helpers).
  Jenkins "Unit tests" stage reuses the ESLint stage's node_modules, JUnit XML.
- Verified with headless Chrome on compose: offline reload, offline edits +
  new trip, survive reload, sync on reconnect (server state checked), and the full
  flow over plain http on a non-localhost address.
- Backend `3ebfba2`: rate limit keyed on `CF-Connecting-IP` when present (all
  tunnel traffic arrives from cloudflared pods). Accepted gap: LAN/Tailscale
  clients could spoof that header.
- Cloudflare Tunnel: `terraform/k3s/tunnel.tf` (cloudflared 2026.10.1, 2
  replicas, anti-affinity, `/ready` liveness, read-only root FS), token from
  Secret `cloudflared-token` (key `token`, ns `tripsync`, created by hand). Remotely
  managed tunnel; public hostname route in the dashboard ->
  `http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80`.
  **Applied 2026-10-16; live at https://tripsync.royerandomnonsense.uk** (2
  connectors, Haifa + Frankfurt edges). Offline e2e (service worker, IndexedDB,
  sync) passed against the public URL; the test account was deleted afterwards.
  Gotchas: the token Secret first held literal quotes (Windows `cmd` keeps `'`;
  use `"` or none), so cloudflared said "token is not valid". The dashboard wizard only
  offers the hostname step once a connector is connected, so apply first.
  `/api/metrics` was publicly reachable through the `/api` Ingress (it was
  already reachable over Tailscale before): the API Ingress regex now excludes
  `metrics` (`f1c51fc`, deploys with the next app pipeline run).
  Cloudflare's default Browser Cache TTL (4h) overrides nginx `no-cache` on
  `sw.js`: set Caching -> Browser Cache TTL to "Respect Existing Headers".

Wanderlog-style features (2026-10-16, built by Claude, **explanation pending**;
Roye picked: free place search with photos, map-first view, drag and drop,
travel times):
- Backend `tripsync/places.py`: `GET /places/search?q&lat&lng` -> Photon (lang en,
  biased to the trip's centre), `GET /places/<N|W|R><id>` -> Nominatim lookup
  (extratags: hours, website, phone, fee, wheelchair, cuisine, wikidata) ->
  Wikidata (enwiki title + P18 image) -> Wikipedia REST summary. No wikidata tag:
  Wikipedia geosearch within 150 m + name match (word-set + char similarity,
  >= 0.75; Roye's "by name" idea made location-safe). P18 photo beats Wikipedia's
  lead image (Eiffel Tower's is a logo). In-process TTL caches (24 h / 7 d),
  Nominatim spaced to 1 req/s (its policy), User-Agent names the app, http(s)-only
  URLs reach the page. Prometheus counters `tripsync_places_upstream_requests_total`
  and `tripsync_places_cache_total`. Overpass was tried and rejected: its public
  server is overloaded and asks automated apps not to use it.
- Migration `6216cec9128c`: stops get osm_ref, category, photo_url, website,
  opening_hours (a copy, so they show offline); days get travel_mode. All nullable
  (expand rule). New deps: requests, cachetools. 78 pytest (places fully mocked).
- Frontend: "+ Add a place" = type-ahead search (300 ms debounce, stale answers
  ignored) -> details card -> add; "Add by hand" kept. Trip page is map-first:
  itinerary left, sticky full-height map right (map on top on phones); hover a
  stop = highlighted pin, click a pin = scroll to the stop, search results =
  temporary grey pins. Drag and drop with @dnd-kit (core 6.3.1 / sortable 10):
  grip handle, mouse 5 px / touch 200 ms hold / keyboard; a drop becomes
  reorderStops or moveStop + reorderStops ops (works offline). Stop rows show
  photo, category, hours, website; straight-line distance between stops. Wikimedia
  photos cached by the service worker. Fixed: a change made during a sync's final
  refresh waited for the 30 s retry (flush now loops; test proves it).
- Routes (backend `5e7f6c8`, frontend `27f5e1d`): `POST /routes {mode, points}` ->
  OpenRouteService (foot-walking / cycling-regular / driving-car, instructions on
  only to get per-leg `segments`; steps dropped), geometry flipped to [lat, lng].
  **This key's quota is 200 directions/day** (X-Ratelimit-Limit header, not the
  2,000 often quoted). So: backend TTL cache (7 d, points rounded to 5 decimals),
  frontend keeps every route in IndexedDB by mode+points (`src/trip/routes.js`,
  422 "no route" remembered, 503/quota not), requests debounced 800 ms after the
  stops stop changing, and straight-line fallback everywhere. Key: Secret
  `openrouteservice` (key `api-key`, ns `tripsync`, by hand, Roye 2026-10-16),
  `ORS_API_KEY` env with `optional: true` (EKS has none -> 503 -> straight lines).
  Compose takes `ORS_API_KEY` from the shell. Counters
  `tripsync_routes_upstream_requests_total{outcome}` / `tripsync_routes_cache_total`.
  Also fixed: "Add to day" waits for place details, so a quick tap no longer
  saves a stop without photo/hours.
- "Where to?" (migration `cf9844cd1d94`): trips get destination, dest_lat,
  dest_lng, dest_zoom (search results now carry a zoom: country 5, city 11...).
  Empty trips open the map on the destination; place search is biased to it; a
  blank name becomes "Trip to <destination>". The map can't leave the world
  (minZoom 2, maxBounds, noWrap). Wide screens: itinerary 480-720 px on the left,
  map takes the rest (Roye's 2000 px screenshot showed a world map with a grey band).
- Map-first redesign (2026-10-16, Roye's spec; backend `c2591e1`, frontend
  `a6cd48a`, migration `5f9384175d2d`, **explanation pending**): trip page = full-
  screen map + frosted panel (desktop, `color-mix` + `backdrop-filter`, solid on
  hover/focus, collapsible) / bottom sheet with peek-half-full snaps (phones).
  Tabs: Itinerary, Ideas (saved places, hollow pins, "Add to day" = createStop +
  deleteItem), Expenses (entered in paid currency, totals in trip.home_currency via
  ECB rates from Frankfurter, cached in IndexedDB), Notes + checklist, Weather
  (Open-Meteo 16-day forecast per ~10 km cell; rules in `src/trip/weather.js`:
  storms, heavy rain >=70% & >=5 mm, snow, >=35°, <=-5°, wind >=50 km/h; outdoor
  stops by category regex are named in the warning; badge on the Weather tab).
  Backend: `extras.py` = one generic owner-checked CRUD for ideas/expenses/checklist
  (`/trips/<id>/<kind>`, `/<kind>/<id>`), Numeric(12,2) money; `travelinfo.py` =
  `/rates`, `/weather` (cached); GET /trips adds `preview` (days, places, <=50
  points, first photo) for the cards (cover photo + non-interactive Leaflet mini
  map). Frontend ops gained createItem/updateItem/deleteItem(kind). Stops/days
  keep only the grip + text visible; actions behind a "⋯" toggle. Category emoji
  when a place has no photo. Fixed: routes were drawn DASHED (Leaflet keeps
  dashArray when only the style changes; route vs straight line now have different
  keys). Gunicorn 26 control-socket error fixed (user gets a home dir).
  Ratings: none (no free legitimate source; Google Places has a free monthly cap
  but needs billing + restrictive terms; decided against). 116 pytest, 49 Vitest.
- Routes round 2 (2026-10-16, after Roye's screenshot of Haneda -> Tokyo Tower as a
  straight line): ORS said "Could not find routable point within 350 m" (the
  airport's pin is mid-airfield; OSM even tags Haneda as an island). Fix:
  `radiuses: 2000` per point. Device route cache key bumped to `v2|` so stored
  "no route" answers are forgotten.
- **Public transport** (Roye asked): `tripsync/transit.py`, Transitous
  (transitous.org, free community MOTIS router over open GTFS, no key; covers
  Tokyo and Lisbon, verified). One plan per consecutive pair at ~10:00 local
  (tz guessed from longitude), max/pre/post walk 45 min, best of 3; dates more
  than 30 days out or past use the next same weekday (timetables are published
  only weeks ahead; the UI says "times for a typical Wednesday"). Encoded
  polylines (precision 6) decoded server-side; response adds `parts` (each ride
  in its GTFS route colour, walks dotted) and `steps` (badges). Line labels:
  short code if <= 5 chars, else Latin part of the long name, else agency (Toei
  sends "2966211"). Cached 12 h per pair+date. 124 pytest, 50 Vitest.
- "Where to?" suggestions keep Photon's relevance order (areas before single
  places only); sorting by size put the airport (island) above the city.
- Language for names (2026-10-16, Roye: "a global user can't read this"): header
  picker (en, he, es, fr, de, it, ja, zh, ko; stored on the device,
  `src/settings.js`). Map: OpenFreeMap vector tiles (liberty style, free, no key)
  drawn by MapLibre GL 6.11.2 inside Leaflet via @maplibre/maplibre-gl-leaflet
  (so pins/routes/drag-and-drop are unchanged); every name label's text-field is
  replaced by coalesce(name:<lang>, name:en, name:latin, name). RTL (Hebrew) via the
  bundled mapbox-gl-rtl-text plugin. Gotchas: maplibre-gl 6 has NO default export
  (the build then fails with a misleading "filename ... Received '.'"), its worker
  must be bundled with `?worker&url` + `setWorkerUrl`, the rtl package's exports
  hide dist/ (imported by path). Trip-card mini maps stay raster (WebGL context
  limit ~16). MapLibre chunk ~1 MB (277 kB gz), trip page only, precached.
  Transit: Transitous `language` param; rides show mode name, from -> to station,
  minutes, changes (Japan's GTFS has English, not French/Hebrew).
  Details: Nominatim accept-language + Wikipedia in the user's language when that
  wiki has the article (else English). Photon only supports en/de/fr.
- **Decided next (Roye):** personal ratings + own photos per stop (keep famous
  photos, own photo can be the cover), photo storage = object storage. **MinIO's
  Docker Hub repo is gone (404; MinIO stopped free images in 2025)** -> use
  **Garage** (dxflrs/garage v2.4.1, S3-compatible, maintained). Then a downloadable
  single-file HTML keepsake (offline forever: itinerary, ratings, notes, photos,
  map image).
- Memories (backend `ba9c3ab`, frontend `7c142f8`, migration `34de9c31a0f6`): stop
  rating (1-5), visited, cover_photo_id; `stop_photos` table; photos.py: upload
  (multipart, Pillow: must decode, exif_transpose, <=2048 px JPEG + 480 px thumb,
  EXIF/GPS stripped, 50 MP bomb limit, max 15 MB, 30/stop), signed URLs (HMAC of
  id+size+exp, exp = 1st of month after next, so URLs are stable for SW caching;
  <img> can't send the JWT), delete removes the objects. storage.py: boto3 S3
  client (path-style) + `flask storage-init` (admin API v2: layout if no role,
  CreateBucket, ImportKey with OUR Helm-generated key, AllowBucketKey; 409 =
  already done). Frontend: ☆ per stop -> stars, "Been here", photo grid, ★ = cover;
  photo upload queue in IndexedDB (works offline, retries like the outbox).
- Garage in the chart (`templates/garage.yaml`): 1-node StatefulSet,
  dxflrs/garage:v2.4.1, uid 1000 + fsGroup, 10Gi (Longhorn; EKS gp3 via the
  postgres class), secrets as env (GARAGE_RPC_SECRET/ADMIN_TOKEN). Readiness is a
  TCP check on 3903, NOT /health: /health is 503 until the layout exists, and
  storage-init sets the layout through the Service -> deadlock otherwise.
  Backend `storage-init` init container (non-fatal after ~2 min). Secret
  template now generates each key separately with `dig` (old Secret keeps the
  Postgres password + JWT key; verified against the live Secret by hash). API
  Ingress `proxy-body-size: 16m`. Alert TripsyncPhotoStorageDown.
  Compose gotcha: an unquoted all-digit hex secret is a YAML number -> quote it.
- **Storage topology decision (Roye, 2026-10-16): option A**, one Garage node on
  Longhorn (2 replicas), same ~1 min failover story as Postgres. Tested locally: 2
  Garage nodes with replication 2 keep READS up with one node down but REFUSE
  WRITES ("Could not reach quorum of 2"); real write availability needs 3 nodes
  (would mean a pod on the control node). Postgres is the app's availability limit
  anyway. Roye's "one shared Longhorn volume" idea = RWX = NFS share-manager;
  rejected for photos (locking, SPOF, not S3-portable, harder backups).
- **Backups (decided): nightly to the NFS server** (`nfs-client` StorageClass):
  pg_dump + rclone sync of the photo bucket. Same building, so not disaster-proof;
  R2 (10 GB free) discussed as the offsite option.
  Built: `templates/backup.yaml` (rendered only if the `nfs-client` StorageClass
  exists, via `lookup`), PVC `tripsync-backups` (30Gi, keep; the class has
  archiveOnDelete=true), CronJob 03:30 Asia/Jerusalem, Forbid concurrency:
  init container pg_dump -Fc (14 days), then rclone 1.75.1 sync of the bucket with
  --backup-dir for deleted photos (30 days), LAST_RUN.txt. Alert
  TripsyncBackupMissing (>26 h since kube_cronjob_status_last_successful_time).
  Restore guide: `docs/backup-restore.md` + `docs/restore-photos-job.yaml`.
  **Verified live 2026-10-16:** storage-init bootstrapped Garage in the cluster;
  photo upload/rating/offline-queue e2e passed on the public URL; a manual backup
  Job wrote the dump (17 KB) + photo mirror to NFS; the dump was restored into a
  scratch DB (`restore_check`) with identical row counts and migration version,
  then dropped. Test account + its Garage objects deleted afterwards.
- WebGL2 fallback (frontend `db28b78`): Roye's PC browser has no WebGL2 (graphics
  acceleration off / GPU blocklisted; check chrome://gpu), MapLibre threw
  "WebGL2 is required" and the map crashed. BaseMap now checks
  `canvas.getContext("webgl2")` and falls back to OSM raster tiles (local-language
  labels, note in the attribution). Tested with Chrome `--disable-webgl2`.
- Polish round (2026-10-16; keepsake and EKS postponed by Roye):
  - Performance, measured: GET /trips/<id> was 40 SQL queries for 5 days x 6 stops
    (N+1 lazy loads) -> selectinload `FULL_TRIP` = constant (<= 8), regression test
    `test_trip_page_query_count_does_not_grow_with_the_trip`. nginx had no gzip:
    main JS 375 kB on the LAN/Tailscale path (Cloudflare already brotli'd the public
    site) -> gzip on, 87 kB. Route-level code splitting (TripPage 91 kB own chunk,
    main 376 -> 277 kB). Leaflet divIcons cached by look (they were recreated on
    every render, so every hover redrew all pins).
  - Transit: Haneda pin mid-airfield made the fastest-by-duration choice a loop
    (T3 -> Tenkubashi -> T3) / pointless terminal hop. Now: drop itineraries that
    revisit a station, score = duration + 7 min per change, ask for 5. Live: direct
    Keikyu, 62 min, 0 changes. Better still: search "Haneda Airport Terminal 3".
  - "Find place details" (stop ... menu, only for stops without osm_ref): place
    search prefilled with the stop's name; picking fills name/category/address/
    position/photo/hours (rating, own photos, notes kept). For stops typed by hand
    offline.
- Google-Maps-style UI (2026-10-16, Roye's spec): trip page has no app header;
  floating search bar (PlaceSearch `compact`: ☰ inside, results drop down, place
  card has an "Add to" select: any day / a new day / Ideas, resets afterwards)
  and a square full-height drawer, closed by default, from the left or the right
  for RTL languages (`RTL_LANGUAGES` in settings.js; only layout is mirrored, the
  UI text stays English). Phone: bottom sheet (peek 150 px = name + tabs, ☰ =
  half). App menu (`components/AppMenu.jsx`: all trips, names language, theme,
  account) in the drawer footer and in a header popover on other pages. Themes
  light / dark / dim (Twitter's navy) via <html data-theme>, "system" follows the
  OS live; map style per theme (OpenFreeMap liberty / dark / fiord); picture
  tiles get a CSS invert filter in dark themes. Map only refits when pins change
  (not when the drawer toggles) but pads for the drawer/search bar.
  Zoom +/- moved to the side away from search/drawer (topright; topleft for RTL;
  below the search bar on phones).
- Stays / lodging (backend `a6574bd`, migration `edd21af5869e`): `lodgings` is a 4th
  extras kind (name, place fields, check_in, check_out, bookends default true;
  check_out >= check_in checked on create and update). Frontend `src/trip/stays.js`:
  `dayEnds(day, lodgings)` = stays covering the date with bookends; moving day
  (check_out of one = check_in of another) starts at the old, ends at the new;
  `dayPoints` = [start, stops with coords, end] -> used by routes (dayRouteRequest),
  leg numbering (legInto), the map (straight fallback + pin-to-road connectors) and
  the 🛏 pin. Itinerary shows "Where you're staying" (dates, nights, switch) and
  Start/End rows per day. Quick-add target "Where I'm staying" (dates = trip dates).
- Dark/Dim visibility (measured): text was fine (>= 5:1) but control borders were
  1.3-1.5:1 -> `--control-border` (dark #696a68, dim #6a7078, both >= 3:1 = WCAG
  non-text minimum) on buttons/inputs/selects/empty stars; Leaflet controls,
  tooltips and attribution themed (scoped under .trip-screen because leaflet.css
  loads later and wins otherwise); route lines get a light casing (agency colours
  like Oedo navy vanished on dark maps); walking dots light grey on dark maps.
- Home button (frontend `cbed96b`): house icon -> "/" in the search bar (after ☰)
  and at the top of the drawer (before the trip name); Roye couldn't find a way
  back to the trips list (it was only in the drawer's menu).

**State at the end of 2026-10-16 (one long session, all built by Claude):**
deployed on k3s and public at https://tripsync.royerandomnonsense.uk; backend
155 pytest, frontend 55 Vitest, all green; backups verified by a real restore.
Roye tested offline add + sync on his phone (works) and the UI on a 2000 px
screen (feedback addressed above).

**Open items, roughly in order:**
1. **Walkthrough for Roye** of everything marked "explanation pending" above
   (he must defend it). This is now the biggest risk, more than any feature.
2. **Build collaborative trips + expense splitting (IN SCOPE since 2026-10-16),**
   see "Collaborative trips" below.
3. Trip keepsake: single downloadable HTML file (Roye: later).
4. Week 8: PDF export + Google Maps link, polish, final review.
5. EKS session: gp3/EBS CSI for Postgres + Garage, transit/ORS key (optional
   Secret there), backups (no nfs-client on EKS -> backup job not rendered),
   check `aws ec2 describe-volumes` after destroy.
6. Jenkins: the frontend job also builds on tripsync-devops commits despite
   `poll: false` (Roye didn't trigger builds by hand); check that job's
   Polling Log / SCM config.
7. Small: `dynamodb_table` -> `use_lockfile` in terraform/aws backend; offsite
   backup (R2) would close the same-building gap.

**Collaborative trips (IN SCOPE, Roye 2026-10-16; not built yet).** Plan: `trip_members(trip_id, user_id, role owner|editor|
viewer)`, invite by link (signed token, no email provider), every owner check
in trips.py / extras.py / photos.py goes through one "is member with role"
helper (they're already centralised: find_trip/find_day/find_stop/find_child/
find_photo + list), isolation tests extended per role, trip list includes
shared trips, other people's changes picked up by polling (or SSE later),
last-write-wins per field (ops are field-level PATCHes; reorder conflicts are
already refused + refreshed). Estimated about a day. Out of scope: live
co-editing (websockets/cursors).
**Expense splitting (IN SCOPE, Roye 2026-10-16; not built yet):** each expense
stores only facts: `paid_by` (a member) and `split_between` (members, default
everyone). Balances ("who owes whom") are computed when shown, never stored, so
edits/deletes can't leave them stale. Equal split; the leftover cent goes to one
person so shares add up exactly; amounts converted to the trip's home currency
(existing ECB rates); "settle up" shows a minimal set of payments (net balances,
then match biggest debtor with biggest creditor).

## Scope (locked, do not silently re-expand)

**Multi-account** (changed from single-user on 2026-10-16, Roye's decision):
open sign-up, trips private to their members (**shared trips + expense
splitting added to scope later the same day**, see Open items), no email
verification or password reset (no mail provider). Every query is scoped to the
logged-in user, with a pytest per endpoint proving user A can't reach user B's
data (404, not 403, so IDs don't leak). Rate limits on login/sign-up. **Place search (changed 2026-10-16, Roye's
decision, "keep it free"):** Photon (OSM) search + Nominatim/Wikidata/Wikipedia
details through the backend; no Google Places, no ratings (no free legitimate
source); stops can still be entered by hand. No full offline
tile prefetch (Workbox opportunistic caching only); export is PDF + Google Maps
link only (no GPX/KML); Jenkins stays outside Kubernetes by design. GitOps with
Argo CD is an **optional ~4h stretch sprint** after the core plan (it can be pulled
forward after Week 4); until then Jenkins deploys directly.

## Pipelines (design)

Each app repo has its own Jenkinsfile running on the agent labeled `k3s-agent`:

1. Checkout its own repo, plus this repo (for the chart)
2. Lint in throwaway containers, in parallel: `helm lint`, flake8 or ESLint
3. Unit tests: pytest against a throwaway Postgres (backend); Vitest (frontend)
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
