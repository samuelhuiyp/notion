# ONTAP NVMe/TCP setup for Harvester (manual CLI)

This does the same as `playbook-nvme-tcp.yaml`, for teams that configure the array by hand. Values come from `vars.yaml`. **Replace node names, ifgrp, aggregates and IPs with your own.** Run it from the cluster shell as `admin`.

## Overview

1. VLAN ports + broadcast domains for fabrics A/B (VLAN 25/26, MTU 9000)
2. SVM: allow NVMe, assign aggregates, start the NVMe service
3. LIFs: 1 SVM management LIF + 4 NVMe/TCP data LIFs (2 nodes × 2 fabrics)
4. Least-privilege Trident account
5. Optional: adaptive QoS for the performance tier
6. Verify

Trident creates the volumes, namespaces, NVMe subsystems and host-NQN mappings itself. Don't pre-create them.

## 1. Network

```
network port vlan create -node aff-01 -vlan-name a0a-25
network port vlan create -node aff-02 -vlan-name a0a-25
network port vlan create -node aff-01 -vlan-name a0a-26
network port vlan create -node aff-02 -vlan-name a0a-26

network port broadcast-domain create -ipspace Default -broadcast-domain bd-nvme-a -mtu 9000 -ports aff-01:a0a-25,aff-02:a0a-25
network port broadcast-domain create -ipspace Default -broadcast-domain bd-nvme-b -mtu 9000 -ports aff-01:a0a-26,aff-02:a0a-26
```

## 2. SVM

Skip `vserver create` if `svm_harvester` already exists.

```
vserver create -vserver svm_harvester -rootvolume svm_harvester_root -aggregate aggr1_n1 -rootvolume-security-style unix
vserver add-protocols -vserver svm_harvester -protocols nvme
vserver modify -vserver svm_harvester -aggr-list aggr1_n1,aggr1_n2
vserver nvme create -vserver svm_harvester -status-admin up
```

## 3. LIFs

```
network interface create -vserver svm_harvester -lif svm_harvester_mgmt -service-policy default-management \
  -home-node aff-01 -home-port e0M -address 10.10.10.200 -netmask 255.255.255.0

network interface create -vserver svm_harvester -lif nvme_a_aff_01 -service-policy default-data-nvme-tcp \
  -home-node aff-01 -home-port a0a-25 -address 10.10.25.101 -netmask 255.255.255.0
network interface create -vserver svm_harvester -lif nvme_a_aff_02 -service-policy default-data-nvme-tcp \
  -home-node aff-02 -home-port a0a-25 -address 10.10.25.102 -netmask 255.255.255.0
network interface create -vserver svm_harvester -lif nvme_b_aff_01 -service-policy default-data-nvme-tcp \
  -home-node aff-01 -home-port a0a-26 -address 10.10.26.101 -netmask 255.255.255.0
network interface create -vserver svm_harvester -lif nvme_b_aff_02 -service-policy default-data-nvme-tcp \
  -home-node aff-02 -home-port a0a-26 -address 10.10.26.102 -netmask 255.255.255.0
```

## 4. Trident account

```
security login create -vserver svm_harvester -user-or-group-name trident-svc -application http \
  -authentication-method password -role vsadmin
```

`vsadmin` is SVM-scoped. For tighter least privilege, use the custom Trident role from the Trident docs.

## 5. Optional: adaptive QoS for the performance tier

```
qos adaptive-policy-group create -vserver svm_harvester -policy-group aqos-harvester-perf \
  -expected-iops 6144IOPS/TB -peak-iops 12288IOPS/TB -absolute-min-iops 1000IOPS
```

Then uncomment `adaptiveQosPolicy` in `backend-ontap-san-nvme.yaml`. Adaptive QoS stops one noisy VM from saturating the aggregate, at the cost of capping bursts. Size the numbers from real workload data, not these placeholders.

## 6. Verify

On ONTAP:
```
vserver nvme show -vserver svm_harvester                       # Status Admin: up
network interface show -vserver svm_harvester -service-policy default-data-nvme-tcp
network ping -vserver svm_harvester -lif nvme_a_aff_01 -destination 10.10.25.11 -packet-size 8972 -disallow-fragmentation true
```

On a Harvester node, after host prep and a reboot:
```
nvme discover -t tcp -a 10.10.25.101 -s 8009                   # discovery controller lists all 4 LIFs
```

After Trident has published a volume to the node:
```
nvme list-subsys                                               # 4 paths: 2 "optimized", 2 "non-optimized"
cat /sys/class/nvme-subsystem/nvme-subsys*/iopolicy            # round-robin
```

## Firewall / switch

- **NVMe/TCP ports:** TCP 4420 (I/O) and 8009 (discovery), between host VLAN 25/26 IPs and the LIFs.
- **Jumbo frames end to end:** switch MTU 9216.
- **Non-routed VLANs:** no gateway on VLAN 25/26. Without CHAP, the network boundary is the access control.
