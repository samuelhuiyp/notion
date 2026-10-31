# Storage design

## Overview

| StorageClass | Backend | Media | Protection | Volume mode | Live migration | Use for |
|--------------|---------|-------|-----------|-------------|----------------|---------|
| `lh-performance` *(default)* | Longhorn | local NVMe (tag `nvme`) | 3 replicas, best-effort locality | Block RWX | yes | DB, latency-sensitive VMs, root disks |
| `lh-performance-retain` | Longhorn | local NVMe | 3 replicas, Retain | Block RWX | yes | Critical data disks |
| `lh-capacity` | Longhorn | local SATA/QLC (tag `capacity`) | 2 replicas | Block RWX | yes | File servers, bulk, dev |
| `netapp-san-performance` | Trident ontap-san (**NVMe/TCP**, default external block) | AFF | array RAID + snapshots | Block RWX | yes, prove it in a test | Large DBs, array-side snapshot/DR |
| `netapp-san-iscsi` | Trident ontap-san (iSCSI, fallback) | AFF | array | Block RWX | yes | LUNs that must stay on iSCSI |
| `netapp-nas-capacity` | Trident ontap-nas (NFSv4.1) | AFF/FAS | array | Filesystem RWX | release-dependent | Shares, archive |
| `nfs-capacity` | csi-driver-nfs | generic filer | filer | Filesystem RWX | release-dependent | Kasten FileStore, ISO library |
| `px-performance` | Portworx | NVMe pool | repl 3 | Block, sharedv4 | yes (check PX version) | If Portworx replaces Longhorn |
| `px-capacity` | Portworx | SATA pool | repl 2 | Block, sharedv4 | yes | — |
| `harvester-longhorn` *(built-in)* | Longhorn | default data disk | 3 replicas | Block RWX | yes | Left for Harvester internals and images |

## Disk layout per node (assumed)

```
boot  RAID1 M.2 480G   -> Harvester OS
nvme0 3.84T            -> Harvester data disk (images, harvester-longhorn)
nvme1, nvme2           -> Longhorn tag "nvme"      (lh-performance)
nvme3, nvme4           -> Portworx (raw)           (px-performance)
sdb, sdc   7.68T       -> Longhorn tag "capacity"  (lh-capacity)
sdd, sde   7.68T       -> Portworx (raw)           (px-capacity)
```

## Design reasoning

**Why 3 replicas for performance but 2 for capacity.** With 3 replicas, the volume stays writable with full redundancy during a planned node drain while also surviving one unplanned failure. Two replicas save 33% raw capacity but leave a single copy during any maintenance. That's acceptable only because capacity-tier data is also exported off-cluster by Kasten. If a capacity-tier workload has no backup, use 3.

**Why `dataLocality: best-effort` on performance.** Reads come from the local NVMe instead of across the storage network. The cost is that after every live migration Longhorn rebuilds a local replica on the new node. If VMs migrate often (for example, the descheduler is very active), switch to `disabled`.

**Why `migratable: "true"`.** Harvester live migration needs RWX block volumes. Longhorn provides this for "migratable" volumes. Without it, VMs can't be live-migrated, and node drains will shut VMs down.

**Why a deny-by-default multipath config.** See `02-storage-drivers/host-prereqs/cloudinit-multipath.yaml`. Longhorn volumes appear as local iSCSI LUNs. If multipathd grabs them, every Longhorn volume breaks. Allow-listing only `NETAPP LUN.*` removes that failure mode completely.

**Why NVMe/TCP is the default external block protocol.** Your ONTAP supports it, and compared with iSCSI it has a shorter kernel I/O path (no SCSI layer), multiple queues per path, and native multipath with ANA, so no `multipath.conf` to maintain. Typical gains are lower latency and less host CPU per IO. The things to watch:
- Trident's NVMe support is newer than its iSCSI support.
- There's no CHAP equivalent here, so the non-routed VLANs are the access control.
- Every node's host NQN must be unique. `cloudinit-nvme-tcp.yaml` derives it from the DMI UUID and refuses an empty or all-zero UUID.

iSCSI stays as `netapp-san-iscsi` so you have a fallback while NVMe proves itself.

**Why the cluster default StorageClass is still `lh-performance`.** "Default" here means the default *NetApp* protocol, not the cluster default. Making an external array the cluster default would put every PVC without an explicit class on the SAN, including Harvester add-on volumes (monitoring, Kasten catalog), and would make the whole cluster depend on the array and the storage network for basic operations. If you do want it:
```
kubectl annotate sc lh-performance storageclass.kubernetes.io/is-default-class=false --overwrite
kubectl annotate sc netapp-san-performance storageclass.kubernetes.io/is-default-class=true --overwrite
```

**Why images are pinned to a tier.** A VM's root disk created from a Longhorn image inherits the image's StorageClass parameters. The `harvesterhci.io/storageClassName` annotation (see `03-storage-classes/vm-image-example.yaml`) decides which tier the VM's root disk can land on.

## Capacity math (raw → usable, 5 nodes)

- **Longhorn perf:** 5 × 2 × 3.84T = 38.4T raw. ÷3 replicas = 12.8T. −25% reserve ≈ **9.6T usable** (thin 2:1 → up to 19T provisioned)
- **Longhorn capacity:** 5 × 2 × 7.68T = 76.8T raw. ÷2 replicas = 38.4T. −25% ≈ **28.8T usable**
