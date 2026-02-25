# Talos Setup

Talos Linux is an immutable, minimal OS designed specifically for Kubernetes. No SSH, no shell - everything is managed via API.

## Cluster Topology

```
┌─────────────────────────────────────────────────────────────┐
│                     Control Plane                           │
│                                                             │
│   ┌─────────┐     ┌─────────┐     ┌─────────┐              │
│   │ NODE-1  │     │ NODE-2  │     │ NODE-3  │              │
│   │  .71    │     │  .72    │     │  .73    │              │
│   │  etcd   │◄───►│  etcd   │◄───►│  etcd   │              │
│   │  API    │     │  API    │     │  API    │              │
│   └────┬────┘     └────┬────┘     └────┬────┘              │
│        │               │               │                    │
│        └───────────────┼───────────────┘                    │
│                        │                                    │
│                   ┌────┴────┐                               │
│                   │   VIP   │ ◄── 192.168.1.70              │
│                   │ (float) │     Kubernetes API            │
│                   └─────────┘                               │
└─────────────────────────────────────────────────────────────┘
```

All 3 nodes are control-plane nodes with scheduling enabled (`allowSchedulingOnControlPlanes: true`).

## Talhelper

We use [talhelper](https://github.com/budimanjojo/talhelper) to generate Talos machine configs from a single `talconfig.yaml`.

### Configuration: `talos/talconfig.yaml`

```yaml
clusterName: cluster
talosVersion: v1.12.4
kubernetesVersion: v1.34.0
endpoint: https://192.168.1.70:6443  # VIP

allowSchedulingOnControlPlanes: true

# Global patches applied to all nodes
patches:
  # Disable kube-proxy (Cilium replaces it)
  - |-
    cluster:
      proxy:
        disabled: true

  # No CNI - Cilium installed separately
  - |-
    cluster:
      network:
        cni:
          name: none

  # Kubelet certificate rotation
  - |-
    machine:
      kubelet:
        extraArgs:
          rotate-server-certificates: "true"

# Control plane specific patches
controlPlane:
  patches:
    # Talos VIP for API HA
    - |-
      machine:
        network:
          interfaces:
            - interface: enp1s0
              dhcp: true
              vip:
                ip: 192.168.1.70

    # etcd configuration
    - |-
      cluster:
        etcd:
          extraArgs:
            listen-metrics-urls: http://0.0.0.0:2381
          advertisedSubnets:
            - 192.168.1.0/24

    # Pod Security Standards - restricted by default
    - |-
      cluster:
        apiServer:
          admissionControl:
            - name: PodSecurity
              configuration:
                defaults:
                  enforce: "restricted"
                exemptions:
                  namespaces:
                    - cilium
                    - kadalu

nodes:
  - hostname: NODE-1
    ipAddress: 192.168.1.71
    controlPlane: true
    installDisk: /dev/nvme0n1

  - hostname: NODE-2
    ipAddress: 192.168.1.72
    controlPlane: true
    installDisk: /dev/nvme0n1

  - hostname: NODE-3
    ipAddress: 192.168.1.73
    controlPlane: true
    installDisk: /dev/nvme0n1
```

### Generating Configs

```bash
just generate
# Or manually:
cd talos && talhelper genconfig
```

This creates:
- `clusterconfig/cluster-NODE-1.yaml`
- `clusterconfig/cluster-NODE-2.yaml`
- `clusterconfig/cluster-NODE-3.yaml`
- `clusterconfig/talosconfig`

### Secrets Management

Talos secrets are stored encrypted in `talos/talsecret.sops.yaml`:

```bash
# Generate new secrets (only needed once)
talhelper gensecret > talsecret.sops.yaml
sops -e -i talsecret.sops.yaml

# Decrypt for talhelper
sops -d talsecret.sops.yaml > talsecret.yaml  # gitignored
```

## PXE Boot Process

Nodes are provisioned via PXE boot using [Siderolabs Booter](https://github.com/siderolabs/booter).

### Two-Phase Boot

The `scripts/booter-wipe` script implements a two-phase boot process:

```
┌──────────────────────────────────────────────────────────────┐
│ PHASE 1: Wipe Mode                                           │
│                                                              │
│   Booter starts with: --extra-kernel-args talos.experimental.wipe=system
│                                                              │
│   Node PXE boots → Talos wipes disk → Reboots → PXE boots   │
│                          ↑                         │         │
│                          └─────────────────────────┘         │
│                                                              │
│   Wait until all MACs seen 2x (proves wipe-reboot loop)     │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ PHASE 2: Clean Mode                                          │
│                                                              │
│   Booter restarts WITHOUT wipe arg                           │
│                                                              │
│   Node PXE boots → Enters maintenance mode (port 50000)     │
│                                                              │
│   Ready to receive config via talosctl apply-config          │
└──────────────────────────────────────────────────────────────┘
```

### Running Booter Manually

```bash
# Two-phase boot with specific MACs
./scripts/booter-wipe -i enp0s20f0u2u1u2 -v v1.12.4 \
    10:e7:c6:0d:12:be 10:e7:c6:0d:12:62 10:e7:c6:0d:61:18

# Or via justfile
just booter-wipe
```

Requirements:
- Wired network interface (WiFi doesn't work for DHCP proxy)
- Podman installed
- Nodes configured to PXE boot

## Bootstrap Process

### Full Bootstrap

```bash
just bootstrap
```

This runs:
1. `generate` - Generate Talos configs from talhelper
2. `booter-wipe` - Start PXE booter, wipe nodes, enter maintenance
3. `_apply-all-nodes` - Apply configs to all nodes in parallel
4. `_booter-stop` - Stop the PXE booter
5. `_bootstrap-cluster` - Bootstrap etcd on node1
6. `_get-kubeconfig` - Retrieve kubeconfig
7. `_wait-for-k8s` - Wait for Kubernetes API

### Manual Steps

If you need to run steps individually:

```bash
# Generate configs
just generate

# Start two-phase booter
just booter-wipe

# Apply config to a single node
just apply-node 192.168.1.71 talos/clusterconfig/cluster-NODE-1.yaml

# Stop booter
just booter-stop
```

## Day-2 Operations

### Accessing Nodes

```bash
# Interactive dashboard
just dashboard 1  # Node number or IP

# Check services
just services 192.168.1.71

# View containers
just containers 192.168.1.71
```

### Cluster Status

```bash
just status
```

### Resetting Nodes

```bash
# WARNING: Destructive! Wipes all data
just reset
```

### Upgrading Talos

1. Update `talosVersion` in `talconfig.yaml`
2. Regenerate configs: `just generate`
3. Apply upgrade:
   ```bash
   talosctl upgrade --nodes 192.168.1.71 \
       --image ghcr.io/siderolabs/installer:v1.12.4
   ```

## Key Design Decisions

### No CNI in Talos Config

```yaml
cluster:
  network:
    cni:
      name: none
```

Cilium is installed separately after Talos bootstrap. This allows:
- More control over Cilium version and config
- ArgoCD can manage Cilium after initial install
- Easier upgrades

### Disabled kube-proxy

```yaml
cluster:
  proxy:
    disabled: true
```

Cilium provides kube-proxy replacement with eBPF, offering better performance.

### VIP for API HA

The Kubernetes API is accessed via a floating VIP (192.168.1.70) that moves between nodes. This is configured via Talos's built-in VIP support.

### Pod Security Standards

Restricted PSS is enforced by default with exemptions for system namespaces:

```yaml
defaults:
  enforce: "restricted"
exemptions:
  namespaces:
    - cilium
    - kadalu
```
