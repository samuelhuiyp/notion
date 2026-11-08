#!/usr/bin/env bash
# Publishes the ct.local root CA certificate (public part only, never the key) from cert-manager/ct-local-root-ca to:
#   rancher-vcluster/tls-ca                  key cacerts.pem          -> synced into the vcluster as cattle-system/tls-ca (Rancher privateCA)
#   kasten-io/custom-ca-bundle-store (CM)    key custom-ca-bundle.pem -> Kasten trusts https://rancher.ct.local (OIDC)
# and writes ./ct-local-root-ca.crt for importing into browsers / OS trust stores.
# cert-manager cannot write these key names itself. Re-run only if the root CA is re-issued (10-year lifetime, same key on renewal).
# Usage: KUBECONFIG=<harvester kubeconfig> ./scripts/publish-ct-local-ca.sh
set -euo pipefail
ca=$(kubectl -n cert-manager get secret ct-local-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d)
[[ "$ca" == *"BEGIN CERTIFICATE"* ]] || { echo "ct-local-root-ca has no ca.crt yet - is the Certificate Ready?" >&2; exit 1; }
printf '%s\n' "$ca" > ct-local-root-ca.crt

kubectl -n rancher-vcluster create secret generic tls-ca --from-file=cacerts.pem=ct-local-root-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kasten-io create configmap custom-ca-bundle-store --from-file=custom-ca-bundle.pem=ct-local-root-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -

openssl x509 -in ct-local-root-ca.crt -noout -subject -enddate -fingerprint -sha256
echo "Import ./ct-local-root-ca.crt into the trust store of every workstation that opens rancher.ct.local / kasten.ct.local."
