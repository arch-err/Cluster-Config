# Cluster-Config Documentation

Home Kubernetes cluster running on Talos Linux with GitOps via ArgoCD.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Cluster-Config                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌─────────────┐     ┌─────────────────────────────────────┐  │
│   │   talos/    │     │           kubernetes/               │  │
│   │             │     │                                     │  │
│   │  talconfig  │     │  bootstrap/  ──► Cilium + ArgoCD    │  │
│   │  talsecret  │     │  platform/   ──► Meta-chart         │  │
│   │  netboot/   │     │  values/     ──► Helm values        │  │
│   │             │     │  secrets/    ──► SOPS encrypted     │  │
│   │             │     │  infra.yaml  ──► Infrastructure     │  │
│   │             │     │  apps.yaml   ──► Applications       │  │
│   └─────────────┘     └─────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Repository Structure

```
Cluster-Config/
├── kubernetes/                  # Kubernetes layer
│   ├── bootstrap/              # Manual bootstrap values (pre-GitOps)
│   │   ├── cilium.yaml         # Cilium Helm values
│   │   └── argocd.yaml         # ArgoCD values + root Applications
│   ├── platform/               # Reusable meta-chart
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── applications.yaml   # Generates ArgoCD Applications
│   │       ├── extras.yaml         # Gateways, certs, external services
│   │       └── httproutes.yaml     # Auto-generates HTTPRoutes
│   ├── values/
│   │   ├── infra/              # Values for infrastructure components
│   │   │   ├── cilium.yaml
│   │   │   ├── cert-manager.yaml
│   │   │   └── argocd.yaml
│   │   └── apps/               # Values for user applications
│   │       └── keycloak.yaml
│   ├── secrets/                # SOPS-encrypted secrets
│   │   └── home-root-ca.yaml
│   ├── infra.yaml              # Infrastructure instance config
│   ├── apps.yaml               # Applications instance config
│   └── .sops.yaml              # SOPS config for kubernetes secrets
│
├── talos/                      # Talos layer
│   ├── talconfig.yaml          # Talhelper configuration
│   ├── talsecret.sops.yaml     # Encrypted Talos secrets
│   ├── clusterconfig/          # Generated (gitignored)
│   │   ├── cluster-NODE-1.yaml
│   │   ├── cluster-NODE-2.yaml
│   │   ├── cluster-NODE-3.yaml
│   │   ├── talosconfig
│   │   └── kubeconfig
│   └── .sops.yaml              # SOPS config for Talos secrets
│
├── scripts/                    # Helper scripts
│   ├── booter-wipe             # Two-phase PXE boot wrapper
│   └── common.sh
│
├── docs/                       # Documentation
└── justfile                    # Task runner (like Makefile)
```

## Two-Layer Architecture

### Layer 1: Talos (OS + etcd)

- **What**: Immutable Linux OS designed for Kubernetes
- **Managed by**: `talosctl` + talhelper
- **Bootstrap**: `just bootstrap`
- **Details**: [talos.md](talos.md)

### Layer 2: Kubernetes (CNI + GitOps)

- **What**: Cilium (networking) + ArgoCD (GitOps)
- **Managed by**: Helm + ArgoCD
- **Bootstrap**: `just install`
- **Details**: [kubernetes.md](kubernetes.md)

## Quick Start

### Full Cluster Bootstrap

```bash
# 1. Generate Talos configs
just generate

# 2. PXE boot and configure nodes (power on nodes when prompted)
just bootstrap

# 3. Install Cilium + ArgoCD
just install

# 4. Access ArgoCD
just argocd-password
# Then visit: https://argocd.home
```

### Day-2 Operations

```bash
# Check cluster status
just status

# View Talos dashboard
just dashboard 1  # Node 1, 2, or 3

# Get ArgoCD password
just argocd-password

# Port-forward ArgoCD UI
just argocd-ui
```

## Network Layout

| Resource | IP/Range |
|----------|----------|
| Talos VIP (API) | 192.168.1.70 |
| Node 1 | 192.168.1.71 |
| Node 2 | 192.168.1.72 |
| Node 3 | 192.168.1.73 |
| LoadBalancer Pool | 192.168.1.200-220 |
| Internal Gateway | 192.168.1.200 |
| Docker Host | 192.168.1.60 |

The internal gateway handles both TLS termination (`*.home`) and TLS passthrough for external services via SNI-based routing.

## Documentation Index

- [Talos Setup](talos.md) - PXE boot, talhelper, node configuration
- [Kubernetes Setup](kubernetes.md) - Cilium, ArgoCD, Gateway API
- [Platform Chart](platform-chart.md) - Meta-chart architecture
- [Adding Applications](adding-apps.md) - How to deploy new apps
- [Secrets Management](secrets.md) - SOPS encryption

## Key Concepts

### Convention over Configuration

The platform chart uses naming conventions to reduce boilerplate:

```yaml
# In infra.yaml
components:
  - name: grafana
    # Automatically loads: values/infra/grafana.yaml
```

### GitOps Flow

```
Git Push → ArgoCD detects → Syncs to cluster
```

All cluster state is defined in this repo. ArgoCD continuously reconciles.

### Two Root Applications

ArgoCD manages two root Applications:

1. **infra** - Platform infrastructure (Cilium, cert-manager, gateways)
2. **apps** - User applications (your services)

Both use the same `platform/` chart with different values files.
