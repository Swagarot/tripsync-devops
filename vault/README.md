# Vault: one place for every secret

HashiCorp Vault (self-hosted Community Edition) holds the secrets that used to
be created by hand with `kubectl create secret`. It runs **outside the
clusters**, as a container on its own homelab machine (`vault/compose`), and
is reachable **only over Tailscale**. The External Secrets Operator (ESO) in
each cluster copies secrets from it into ordinary Kubernetes Secrets, with the
same names and keys, so no app changes.

**Optional.** Without this layer everything works with hand-made Secrets
(see `docs/deploy-yourself.md`).

```
   Vault machine (not a k3s node)             AWS
  ┌──────────────────────────────┐        ┌───────────────────┐
  │ tailscale (on the LXC) ─ serve│        │ KMS: auto-unseal  │◄─┐
  │ vault (127.0.0.1:8200) ──────┼────────┼───────────────────┘  │
  │ backup (nightly snapshot)    │                               │
  └──────────────▲───────────────┘                               │
                 │ Tailscale only (tag:vault, port 8200)         │
     ┌───────────┴─────────────┐          ┌──────────────────────┴─┐
     │ k3s: ESO ─► Secrets      │          │ EKS: Tailscale egress  │
     │ openrouteservice,        │          │ proxy ─► ESO ─►        │
     │ cloudflared-token,       │          │ openrouteservice only  │
     │ alertmanager-discord     │          └────────────────────────┘
     │ Prometheus scrapes Vault │
     └──────────────────────────┘
```

Why outside the cluster: a broken or compromised k3s shouldn't take its
secrets store down with it (or hand it over: cluster admin can `exec` into any
pod), and rebuilding k3s from scratch is easier when the secrets are already
waiting. Production setups keep Vault on dedicated machines for the same
reasons. Why Tailscale only: Vault has no public users (two ESOs and the
owner), so it shouldn't be on the internet at all; the Cloudflare tunnel is
for the app's browsers, not for this.

## What lives where

| Vault path (`secret/`)  | Key       | Becomes Secret                        | Read by |
|-------------------------|-----------|---------------------------------------|---------|
| `tripsync/openrouteservice` | `api-key` | `tripsync/openrouteservice`       | k3s, EKS |
| `tripsync/cloudflared`  | `token`   | `tripsync/cloudflared-token`          | k3s |
| `monitoring/discord`    | `url`     | `monitoring/alertmanager-discord` (`webhook-url`) | k3s |

Not in Vault on purpose: the secrets the Helm chart generates itself
(Postgres password, JWT key, Garage keys; `templates/secret.yaml`), and
Vault's own unseal credentials and Tailscale key (they are how Vault starts,
so they can't live in it; they are in `vault/compose/.env` on the Vault
machine only).

## Setup, in order

1. **Tailscale ACL** (admin console, access controls): a tag `tag:vault`
   (owner: you) on the Vault machine's device (Machines -> ... -> Edit ACL
   tags), and a grant letting your devices, the k3s nodes and `tag:k8s` (the
   EKS proxy) reach `tag:vault` on tcp:8200. Only effective once the default
   allow-all grant is replaced by specific grants: removing allow-all alone
   cuts every other Tailscale path (kubectl, SSH, Grafana) - list those too.
   Vault also needs `tag:vault` -> the k3s control node on tcp:6443: it
   checks pod logins against the k3s API over Tailscale (the Vault LXC can't
   reach the LAN address).
2. **AWS + ESO:** `terraform -chdir=terraform/vault init && terraform -chdir=terraform/vault apply`
   (KMS key + the unseal IAM user, and ESO in k3s).
3. **The container**, on the Vault machine (an LXC with Tailscale and Docker
   installed; Proxmox: features nesting + keyctl, TUN for Tailscale):
   copy `vault/compose/`, `cp .env.example .env`, fill in the three KMS values
   (`terraform output -raw ...` inside `terraform/vault`; the secret with
   `| Set-Clipboard` so it's never on screen), `docker compose up -d vault`.
   Then once: `sudo tailscale serve --bg --tcp 8200 tcp://127.0.0.1:8200`
   (Vault listens on 127.0.0.1 only; this is the only way in).
4. **Initialize, once:** `docker compose exec vault vault operator init`.
   With auto-unseal this prints **recovery keys** (only for a few admin
   operations, never for unsealing) and the **initial root token**. Both go in
   your password manager, not a file, not git. From now on Vault unseals by
   itself after every restart.
5. **Configuration** (KV mount, policies, logins, ClusterSecretStore, Discord
   ExternalSecret, Prometheus scrape + alerts), from a machine with kubectl:
   `export VAULT_ADDR=http://<vault machine>.<tailnet>.ts.net:8200 VAULT_TOKEN=<root token>`
   `terraform -chdir=terraform/vault-config apply -var vault_addr=http://<Vault's Tailscale IP>:8200 -var k3s_api_url=https://<control node LAN IP>:6443`
   (pods can't resolve MagicDNS names, hence the IP; the API URL must be an
   address in the k3s API certificate).
6. **Backup token:** `docker compose exec vault vault token create -policy=raft-snapshot -period=768h -orphan -field=token`
   (with `VAULT_TOKEN` set) into `.env` as `VAULT_BACKUP_TOKEN`, set
   `BACKUP_DIR` (ideally the NFS share mounted on that machine),
   `docker compose up -d` (now with the backup service).
7. **Copy today's secrets in** (values never printed): `./vault/import-from-k8s.sh`
8. The chart's ExternalSecrets (`values-k3s.yaml`, `externalSecrets.enabled`)
   now find the store and take over `openrouteservice` and `cloudflared-token`
   in place (`creationPolicy: Orphan`). Check: `kubectl get externalsecret -A`
   -> `SecretSynced`.
9. Hardening: an admin policy + token for daily use, then revoke the root
   token (`vault token revoke <root>`); a new one can be made from the
   recovery keys (`vault operator generate-root`).

## EKS (during an EKS session)

1. Tailscale admin console: an OAuth client (scopes `devices:core`,
   `auth_keys`; tag `tag:k8s-operator`), tag owners for `tag:k8s-operator`
   and `tag:k8s`, and the ACL rule `tag:k8s` -> `tag:vault:8200`.
2. `TF_VAR_vault_enabled=true TF_VAR_vault_tailnet_host=<vault machine>.<tailnet>.ts.net
   TF_VAR_tailscale_oauth_client_id=... TF_VAR_tailscale_oauth_client_secret=...
   terraform -chdir=terraform/aws apply`
3. `terraform -chdir=terraform/vault-config apply ... -var eks_oidc_issuer=$(terraform -chdir=terraform/aws output -raw oidc_issuer)`
4. The next EKS deploy renders the `openrouteservice` ExternalSecret
   (`values-eks.yaml`); routes work instead of straight lines.
5. After the teardown: `terraform -chdir=terraform/vault-config apply` without
   `eks_oidc_issuer` removes the EKS login again.

## Day to day

- Change a secret: `vault kv put -mount=secret tripsync/openrouteservice api-key=-`
  (paste, Enter, Ctrl-D). ESO picks it up within the refresh interval (1h),
  or at once: `kubectl -n tripsync annotate externalsecret openrouteservice force-sync=$(date +%s) --overwrite`.
  Pods read env vars only at start: `kubectl -n tripsync rollout restart deploy/tripsync-backend`.
- Undo a bad change: KV v2 keeps versions, `vault kv rollback -mount=secret -version=<n> <path>`.
- UI: `http://<vault machine>.<tailnet>.ts.net:8200` (tailnet only).
- Upgrade: change the image tag in `docker-compose.yml` (both services),
  `docker compose up -d`, check `vault status`.

## When things go wrong

- **VaultSealed:** Vault restarted and KMS didn't answer. On the Vault machine:
  `docker compose logs vault` (AWS reachable? unseal key in `.env` still valid?).
- **VaultDown:** Prometheus can't reach it: `docker compose ps`, and is the
  `vault` device online in the Tailscale admin console?
- In both cases apps keep working on the Secrets they have; only changes stop
  syncing.
- **Restore:** `vault operator raft snapshot restore -force <file>` from
  `BACKUP_DIR` (one per night, 14 days). It unseals with the same KMS key, so
  the key must still exist (`prevent_destroy`, and AWS waits 30 days before
  deleting a KMS key).
- **Lost the root token:** `vault operator generate-root` with the recovery keys.
