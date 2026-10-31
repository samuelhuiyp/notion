#!/usr/bin/env bash
# Offline validation: YAML lint + schema check of Kubernetes manifests.
# Harvester/Longhorn/Trident/Portworx/Kasten CRDs have no public schema in the
# default catalog, so unknown kinds are skipped (-ignore-missing-schemas):
# the real gate for those is `kubectl apply --dry-run=server` against a lab cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
yamllint -s .
if command -v kubeconform >/dev/null; then
  find . -name '*.yaml' -not -path './00-node-deployment/install-config/*' \
    -not -name '*helm-values*' -not -name '*.patch.yaml' -not -name '*.template.yaml' -not -name 'kustomization.yaml' -not -path './inventory/*' -not -path './02-storage-drivers/netapp-ontap-setup/*' \
    -not -path './.git/*' -print0 | xargs -0 kubeconform -strict -ignore-missing-schemas -summary
fi
for k in $(find . -name kustomization.yaml -exec dirname {} \;); do
  kubectl kustomize "$k" >/dev/null && echo "kustomize ok: $k"
done
