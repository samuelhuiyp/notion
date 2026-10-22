#!/usr/bin/env bash
# Topology + capability labels used by StorageClasses, Longhorn zone anti-affinity,
# Portworx placement and VM affinity rules. Idempotent.
set -euo pipefail
declare -A ZONE=([hv01]=rack-a [hv02]=rack-b [hv03]=rack-c [hv04]=rack-a [hv05]=rack-b)
for n in "${!ZONE[@]}"; do
  kubectl label node "$n" --overwrite \
    topology.kubernetes.io/region=dc1 \
    topology.kubernetes.io/zone="${ZONE[$n]}" \
    storage.corp.example.com/external-san=true \
    px/enabled=true
done
# CPU manager (needed for dedicatedCpuPlacement VMs) is enabled per node from the
# Harvester UI (Hosts > ⋮ > Enable CPU Manager, v1.4+). Do it on the nodes meant
# for the performance VM profile, e.g. hv04/hv05, and drain them first.
