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
│  2. install-argocd     ArgoCD + extraObjects (root apps)       │
│         │                                                       │
│         ▼                                                       │
│  3. deploy-age-key     Age key for sops-secrets-operator       │
│         │                                                       │
│         ▼                                                       │
│  ┌──────┴──────┐                                               │
│  │   ArgoCD    │ ◄── Immediately syncs root Applications       │
│  └──────┬──────┘                                               │
│         │                                                       │
│    ┌────┴────┬────────────┬────────────┐                       │
│    ▼         ▼            ▼            ▼                       │
│ [infra]   [apps]   [infra-secrets] [apps-secrets]              │
│    │         │            │            │                       │
│    ▼         ▼            ▼            ▼                       │
│ platform/  platform/   secrets/     secrets/                   │
│ + infra.yaml + apps.yaml  infra/       apps/                   │
│                                                                 │
│  ArgoCD syncs sops-secrets-operator → decrypts SopsSecrets     │
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

### Gateway API CRDs

Gateway API CRDs are installed from the official kubernetes-sigs releases before Cilium:

```bash
# Installed by just install-cilium
GWAPI_VERSION=v1.1.0  # Must match Cilium's expected version
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GWAPI_VERSION}/config/crd/experimental/...
```

**Version Compatibility**: Cilium 1.16.x requires Gateway API **v1.1.0**. Using v1.2.0+ causes schema mismatches (`supportedFeatures` field format changed).

### Gateway API Architecture

A single gateway handles both TLS termination and passthrough via SNI-based routing:

```
                         Internet / LAN
                              │
                    ┌─────────▼─────────┐
                    │  Internal Gateway │
                    │   192.168.1.200   │
                    │                   │
                    │  Multiple Listeners:
                    │  ├─ HTTPS *.home (terminate)
                    │  ├─ TLS homeassistant.home (passthrough)
                    │  ├─ TLS vault.home (passthrough)
                    │  └─ TLS ntfy.home (passthrough)
                    └─────────┬─────────┘
                              │
          ┌───────────────────┼───────────────────┐
          │                   │                   │
    ┌─────▼─────┐       ┌─────▼─────┐       ┌─────▼─────┐
    │ HTTPRoutes│       │ TLSRoutes │       │ TLSRoutes │
    │           │       │ (external)│       │ (external)│
    │ argocd    │       │ homeassist│       │ vault     │
    │ hubble    │       │ ntfy      │       │ happy.*   │
    │ grafana   │       │           │       │           │
    └─────┬─────┘       └─────┬─────┘       └─────┬─────┘
          │                   │                   │
          ▼                   └─────────┬─────────┘
    Cluster Pods                        ▼
                                  Docker Host
                                   (Traefik)
```

**How it works**:
- **HTTPS listener** (`*.home`): Terminates TLS using the wildcard cert, routes via HTTPRoutes to cluster pods
- **TLS listeners** (per external service): Pass TLS through via SNI routing to Docker host

All listeners share the same IP (192.168.1.200). Cilium uses SNI (Server Name Indication) to route traffic to the correct listener.

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

### Two-Phase Install

ArgoCD is installed in two phases because `extraObjects` contain Application CRs that require ArgoCD CRDs to exist first:

```bash
# Phase 1: Install ArgoCD (creates CRDs)
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait

# Phase 2: Upgrade with full values (extraObjects now work)
kubernetes/bootstrap/argocd.yaml --wait
```

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

### Handling Gateway API Drift

Gateway API resources show as "OutOfSync" because Kubernetes adds default values (e.g., `group: ""`, `kind: Secret`) that aren't in the original manifests. The infra Application uses `ignoreDifferences` to handle this:

```yaml
# In kubernetes/bootstrap/argocd.yaml
ignoreDifferences:
  - group: gateway.networking.k8s.io
    kind: Gateway
    jsonPointers:
      - /spec/listeners
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    jsonPointers:
      - /spec
  - group: gateway.networking.k8s.io
    kind: TLSRoute
    jsonPointers:
      - /spec
  - group: gateway.networking.k8s.io
    kind: ReferenceGrant
    jsonPointers:
      - /spec
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
│      SopsSecret: home-root-ca           │
│    kubernetes/secrets/infra/            │
│                                         │
│    Synced by: ArgoCD (infra-secrets)    │
│    Decrypted by: sops-secrets-operator  │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│    Secret: home-root-ca (auto-created)  │
│    namespace: cert-manager              │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│      home-ca (ClusterIssuer)            │
│                                         │
│    References: home-root-ca secret      │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│    wildcard-home (Certificate)          │
│                                         │
│    CN: *.home                           │
│    Secret: wildcard-home-tls            │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│      Internal Gateway                   │
│                                         │
│    Uses: wildcard-home-tls              │
│    Terminates TLS for *.home            │
└─────────────────────────────────────────┘
```

### Why SOPS-encrypt the Root CA?

When the cluster is rebuilt, the same root CA is deployed automatically via GitOps:
- Devices don't need to re-import a new CA certificate
- Existing browser trust is preserved
- No certificate warnings after cluster reinstall

## External Services

Services running on the Docker host (192.168.1.60) are exposed via TLS passthrough on the internal gateway:

```yaml
# kubernetes/infra.yaml
external:
  dockerHost: "192.168.1.60"
  services:
    - name: homeassistant
      hostname: homeassistant.home
    - name: vault
      hostname: vault.home
    - name: ntfy
      hostname: ntfy.home
```

This creates:
1. **Service + EndpointSlice** pointing to Docker host IP
2. **TLS passthrough listener** on the internal gateway (per hostname)
3. **TLSRoute** per service routing to the Docker host

Traffic flow:
```
Client → 192.168.1.200:443 → Cilium (SNI routing) → Passthrough listener → Docker:443 → Traefik
```

TLS is never decrypted by the cluster - Cilium routes based on SNI and passes TLS through to Traefik on the Docker host.

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
