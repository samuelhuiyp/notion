# Network design

## Overview

- **4 traffic classes, physically separated:** management, VM data, Longhorn replication, external storage
- **Harvester-managed** (cluster networks): `mgmt`, `vmnet`, `storage`
- **Host-managed** (CloudInit ifcfg): `bond-ext`, because CSI node plugins need host IPs on storage VLANs
- **Live migration** has its own VLAN 30, so a node drain doesn't hit the mgmt network

## Port map (per node)

| Bond | Ports (split across NIC cards) | Mode | MTU | Carries |
|------|-------------------------------|------|-----|---------|
| `mgmt-bo` / `mgmt-br` | eno1, eno2 (10G) | active-backup | 1500 | VLAN 10 native: host, API, VIP, UI, Rancher agent |
| `vmnet-bo` / `vmnet-br` | ens1f0, ens2f0 (25G) | 802.3ad | 9000 | VLAN 100/110/120 (VMs), VLAN 30 (live migration) |
| `storage-bo` / `storage-br` | ens1f1, ens3f0 (25G) | 802.3ad | 9000 | VLAN 20 (Longhorn storage network) |
| `bond-ext` | ens2f1, ens3f1 (25G) | 802.3ad | 9000 | VLAN 21/22 iSCSI A/B, 23 NFS, 24 Portworx |

## VLANs

| VLAN | Purpose | Subnet | Gateway | Notes |
|------|---------|--------|---------|-------|
| 10 | Management | 10.10.10.0/24 | .1 | VIP .10, nodes .11–.15 |
| 20 | Longhorn replication | 10.10.20.0/24 | none | Pod IPs via `storage-network` setting |
| 21 | iSCSI fabric A | 10.10.21.0/24 | none | Non-routed |
| 22 | iSCSI fabric B | 10.10.22.0/24 | none | Non-routed |
| 23 | NFS | 10.10.23.0/24 | none | NetApp LIF .100, generic NFS .50 |
| 24 | Portworx data | 10.10.24.0/24 | none | Only if Portworx is deployed |
| 30 | Live migration | 10.10.30.0/24 | none | `vm-migration-network` setting |
| 100 | VM production | 10.100.0.0/22 | .1 | |
| 110 | VM DMZ | 10.110.0.0/24 | .1 | Firewall at the gateway, not on Harvester |
| 120 | VM dev/test | 10.120.0.0/23 | .1 | |

## Design reasoning

**Why mgmt uses active-backup rather than LACP.** The control plane should not depend on the MLAG peer-link being healthy. Active-backup works with any switch config, and 10G is plenty for etcd and the API.

**Why live migration sits on `vmnet` rather than `storage`.** Draining a node does two things at once: it live-migrates every VM off the node, and it makes Longhorn rebuild that node's replicas elsewhere. If both share a bond, they compete exactly when you need both to be fast. VM data traffic is usually far below 25G, so `vmnet` has the headroom.

**Why `bond-ext` is not a Harvester cluster network.** Cluster networks give L2 to VMs and pods. Trident, NFS CSI and Portworx run in the host network namespace and need host IPs on the storage VLANs. Harvester has no first-class API for host IPs on extra VLANs, so the CloudInit CRD writes ifcfg files instead.

**Why iSCSI runs over LACP with two subnets.** The textbook iSCSI design is two unbonded NICs, one per fabric. Here the bond gives link redundancy, and the two VLAN subnets still give dm-multipath two independent sessions per LUN. The trade-off is that both paths share the same two physical links. If your SAN team insists on independent fabrics, split `bond-ext` into `ens2f1.21` and `ens3f1.22` without bonding, and move NFS and Portworx elsewhere.

**Why VM NADs have empty IPAM.** Harvester bridges L2 only. Addressing comes from DHCP or IPAM on the upstream network, or from static config in the guest.

## Switch requirements checklist

- [ ] MLAG/vPC port-channels for `vmnet`, `storage`, `bond-ext` (LACP fast)
- [ ] MTU 9216 on switch ports for 9000 MTU hosts; verify end to end with `ping -M do -s 8972`
- [ ] VLAN 10 native on mgmt ports; VLANs 20 / 21–24 / 30 / 100–120 tagged on the relevant port-channels only
- [ ] Portfast/edge on all host ports; BPDU guard
- [ ] No gateway on the storage and migration VLANs (keep them non-routed)
