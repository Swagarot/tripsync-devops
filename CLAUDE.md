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

Week 4 remaining (EKS is rebuilt for each test):
1. Write my own minimal VPC module (spec below) to replace the community VPC module.
2. Terraform the in-cluster pieces that are currently manual: the `tripsync`
   namespace, ingress-nginx as a `helm_release`, and the Jenkins access entry via
   the EKS module's `access_entries`.
3. Make a fresh cluster pipeline-ready: `helm upgrade --install`, and push a
   `:latest` tag next to the SHA tag (a fresh install has no tags to reuse, so the
   frontend would otherwise pull a missing `latest` and `--atomic` would roll back).
4. Clean-slate test: destroy, apply, run both pipelines with no manual steps.
Optional: move EKS images to ECR.

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
  `tripsync`). The access entry is created outside Terraform today and is lost on
  destroy; it must be recreated or moved into Terraform.
- A fresh EKS cluster has no ingress-nginx and no `tripsync` namespace. Today both
  are created by hand, and the first install is manual
  (`helm upgrade --install` with both tags), because `helm upgrade` needs an
  existing release.
- EKS pulls the public Docker Hub images (no ECR yet) through the NAT gateway.
- **Teardown order:** `helm uninstall` the app, `helm uninstall ingress-nginx`
  (this deletes the AWS load balancer Kubernetes created, which Terraform doesn't
  know about), wait until `aws elb describe-load-balancers` and
  `aws elbv2 describe-load-balancers` are empty, then `terraform destroy`. A
  leftover load balancer makes the VPC delete fail with `DependencyViolation`.
  Anything created by controllers inside the cluster (load balancers, EBS volumes
  from PVCs) must be removed from inside the cluster first.
- Cost: the control plane, NAT gateway, node and load balancer all bill hourly.
  Never leave EKS running unattended.

## Planned minimal VPC module (`terraform/aws/modules/vpc`)

Being written by Roye step by step (coached, not generated). Design decision:
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
subnets and `subnet_ids` = the private subnet (nodes). Check the EKS module's
input names when wiring. All nodes then run in one AZ, which is acceptable here.

**Progress (2026-10-08):** coaching mode. Claude explains each resource and its key
arguments, Roye writes the code, Claude reviews and runs `terraform validate` (on a
scratch copy with `init -backend=false`, so no `.terraform/` lands in the module).
`terraform fmt` is run once at the end, not per step.
Order: variables, vpc, igw, public subnets, private subnet, eip, nat gateway, route
tables and routes, associations, outputs, wiring into `terraform/aws/main.tf`.
- Done and validating: `variables.tf`, `aws_vpc.this`, `aws_internet_gateway.igw`,
  `aws_subnet.public_subnet` (count, ELB tag), `aws_subnet.private_subnet`
  (2026-10-10; traffic path discussed: LB in public subnets, VPC local route to
  NodePorts on private nodes, NAT is outbound only).
  `aws_eip.nat_eip` (count on `enable_nat_gateway`, `domain = "vpc"`, depends_on
  IGW), `aws_nat_gateway.nat_gateway` (count, EIP `[0]`, in `public_subnet[0]`).
  Cosmetic: their Name tags use underscores, others use hyphens.
  Route tables, routes (separate `aws_route`, private one counted) and all 3
  associations (written with Copilot's help, 2026-10-10). All 14 resources done.
  `outputs.tf` done (community-module names, private as `[ ... .id]`).
  Wired into `terraform/aws/main.tf` (local source, `control_plane_subnet_ids` =
  public, `subnet_ids` = private), `terraform fmt` done, init + validate pass,
  state was empty. **Week 4 item 1 done, pending a real apply test.**
- Later: backend `dynamodb_table` is deprecated, switch to `use_lockfile`.
- Week 4 item 2, step 1 done (2026-10-10): Jenkins access entry via the EKS
  module's `access_entries` (Edit, namespace-scoped to `tripsync`), ARN read with
  `data "aws_iam_user" "jenkins"`. The IAM user and its key stay outside Terraform
  on purpose (keeps the secret out of state, survives destroy). Plan: 52 to add.
- Next: step 2, `kubernetes` + `helm` providers pointed at the EKS cluster, then
  step 3 `tripsync` namespace, step 4 ingress-nginx `helm_release`.
- To verify on next apply: does ingress-nginx's `type: LoadBalancer` Service get
  a Classic ELB or an NLB on EKS 1.37 (no AWS Load Balancer Controller installed)?

## Terraform and AWS

- Remote state: S3 bucket `tripsync-tfstate-roye`, DynamoDB lock table
  `tripsync-tfstate-lock`, region `eu-central-1`; state keys `k3s/terraform.tfstate`
  and `aws/terraform.tfstate`. Environments are separate root configurations
  (different providers), not workspaces.
- `.gitignore` must keep ignoring `.terraform/`, `*.tfstate*`, `*.tfvars`,
  `.terraform.lock.hcl` (a 685 MB provider binary once blocked a push).
- **Do not `terraform apply` in `terraform/aws` without asking Roye first.** The
  VPC module includes a NAT gateway and EKS bills ~$0.10/hr for its control plane,
  all hourly regardless of load. Plan: apply, test, then destroy in one sitting.
  Before `terraform destroy`, uninstall the ingress-nginx release so the AWS load
  balancer doesn't block VPC deletion.
- When EKS is enabled it needs `enable_cluster_creator_admin_permissions = true`
  (verify in the module docs) or `kubectl` is denied.
- Nothing secret belongs in this repo: AWS keys, kubeconfigs and tokens live in
  local config or the Jenkins credential store.

## Working style

- Roye knows Docker, basic Kubernetes, Terraform and Linux. Jenkins and Helm are
  newer to him: explain pipeline syntax, agents, credentials binding and
  templating when they come up.
- If uncertain, say so ("לא בטוח") instead of asserting. Flag unverified
  hypotheses and check them before presenting them as likely. Past mistakes in
  this project came from confident but unchecked answers.
- On Windows PowerShell, scripts are blocked by default:
  `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` per window.
- **At the end of the project, quiz Roye** on everything fixed or built and why
  (Ingress annotation scoping, Helm release vs resource namespace, CORS, `0.0.0.0`
  binding, nginx `try_files`, Helm value recomputation, state locking, liveness vs
  readiness), so he can explain any of it cold.
