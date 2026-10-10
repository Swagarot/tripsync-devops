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
| `tripsync-devops` (this repo) | `k8s-helm/tripsync/` chart, `terraform/k3s`, `terraform/aws`, `docker-compose.yml` + `compose/gateway.conf`, this file. Monitoring configs are to be added |

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
laptop); test it in Week 6 when a `postgres` service is added for local dev.

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

Then: Week 5 observability (Prometheus, Grafana, Loki,
Alertmanager); Week 6 backend features (Postgres, JWT, CRUD, pytest stage);
Week 7 frontend + offline (Cloudflare Tunnel for HTTPS, Leaflet, service worker,
Jest stage); Week 8 export, sync, polish, final review.

## Scope (locked, do not silently re-expand)

Single-user only; no Google Places API (stops entered manually); no full offline
tile prefetch (Workbox opportunistic caching only); export is PDF + Google Maps
link only (no GPX/KML); Jenkins stays outside Kubernetes by design. GitOps with
Argo CD is an **optional ~4h stretch sprint** after the core plan (it can be pulled
forward after Week 4); until then Jenkins deploys directly.

## Pipelines (design)

Each app repo has its own Jenkinsfile running on the agent labeled `k3s-agent`:

1. Checkout its own repo, plus this repo (for the chart)
2. Lint in throwaway containers, in parallel: `helm lint`, flake8 or ESLint
3. Unit tests (pytest / Jest) — added in Weeks 6 and 7
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
  outage would cause restart loops); readiness `/health/ready` will check the DB
  once Postgres exists. Frontend probes hit `/` on nginx.
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
  Services, Ingresses only), so uninstalling it first is optional. **This changes
  in Week 6:** a Postgres PVC creates an EBS volume (needs the EBS CSI add-on);
  delete it from inside the cluster before destroy or it keeps billing.
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
