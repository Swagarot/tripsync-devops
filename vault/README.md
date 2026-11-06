# Vault: one place for every secret

HashiCorp Vault (self-hosted Community Edition) runs on the homelab and holds
the secrets that used to be created by hand with `kubectl create secret`. The
External Secrets Operator (ESO) copies them into ordinary Kubernetes Secrets,
with the same names and keys, so no app changes. Both clusters read the same
Vault: k3s directly, EKS over Tailscale.

**Optional.** Without this layer everything works with hand-made Secrets
(see `docs/deploy-yourself.md`).

```
                 homelab k3s                                   AWS
  ┌───────────────────────────────────────────┐        ┌────────────────────┐
  │ vault-0 (Raft on Longhorn) ◄──────────────┼── KMS ─┤ auto-unseal key    │
  │   ▲ Kubernetes auth                       │        └────────────────────┘
  │ ESO ──► Secrets: openrouteservice,         │        ┌────────────────────┐
  │         cloudflared-token,                │        │ EKS                │
  │         alertmanager-discord              │◄───────┤ ESO ─► openroute-  │
  │ NodePort 30820 (LAN + Tailscale)          │ Tail-  │        service     │
  └───────────────────────────────────────────┘ scale  │ (JWT auth, ORS     │
                                                       │  key only)         │
                                                       └────────────────────┘
```

## What lives where

| Vault path (`secret/`)  | Key       | Becomes Secret                        | Read by |
|-------------------------|-----------|---------------------------------------|---------|
| `tripsync/openrouteservice` | `api-key` | `tripsync/openrouteservice`       | k3s, EKS |
| `tripsync/cloudflared`  | `token`   | `tripsync/cloudflared-token`          | k3s |
| `monitoring/discord`    | `url`     | `monitoring/alertmanager-discord` (`webhook-url`) | k3s |

Not in Vault on purpose: the secrets the Helm chart generates itself
(Postgres password, JWT key, Garage keys; `templates/secret.yaml`), and the
Vault unseal credentials (they unlock Vault, so they can't live in it).

## Setup, in order (homelab)

1. **Infrastructure** (KMS key, Vault, ESO):
   `terraform -chdir=terraform/vault init && terraform -chdir=terraform/vault apply`
   The pod `vault-0` starts but stays not-ready: it is not initialized yet.
2. **Initialize, once:**
   `kubectl -n vault exec -it vault-0 -- vault operator init`
   With auto-unseal this prints **recovery keys** (needed only for a few
   admin operations, never for unsealing) and the **initial root token**. Put
   both in your password manager, not in a file, not in git. Vault unseals by
   itself from now on, also after every restart.
3. **Configuration** (KV mount, policies, logins, ClusterSecretStore, Discord
   ExternalSecret, nightly backup):
   `export VAULT_ADDR=http://<homelab node>:30820 VAULT_TOKEN=<root token>`
   `terraform -chdir=terraform/vault-config init && terraform -chdir=terraform/vault-config apply`
4. **Copy today's secrets in** (values never printed):
   `./vault/import-from-k8s.sh`
5. The chart's ExternalSecrets (`values-k3s.yaml`, `externalSecrets.enabled`)
   now find the store and take over `openrouteservice` and
   `cloudflared-token` in place (`creationPolicy: Orphan`). Check:
   `kubectl get externalsecret -A` -> `SecretSynced`.
6. Optional hardening: create an admin token/policy for daily use and revoke
   the root token (`vault token revoke <root>`); a new root token can be made
   later from the recovery keys (`vault operator generate-root`).

## EKS (during an EKS session)

1. Tailscale admin console: an OAuth client with scope `devices:core` +
   `auth_keys`, tag `tag:k8s-operator`; tag owners and an ACL that lets
   `tag:k8s` reach the homelab nodes on port 30820.
2. `TF_VAR_vault_enabled=true TF_VAR_vault_tailnet_host=<node>.<tailnet>.ts.net
   TF_VAR_tailscale_oauth_client_id=... TF_VAR_tailscale_oauth_client_secret=...
   terraform -chdir=terraform/aws apply`
3. `terraform -chdir=terraform/vault-config apply -var eks_oidc_issuer=$(terraform -chdir=terraform/aws output -raw oidc_issuer)`
4. The next EKS deploy renders the `openrouteservice` ExternalSecret
   (`values-eks.yaml`); routes work instead of straight lines.
5. After the teardown: `terraform -chdir=terraform/vault-config apply`
   (no variable) removes the EKS login again.

## Day to day

- Change a secret: `vault kv put -mount=secret tripsync/openrouteservice api-key=-`
  (paste, Enter, Ctrl-D). ESO picks it up within the refresh interval (1h),
  or at once: `kubectl -n tripsync annotate externalsecret openrouteservice force-sync=$(date +%s) --overwrite`.
  Pods read env vars only at start: `kubectl -n tripsync rollout restart deploy/tripsync-backend`.
- Undo a bad change: KV v2 keeps versions, `vault kv rollback -mount=secret -version=<n> <path>`.
- UI: `http://<homelab node>:30820` (LAN/Tailscale only).

## When things go wrong

- **VaultSealed alert:** Vault restarted and KMS didn't answer. Check
  `kubectl -n vault logs vault-0` (AWS reachable? `vault-kms` key still
  valid?). Apps keep working on the Secrets they have; only changes stop syncing.
- **Restore:** snapshots are on the NFS share (`vault-backup` PVC), one per
  night, 14 days. `vault operator raft snapshot restore <file>`; it unseals
  with the same KMS key, so the key must still exist (it is
  `prevent_destroy`, and AWS waits 30 days before deleting a KMS key).
- **Lost the root token:** `vault operator generate-root` with the recovery keys.
