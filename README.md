# Harvester (SUSE Virtualization) — configuration baseline

Git source of truth for a production Harvester HCI cluster: node install, networking, storage drivers (NFS / iSCSI / NetApp), storage tiers, Portworx, Kasten, Rancher integration, tuning and overcommit.

> **Read `docs/assumptions.md` first.** Every IP, NIC name, disk and version here is an assumption. Then read `docs/review-notes.md` for the design choices I'd challenge and the items still to verify against vendor docs.

## Repository layout

```
inventory/cluster-inventory.yaml   single source of truth for IPs, VLANs, disks (reference data)
docs/                              assumptions, network design, storage design, review notes
00-node-deployment/
  install-config/                  per-node Harvester install config (ISO/PXE), hv01 create, hv02-05 join
  post-install/                    namespaces, BlockDevice (disk tag) template
01-networking/                     ClusterNetworks, VlanConfigs, VM VLAN NADs,
                                   Longhorn storage network, live-migration network,
                                   host-storage-interfaces/ (bond-ext + VLANs via CloudInit)
02-storage-drivers/                NVMe/TCP host prep (default) + multipath (iSCSI fallback), NFS CSI,
                                   generic iSCSI, NetApp Trident backends,
                                   netapp-ontap-setup/ (array-side Ansible playbook + CLI runbook)
03-storage-classes/                performance/capacity tiers (Longhorn, NetApp, NFS, Portworx),
                                   Longhorn settings, VolumeSnapshotClasses, csi-driver-config
04-portworx/                       Portworx StorageCluster
05-kasten/                         Kasten Helm values, location profiles, tiered policies
06-rancher/                        Rancher server values, Harvester import, RKE2 guest clusters
07-optimisation/                   platform settings, sysctl, KSM, addons, migration tuning, VM profiles
08-overcommit/                     overcommit ratios, namespace quotas
scripts/                           validate, label nodes, tag disks
```

Directories are numbered in apply order. Each Kubernetes stage has a `kustomization.yaml`. Helm values, install configs, examples and secret templates are deliberately left out of the kustomizations.

## Deployment order

| Step | Action | Command / file |
|------|--------|----------------|
| 0 | Switch config (see network-design checklist), BIOS: VT-x/VT-d, SR-IOV, performance power profile | — |
| 1 | Install hv01 (create), then hv02–hv05 (join), one at a time | `00-node-deployment/install-config/*.yaml` (render secrets with `envsubst`) |
| 2 | Namespaces, node labels, disk tags | `kubectl apply -k 00-node-deployment/post-install`, `scripts/label-nodes.sh`, `scripts/tag-disks.sh` |
| 3 | Networking (**before any VM exists**: storage-network needs all VMs stopped) | `kubectl apply -k 01-networking`, then reboot nodes one by one (maintenance mode) for host interfaces |
| 3b | ONTAP array: NVMe/TCP VLANs, LIFs, SVM services, Trident account | `02-storage-drivers/netapp-ontap-setup/` (`ansible-playbook ... --check` first) |
| 4 | Storage drivers | `helm install` NFS CSI + Trident with values files, create secrets from `*.example.yaml`, `kubectl apply -k 02-storage-drivers`, rolling reboot for NVMe/TCP + multipath host prep |
| 5 | Portworx (optional, see review notes) | install operator, `kubectl apply -k 04-portworx` |
| 6 | Storage classes | `kubectl apply -k 03-storage-classes` (drop `portworx.yaml` if step 5 skipped), un-default `harvester-longhorn` |
| 7 | Optimisation | `kubectl apply -k 07-optimisation`, `kubectl patch` addons and KubeVirt per file headers |
| 8 | Overcommit + quotas | `kubectl apply -k 08-overcommit` |
| 9 | Kasten | `helm install` with values, secrets, `kubectl apply -k 05-kasten` |
| 10 | Rancher | Import Harvester (`06-rancher/harvester-import`), then guest clusters |
| 11 | Validate | `docs/review-notes.md` → *Validation before production* |

## Conventions

- **Secrets never committed.** `*.example.yaml` are templates; real copies are `*.secret.yaml` (git-ignored) or SOPS-encrypted `*.enc.yaml`.
- **Pin every version** (Helm charts, images, Kubernetes) before use; placeholders say `<pin>`.
- **Validate** with `scripts/validate.sh`, then `kubectl apply --dry-run=server` on a lab cluster.
- **GitOps (optional).** Once Harvester is imported into Rancher, Fleet can apply stages 01–08 from this repo. Keep stage 00 and the Helm installs manual or in a pipeline.
