#!/usr/bin/env bash
# One-time move of today's hand-made Kubernetes Secrets into Vault.
# Run by the owner (needs kubectl on the homelab and a Vault admin token):
#   export VAULT_ADDR=http://<vault machine>.<tailnet>.ts.net:8200 VAULT_TOKEN=<admin token>
#   ./vault/import-from-k8s.sh
# Values go straight from kubectl into `vault kv put` (key=- reads stdin), so
# they are never printed, never in a file and never in shell history.
# Safe to run again: each run writes a new version (KV v2 keeps the old ones).
set -euo pipefail

copy() { # <namespace> <secret> <key in secret> <vault path> <key in vault>
  local ns=$1 secret=$2 key=$3 path=$4 field=$5
  if ! kubectl --context default -n "$ns" get secret "$secret" >/dev/null 2>&1; then
    echo "skip   $ns/$secret (not in the cluster)"
    return
  fi
  kubectl --context default -n "$ns" get secret "$secret" -o "jsonpath={.data.$key}" \
    | base64 -d \
    | vault kv put -mount=secret "$path" "$field=-" >/dev/null
  echo "copied $ns/$secret -> secret/$path ($field)"
}

copy tripsync   openrouteservice     api-key     tripsync/openrouteservice api-key
copy tripsync   cloudflared-token    token       tripsync/cloudflared      token
copy monitoring alertmanager-discord webhook-url monitoring/discord        url
