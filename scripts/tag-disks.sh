#!/usr/bin/env bash
# Provision local disks to Longhorn and tag them for the perf/capacity tiers.
# Usage: DISK_MAP=disk-map.txt ./scripts/tag-disks.sh   (add DRY_RUN=0 to apply)
# disk-map.txt lines: <node> <disk-serial-number> <tag>
#   hv01 S6XXXXXXXXXXXX nvme
#   hv01 2245XXXXXXXX   capacity
# Serials: kubectl -n longhorn-system get bd -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,DEV:.status.deviceStatus.devPath,SERIAL:.status.deviceStatus.details.serialNumber
# Portworx disks must NOT appear in this map (Portworx needs them raw).
set -euo pipefail
DISK_MAP=${DISK_MAP:?set DISK_MAP}
DRY_RUN=${DRY_RUN:-1}
while read -r node serial tag; do
  [[ -z "${node}" || "${node}" == \#* ]] && continue
  bd=$(kubectl -n longhorn-system get bd -o json | jq -r --arg n "$node" --arg s "$serial" \
    '.items[] | select(.spec.nodeName==$n and .status.deviceStatus.details.serialNumber==$s) | .metadata.name' | head -1)
  if [[ -z "$bd" ]]; then echo "WARN: no blockdevice for $node serial $serial" >&2; continue; fi
  patch=$(jq -nc --arg t "$tag" '{spec:{provision:true,provisioner:{longhorn:{engineVersion:"LonghornV1"}},fileSystem:{forceFormatted:true},tags:[$t]}}')
  echo "bd/$bd ($node $serial) -> tag=$tag"
  [[ "$DRY_RUN" == 0 ]] && kubectl -n longhorn-system patch bd "$bd" --type merge -p "$patch"
done < "$DISK_MAP"
[[ "$DRY_RUN" == 0 ]] || echo "(dry run — set DRY_RUN=0 to apply)"
