# Assumptions

You weren't available to give input, so every value in this repo rests on the assumptions below. **Check each one before you deploy.** The values themselves live in `inventory/cluster-inventory.yaml`.

## Overview

| # | Area | Assumption | If wrong, change |
|---|------|-----------|------------------|
| A1 | Version | Harvester v1.6.x or newer. CRD field names follow v1.5/v1.6 docs | Every CRD — run `kubectl explain` on your cluster |
| A2 | Topology | 5 bare-metal nodes in 1 site: 3 management (hv01–03) + 2 worker (hv04–05), spread over 3 racks | install-config, quotas, Portworx KVDB |
| A3 | Hardware | 2×32c, 1 TiB RAM, 8 NIC ports, boot RAID1 + 1 data NVMe + 4 NVMe + 4 SATA SSD per node | install-config, disk map, NIC names |
| A4 | Network | Redundant ToR pair with MLAG/vPC (LACP), jumbo frames on storage VLANs, VLAN plan below | 01-networking |
| A5 | IP / DNS | Static IPs, mgmt 10.10.10.0/24, VIP .10, internal DNS + NTP exist, domain `corp.example.com` | inventory, install-config |
| A6 | External storage | NetApp ONTAP (AFF) with one SVM serving iSCSI + NFSv4.1; one generic NFS server | 02-storage-drivers |
| A7 | SDS | Longhorn (bundled) is the primary storage. Portworx is included because you asked for it, on separate disks | 04-portworx, disk map |
| A8 | Backup | Kasten runs in the Harvester cluster. S3-compatible object storage with Object Lock exists | 05-kasten |
| A9 | Rancher | Rancher Prime runs on its own 3-node RKE2 cluster, outside Harvester | 06-rancher |
| A10 | Identity | An OIDC IdP exists (for Kasten and Rancher SSO) | Kasten / Rancher values |
| A11 | Workload mix | About 60% general VMs, 25% databases, 15% guest Kubernetes nodes | overcommit, quotas |
| A12 | Air-gap | Clusters have internet access (or a proxy) to pull charts and images | Add private registry + `containerd-registry` setting |
| A13 | Secrets | Nothing secret is committed. Templates are `*.example.yaml` and real copies are git-ignored | — |

## Notes on the assumptions most likely to be wrong

**A1 (version).** Harvester renames CRD fields between minor releases. Two examples: `BlockDevice.spec.fileSystem.provisioned` became `spec.provision`, and the `vm-migration-network` setting is newer than v1.5. Before applying anything, run `kubectl apply --dry-run=server -k <dir>` against a lab cluster on the **same** release.

**A3 (8 NIC ports).** Many servers have 4 ports. With 4 ports, collapse the layout to:
- `mgmt` + `vmnet` on one LACP pair, with VM VLANs tagged on top of the mgmt bond
- `storage` + external storage on the second pair

Physical separation then becomes VLAN separation only. Add QoS on the switch so a node drain (migration plus Longhorn rebuilds) can't starve the control plane.

**A7 (two SDS layers).** See `docs/review-notes.md`. Running Longhorn **and** Portworx **and** NetApp in one cluster is supported, but the operational cost is high.
