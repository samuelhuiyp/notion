#!/usr/bin/env bash
# Copies the Kasten OIDC client credentials from Rancher to Harvester:
#   Rancher:   oidcclient/kasten .status.clientID + Secret cattle-oidc-client-secrets/<clientID>
#   Harvester: Secret kasten-io/k10-oidc-auth  (keys client-id, client-secret)  -> referenced by auth.oidcAuth.clientSecretName
# Re-run after rotating the client secret in Rancher. Nothing is printed except key names.
# Usage: RANCHER_CONTEXT=<rancher-vcluster ctx> HARVESTER_CONTEXT=<harvester ctx> ./scripts/sync-kasten-oidc-secret.sh
set -euo pipefail
R=${RANCHER_CONTEXT:?set RANCHER_CONTEXT}; H=${HARVESTER_CONTEXT:?set HARVESTER_CONTEXT}
id=$(kubectl --context "$R" get oidcclient kasten -o jsonpath='{.status.clientID}')
[[ -n "$id" ]] || { echo "oidcclient/kasten has no status.clientID yet" >&2; exit 1; }
# The secret's key name is not documented here with certainty: take the first key that starts with client-secret.
key=$(kubectl --context "$R" -n cattle-oidc-client-secrets get secret "$id" -o json \
  | jq -r '.data | keys[] | select(startswith("client-secret"))' | head -1)
[[ -n "$key" ]] || { echo "No client-secret* key in cattle-oidc-client-secrets/$id; keys are:" >&2
  kubectl --context "$R" -n cattle-oidc-client-secrets get secret "$id" -o json | jq -r '.data | keys[]' >&2; exit 1; }
secret=$(kubectl --context "$R" -n cattle-oidc-client-secrets get secret "$id" -o json | jq -r --arg k "$key" '.data[$k]' | base64 -d)
kubectl --context "$H" -n kasten-io create secret generic k10-oidc-auth \
  --from-literal=client-id="$id" --from-literal=client-secret="$secret" --dry-run=client -o yaml \
  | kubectl --context "$H" apply -f -
echo "kasten-io/k10-oidc-auth updated (client-id=$id, from key $key)."
