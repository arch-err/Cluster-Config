# Cluster Architecture

## Overview

A 3-node Talos Linux Kubernetes cluster with GitOps-driven configuration, distributed storage, and full HA capabilities.

| Component | Value |
|-----------|-------|
| Cluster Name | `cluster` |
| Talos Version | v1.12.4 |
| Kubernetes Version | v1.34.0 |
| GitOps | ArgoCD |
| CNI | Cilium (kube-proxy replacement) |

## Nodes

All 3 nodes are **control plane** nodes with workload scheduling enabled.

| Node | Hostname | IP Address | Install Disk | External Storage |
|------|----------|------------|--------------|------------------|
| 1 | NODE-1 | 192.168.1.71 | /dev/nvme0n1 | /dev/sda (4TB) |
| 2 | NODE-2 | 192.168.1.72 | /dev/nvme0n1 | /dev/sda (4TB) |
| 3 | NODE-3 | 192.168.1.73 | /dev/nvme0n1 | — (tiebreaker) |

**VIP (Virtual IP):** `192.168.1.70:6443` on interface `enp1s0`

## Networking

### Subnets
- **Pod CIDR:** 10.244.0.0/16
- **Service CIDR:** 10.96.0.0/12
- **Management Network:** 192.168.1.0/24

### Cilium CNI
- **Mode:** kube-proxy replacement
- **IPAM:** Kubernetes native
- **L2 Announcements:** Enabled
- **Hubble:** Disabled

### LoadBalancer
- **IP Pool:** 192.168.1.200-254 (55 IPs)
- **Announcement:** L2 on control plane nodes via `enp*` or `eth*` interfaces

## Storage

Three-tier storage strategy:

### 1. Local Path Provisioner (Fast/Ephemeral)
- **StorageClass:** `local-path`
- **Path:** `/var/local-path-provisioner`
- **Use Case:** Fast local NVMe storage, non-replicated

### 2. Kadalu GlusterFS (Distributed/Replicated)
- **StorageClass:** `kadalu.replica2`
- **Type:** Replica2 with Tiebreaker
- **Configuration:**
  - NODE-1: /dev/sda (4TB)
  - NODE-2: /dev/sda (4TB)
  - NODE-3: Tiebreaker at `/var/lib/kadalu/tiebreaker`
- **Use Case:** Redundant persistent storage with automatic failover

### 3. Longhorn (Planned)
- **Status:** Configured but not deployed
- **Blocked by:** External drive mounting in Talos config

## Directory Structure

```
Cluster-Config/
├── talos/                          # Talos infrastructure
│   ├── talconfig.yaml              # Source config (talhelper)
│   ├── talsecret.sops.yaml         # Encrypted secrets (Age)
│   ├── cilium-lb.yaml              # L2 pool definition
│   ├── clusterconfig/              # Generated configs
│   │   ├── cluster-NODE-{1,2,3}.yaml
│   │   ├── talosconfig
│   │   └── kubeconfig
│   └── netboot/                    # PXE boot artifacts
│
├── kubernetes/
│   ├── apps/                       # ArgoCD applications
│   │   ├── root.yaml               # Root app-of-apps
│   │   └── platform/               # Platform apps
│   │       ├── cilium.yaml
│   │       ├── local-path.yaml
│   │       └── longhorn.yaml
│   │
│   └── infra/                      # Helm values & manifests
│       ├── cilium/
│       ├── local-path/
│       ├── longhorn/
│       ├── kadalu/
│       └── argocd/
│
├── scripts/
│   └── booter-wipe                 # PXE boot automation
│
└── justfile                        # Task automation
```

## Bootstrap Process

### PXE Boot (Two-Phase)
1. **Phase 1:** Nodes boot with `talos.experimental.wipe=system`, wipe drives, reboot
2. **Phase 2:** Booter restarts without wipe flag, nodes enter maintenance mode

### Just Recipes

**Full Bootstrap:**
```bash
just bootstrap    # wipe → PXE → apply → bootstrap etcd → wait
```

**Individual Steps:**
```bash
just generate           # Generate Talos configs
just booter-wipe        # Start PXE booter
just status             # Show cluster status
just dashboard node1    # Interactive dashboard
```

**Kubernetes Install:**
```bash
just install            # Cilium + local-path + kadalu + ArgoCD
just install-cilium
just install-kadalu
just install-argocd
just argocd-bootstrap   # Apply root app
```

## Security

### Secrets Management
- **Tool:** SOPS with Age encryption
- **Key:** `~/.config/sops/age/cluster-config.txt`
- **Encrypted:** `talos/talsecret.sops.yaml`

### Pod Security Standards
- **Default:** Restricted
- **Exemptions:** `cilium`, `longhorn-system` namespaces

## Talos Configuration

### Key Settings
- **kube-proxy:** Disabled (Cilium replacement)
- **CNI:** None (manual Cilium install)
- **Scheduling on Control Planes:** Enabled
- **KubePrism:** Enabled (port 7445)
- **Host DNS Forwarding:** Enabled

### Metrics Exposure
- etcd: `0.0.0.0:2381`
- Controller Manager: `0.0.0.0`
- Scheduler: `0.0.0.0`

## TODOs

- [ ] Mount external drives in Talos config for Kadalu/Longhorn
- [ ] Configure ArgoCD repository credentials
- [ ] Add application workloads beyond platform infrastructure
