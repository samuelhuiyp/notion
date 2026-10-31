# Review notes: challenges and verification list

## Things I'd push back on

1. **Three storage stacks (Longhorn + Portworx + NetApp) is probably one too many.**
   - Each stack brings its own upgrade cadence, support contract, kernel coupling and monitoring. Portworx and Longhorn also compete for the same local disks, RAM and CPU.
   - Typical patterns:
     - (a) Longhorn for local + NetApp for external
     - (b) Portworx *instead of* Longhorn for all local data (Harvester still needs Longhorn for its own images and system volumes)
   - Questions to answer: Why is Portworx on the list? Licensing you already own? Async DR (PX-DR) between sites? An existing OpenShift/Portworx estate? The answer decides between (a) and (b).

2. **Kasten vs Harvester-native backup.** The repo sets up both: Kasten for policy-driven, immutable, off-site backups, and the native `backup-target` as a last resort. If you have no S3 with Object Lock, Kasten's main advantage (ransomware resistance) is weaker. Decide whether one tool is enough.

3. **Memory overcommit.** I set `memory: 120`. Harvester has no swap, so memory pressure kills VMs rather than slowing them. For a database-heavy cluster I'd set `100` and overcommit CPU only.

4. **Where Rancher runs.** Running Rancher as VMs on the Harvester cluster it manages creates a circular dependency. The repo assumes a separate cluster. If budget forces co-location, at least keep Rancher's etcd backups off-cluster.

5. **5 nodes with 2 workers.** With 3 management nodes, losing one leaves no etcd tolerance during maintenance of a second. Consider a witness node in a third failure domain if racks share power/cooling, or make all nodes management-capable on day 1 (Harvester promotes automatically).

6. **NFS for VM disks.** Supported only in newer Harvester releases, and only in filesystem mode. For VM disks on external storage, prefer iSCSI (ontap-san) block volumes.

## Unverified items (check against official docs for your exact version)

None of these citations were fetched live while writing; they're based on prior knowledge of the projects. Search the authoritative page yourself before relying on them.

| Item | File | What to verify | Where |
|------|------|----------------|-------|
| Trident `sanType: nvme` minimum version + RWX block support (live migration) | 02-storage-drivers/netapp-trident/backend-ontap-san-nvme.yaml | Release notes for your Trident version | https://docs.netapp.com/us-en/trident/ |
| `nvme-cli`, `nvme-tcp` module, native multipath default in the Harvester OS | 02-storage-drivers/host-prereqs/cloudinit-nvme-tcp.yaml | `which nvme`, `cat /sys/module/nvme_core/parameters/multipath` | NetApp ONTAP SAN host config for SUSE: https://docs.netapp.com/us-en/ontap-sanhost/ |
| Whether `/etc/nvme` persists on the immutable OS (the boot-stage rewrite assumes it may not) | same | Reboot a node, then compare `/etc/nvme/hostnqn` | Harvester / Elemental persistent paths docs |
| `netapp.ontap` module options (`services`, `application_dicts`, `service_policy`) | 02-storage-drivers/netapp-ontap-setup/playbook-nvme-tcp.yaml | Collection version in use | https://docs.ansible.com/ansible/latest/collections/netapp/ontap/ |
| `vm-migration-network` setting name and JSON shape | 01-networking/vm-migration-network.yaml | Exists in your release | https://docs.harvesterhci.io/latest/advanced/settings |
| BlockDevice `spec.provision` / `spec.provisioner` | 00-node-deployment/post-install | Field names changed around v1.5 | `kubectl explain bd.spec` |
| CloudInit CRD + wicked ifcfg format | 01-networking/host-storage-interfaces | OS base may move to NetworkManager | https://docs.harvesterhci.io/latest/advanced/cloudinitcrd |
| Install config keys (`role`, `wipe_all_disks`, `harvester.longhorn.default_settings`) | install-config | Keys per release | https://docs.harvesterhci.io/latest/install/harvester-configuration |
| `descheduler` addon availability | 07-optimisation/addons | Name/namespace | `kubectl get addons -A` |
| `cpumanager=true` node label | vm-performance-example | Label Harvester applies | Harvester CPU pinning docs |
| Kasten `k10.kasten.io/freezeVM` annotation, Harvester support | 05-kasten, vm profiles | Supported platform list | https://docs.kasten.io/latest/ |
| Portworx on Harvester (kernel / px-fuse) | 04-portworx | Support matrix | https://docs.portworx.com/ |
| Portworx RWX block for KubeVirt minimum version | 03-storage-classes/portworx.yaml | `sharedv4` behaviour | Portworx KubeVirt docs |
| Longhorn setting value formats | 03-storage-classes/longhorn-settings.yaml | Some became per-data-engine JSON | https://longhorn.io/docs/latest/references/settings/ |
| Rancher import label `provider.cattle.io: harvester` | 06-rancher/harvester-import | Import flow | https://docs.harvesterhci.io/latest/rancher/virtualization-management |
| HarvesterConfig fields | 06-rancher/guest-clusters | Node-driver schema | `kubectl explain harvesterconfig` on Rancher |
| KubeVirt CR reverted by Harvester chart on upgrade | 07-optimisation/kubevirt-migration-tuning | Persistence | Harvester KubeVirt tuning docs |

## Validation before production

- [ ] `scripts/validate.sh` (lint + schema)
- [ ] `kubectl apply --dry-run=server -k <dir>` for every stage, on a lab cluster of the same version
- [ ] Jumbo-frame test on every storage VLAN: `ping -M do -s 8972 <peer>`
- [ ] `cat /etc/nvme/hostnqn` is **different on every node**
- [ ] `nvme list-subsys` shows each NetApp namespace with 4 paths (2 optimized, 2 non-optimized) and `iopolicy` round-robin
- [ ] Live-migrate a VM on `netapp-san-performance` (NVMe) **and** fail one fabric (shut a switch port) during I/O: no guest I/O errors
- [ ] (iSCSI fallback) `multipath -ll` shows NetApp LUNs with 4 paths; `lsblk` shows Longhorn devices **not** under dm-*
- [ ] Live-migrate one VM per StorageClass; drain a node with 20+ VMs and time it
- [ ] Kasten: back up and **restore** a VM to a different namespace (an untested backup isn't a backup)
- [ ] Pull a node's power cord: VM restarts elsewhere within `vm-force-reset-policy` period + boot time
