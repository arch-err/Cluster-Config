# Kubernetes Setup

After Talos bootstrap, we install the Kubernetes layer: Cilium (CNI) and ArgoCD (GitOps).

## Bootstrap Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                     just install                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. install-cilium     CNI + Gateway API + L2 announcements    │
│         │                                                       │
│         ▼                                                       │
│  2. deploy-secrets     SOPS-decrypt root CA → cert-manager ns  │
│         │                                                       │
│         ▼                                                       │
│  3. install-argocd     ArgoCD + extraObjects (root apps)       │
│         │                                                       │
│         ▼                                                       │
│  ┌──────┴──────┐                                               │
│  │   ArgoCD    │ ◄── Immediately syncs root Applications       │
│  └──────┬──────┘                                               │
│         │                                                       │
│    ┌────┴────┐                                                 │
│    ▼         ▼                                                 │
│ [infra]   [apps]   ◄── Two root ArgoCD Applications            │
│    │         │                                                 │
│    ▼         ▼                                                 │
│ platform/  platform/   ◄── Same chart, different values       │
│ + infra.yaml  + apps.yaml                                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Cilium

### Features Enabled

| Feature | Purpose |
|---------|---------|
| Gateway API | Ingress via Gateway/HTTPRoute resources |
| L2 Announcements | Announce LoadBalancer IPs on local network |
| kube-proxy replacement | eBPF-based service routing |
| DSR (Direct Server Return) | Optimized return path for load balancing |
| Hubble | Network observability |

### Configuration: `kubernetes/bootstrap/cilium.yaml`

```yaml
# Kubernetes API (for kube-proxy replacement)
k8sServiceHost: 192.168.1.70
k8sServicePort: 6443
kubeProxyReplacement: true

# Gateway API
gatewayAPI:
  enabled: true

# L2 announcements for LoadBalancer services
l2announcements:
  enabled: true

# Native routing with DSR
routingMode: native
loadBalancer:
  mode: dsr
  algorithm: maglev

# Hubble observability
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
```

### Gateway API Architecture

```
                    Internet / LAN
                         │
            ┌────────────┴────────────┐
            │                         │
    ┌───────▼───────┐        ┌───────▼───────┐
    │   Internal    │        │  Passthrough  │
    │   Gateway     │        │   Gateway     │
    │ 192.168.1.200 │        │ 192.168.1.202 │
    │               │        │               │
    │ TLS Terminate │        │ TLS Passthru  │
    │  *.home cert  │        │  (no decrypt) │
    └───────┬───────┘        └───────┬───────┘
            │                         │
    ┌───────▼───────┐        ┌───────▼───────┐
    │  HTTPRoutes   │        │   TLSRoutes   │
    │               │        │               │
    │ argocd.home   │        │ homeassistant │
    │ hubble.home   │        │ vault.home    │
    │ grafana.home  │        │ ntfy.home     │
    └───────┬───────┘        └───────┬───────┘
            │                         │
            ▼                         ▼
      Cluster Pods            Docker Host
                              (Traefik)
```

**Internal Gateway**: Terminates TLS using wildcard cert, routes to cluster services.

**Passthrough Gateway**: Passes TLS directly to Docker host for services running outside the cluster.

### L2 Announcements

Cilium announces LoadBalancer IPs on the local network using ARP:

```yaml
# Configured via platform chart (extras.yaml)
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default
spec:
  interfaces:
    - ^eth[0-9]+
    - ^en[a-z0-9]+
  loadBalancerIPs: true

---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  blocks:
    - start: "192.168.1.200"
      stop: "192.168.1.220"
```

## ArgoCD

### Bootstrap with Root Applications

The ArgoCD Helm chart is installed with `extraObjects` that create two root Applications:

```yaml
# kubernetes/bootstrap/argocd.yaml
extraObjects:
  - apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: infra
      namespace: argocd
    spec:
      source:
        repoURL: https://github.com/arch-err/Cluster-Config.git
        targetRevision: v2
        path: kubernetes/platform
        helm:
          valueFiles:
            - ../infra.yaml
      # ...

  - apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: apps
      namespace: argocd
    spec:
      source:
        repoURL: https://github.com/arch-err/Cluster-Config.git
        targetRevision: v2
        path: kubernetes/platform
        helm:
          valueFiles:
            - ../apps.yaml
      # ...
```

### ArgoCD Configuration

```yaml
server:
  ingress:
    enabled: false  # Using Gateway API instead

configs:
  params:
    server.insecure: true  # TLS terminated at gateway

  cm:
    # Override resource exclusions - allow EndpointSlice
    resource.exclusions: |
      - apiGroups:
          - ''
        kinds:
          - Endpoints
      - apiGroups:
          - cilium.io
        kinds:
          - CiliumIdentity
          - CiliumEndpoint
```

### Accessing ArgoCD

```bash
# Get admin password
just argocd-password

# Port-forward (if gateway not ready)
just argocd-ui

# Via gateway (after bootstrap complete)
https://argocd.home
```

## cert-manager

### CA Chain

```
┌─────────────────────────────────────────┐
│         home-root-ca (Secret)           │
│    SOPS-encrypted in kubernetes/secrets │
│                                          │
│    Deployed by: just deploy-secrets      │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│      home-ca (ClusterIssuer)            │
│                                          │
│    References: home-root-ca secret       │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│    wildcard-home (Certificate)          │
│                                          │
│    CN: *.home                            │
│    Secret: wildcard-home-tls             │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│      Internal Gateway                    │
│                                          │
│    Uses: wildcard-home-tls               │
│    Terminates TLS for *.home             │
└─────────────────────────────────────────┘
```

### Why SOPS-encrypt the Root CA?

When the cluster is rebuilt, the same root CA is deployed. This means:
- Devices don't need to re-import a new CA certificate
- Existing browser trust is preserved
- No certificate warnings after cluster reinstall

## External Services

Services running on the Docker host (192.168.1.60) are exposed via TLS passthrough:

```yaml
# kubernetes/infra.yaml
external:
  dockerHost: "192.168.1.60"
  passthroughIP: "192.168.1.202"
  services:
    - name: homeassistant
      hostname: homeassistant.home
    - name: vault
      hostname: vault.home
    - name: ntfy
      hostname: ntfy.home
```

This creates:
1. **Service + EndpointSlice** pointing to Docker host
2. **Passthrough Gateway** listening on 192.168.1.202
3. **TLSRoute** per service routing to the Docker host

Traffic flow:
```
Client → 192.168.1.202:443 → Cilium (passthrough) → Docker:443 → Traefik → Container
```

TLS is never decrypted by the cluster - it passes through to Traefik on the Docker host.

## Sync Waves

Resources are synced in order using ArgoCD sync waves:

| Wave | Resources |
|------|-----------|
| 0 | ArgoCD Applications (default) |
| 1 | Cilium L2 Policy, IP Pool |
| 3 | ClusterIssuer (home-ca) |
| 4 | Certificate (wildcard), ReferenceGrant |
| 5 | Gateways |
| 6 | TLSRoutes |
| 10 | HTTPRoutes |

## Troubleshooting

### Cilium Not Ready

```bash
# Check Cilium status
kubectl -n kube-system exec -it ds/cilium -- cilium status

# View Cilium logs
kubectl -n kube-system logs -l app.kubernetes.io/name=cilium
```

### Gateway Not Getting IP

```bash
# Check L2 announcements
kubectl get ciliuml2announcementpolicies
kubectl get ciliumloadbalancerippool

# Check gateway status
kubectl -n gateway-system get gateway -o wide
```

### Certificate Issues

```bash
# Check cert-manager
kubectl -n cert-manager get clusterissuer
kubectl -n cert-manager get certificate

# Check certificate secret
kubectl -n cert-manager get secret wildcard-home-tls
```

### ArgoCD Sync Issues

```bash
# Check application status
kubectl -n argocd get applications

# Force sync
argocd app sync infra --force
```
