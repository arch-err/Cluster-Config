# Cluster Build Plan

> Based on Plan 2 (Cilium-Native Gateway API Stack), customized through discussion.
> This is a living document - sections marked with `[TODO]` need further planning.

---

## Quick Reference

| Component | Choice | Status |
|-----------|--------|--------|
| **GitOps** | ArgoCD | Decided |
| **CNI** | Cilium | Decided |
| **Gateway** | Cilium Gateway API (Dual) | Decided |
| **SSO** | Keycloak | Decided |
| **Secrets** | SOPS + age | Decided |
| **Observability** | Loki + Prometheus + Grafana | Decided |
| **Notifications** | Gotify | Decided |
| **Uptime** | Gatus | Decided |
| **Password Manager** | Vaultwarden (internal only) | Decided |
| **Audiobooks** | Audiobookshelf | Decided |
| **Torrenting** | *arr stack + Gluetun (ProtonVPN) | Decided |
| **Home Cloud** | Nextcloud + Immich (evaluate both) | Partial |
| **Network Storage** | `[TODO]` - penguin-share mentioned | Pending |
| **File Sharing (DMZ)** | Send + PsiTransfer + Pingvin Share (compare) | Decided |
| **DMZ Security** | Start simple (namespace + policies), add zero-trust later | Decided |
| **External Access** | Cloudflare Tunnel (future) | Decided |
| **App Structure** | Meta-chart with catalog (maximum DRY) | Decided |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         FUTURE: Cloudflare Tunnel                            │
│                    (Zero exposed ports when implemented)                     │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
┌─────────────────────────────────────┼───────────────────────────────────────┐
│                       CILIUM GATEWAY API                                     │
│    ┌─────────────────────┐              ┌─────────────────────┐             │
│    │   External Gateway  │              │   Internal Gateway  │             │
│    │   *.yourdomain.com  │              │      *.home         │             │
│    │   192.168.1.201     │              │   192.168.1.200     │             │
│    │   DMZ traffic only  │              │   All internal apps │             │
│    └─────────────────────┘              └─────────────────────┘             │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CILIUM NETWORKING                                   │
│                  eBPF-based • L2 Announcements • Network Policies            │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
     ┌────────────────┬───────────────┼───────────────┬────────────────┐
     │                │               │               │                │
     ▼                ▼               ▼               ▼                ▼
┌─────────┐    ┌───────────┐   ┌───────────┐   ┌───────────┐    ┌───────────┐
│   DMZ   │    │   APPS    │   │   MEDIA   │   │ AUTOMATION│    │  SYSTEM   │
│         │    │           │   │           │   │           │    │           │
│ Send    │    │ Nextcloud │   │ Audiobook │   │ Home Asst │    │ FluxCD    │
│ PsiTrans│    │ Immich    │   │ *arr stack│   │ n8n       │    │ Keycloak  │
│ Pingvin │    │ Vaultwarden│  │ qBittorrent│  │ Gotify    │    │ Grafana   │
│         │    │ Homepage  │   │ Gluetun   │   │           │    │ Gatus     │
└─────────┘    └───────────┘   └───────────┘   └───────────┘    └───────────┘
```

---

## 1. GitOps with FluxCD

### Why FluxCD
- Kubernetes-native (CRDs, not separate UI)
- Pairs well with Cilium and Gateway API
- SOPS integration built-in
- Lighter footprint than ArgoCD

### Repository Structure

```
cluster-config/
├── flux/
│   ├── flux-system/               # FluxCD bootstrap
│   │   ├── gotk-components.yaml
│   │   ├── gotk-sync.yaml
│   │   └── kustomization.yaml
│   │
│   ├── sources/                   # HelmRepository definitions
│   │   ├── cilium.yaml
│   │   ├── grafana.yaml
│   │   ├── bitnami.yaml
│   │   └── ...
│   │
│   └── kustomizations/            # Deployment waves
│       ├── infrastructure.yaml    # Wave 1: Cilium, cert-manager
│       ├── security.yaml          # Wave 2: Keycloak, policies
│       ├── observability.yaml     # Wave 3: Grafana stack
│       └── apps.yaml              # Wave 4: User applications
│
├── infrastructure/
│   ├── cilium/
│   ├── cert-manager/
│   └── gateway-system/
│
├── security/
│   ├── keycloak/
│   ├── network-policies/
│   └── sops/                      # age keys, encryption config
│
├── observability/
│   ├── prometheus/
│   ├── loki/
│   └── grafana/
│
├── apps/                          # Meta-chart generating HelmReleases
│   ├── Chart.yaml
│   ├── values.yaml                # ← THE CATALOG (single source of truth)
│   └── templates/
│       ├── helmrelease.yaml       # Generates HelmRelease per app
│       ├── httproute.yaml         # Generates HTTPRoute per app
│       ├── namespace.yaml         # Generates Namespace per app
│       └── helmrepository.yaml    # Generates HelmRepository per app
│
├── values/                        # Per-app Helm value overrides
│   ├── nextcloud.yaml
│   ├── grafana.yaml
│   ├── home-assistant.yaml
│   └── ...
│
├── secrets/                       # SOPS-encrypted secrets
│   ├── nextcloud.yaml
│   ├── keycloak.yaml
│   └── ...
│
└── dmz/                           # DMZ apps (also in apps/values.yaml)
    ├── namespace.yaml
    └── network-policies/
```

### SOPS + age Integration

```yaml
# flux/flux-system/gotk-sync.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

Secrets are encrypted in Git, decrypted at deploy time. No external secrets store needed.

### App Catalog Schema

The `apps/values.yaml` is the single source of truth. A Helm chart generates FluxCD `HelmRelease`, `HTTPRoute`, `Namespace`, and `HelmRepository` CRs from this catalog.

#### Smart Defaults

| Field | Default Value |
|-------|---------------|
| `namespace` | Same as `name` |
| `chart.name` | Same as `name` |
| `gateway.hostname` | `<name>.home` (or `<name><domainSuffix>`) |
| `gateway.class` | `internal` |
| `gateway.tls.secretName` | `wildcard-home-tls` |
| `homepage.name` | Titlecase of `name` |
| `homepage.icon` | `<name>.png` |
| `homepage.group` | Titlecase of `namespace` |
| `sso.provider` | `keycloak` |
| `sso.policy` | `one_factor` |
| `storage.class` | `kadalu.replica2` |
| `storage.accessMode` | `ReadWriteOnce` |
| `monitoring.gatus.enabled` | `true` |
| `monitoring.gatus.interval` | `60s` |

#### Full Schema

```yaml
# apps/values.yaml

defaults:
  gateway:
    class: internal
    tls:
      secretName: wildcard-home-tls
    domainSuffix: .home
  sso:
    provider: keycloak
    realm: home
    policy: one_factor
  storage:
    class: kadalu.replica2
    accessMode: ReadWriteOnce
  monitoring:
    gatus:
      enabled: true
      interval: 60s
      conditions:
        - "[STATUS] == 200"

apps:
  # ════════════════════════════════════════════════════════════════
  # MINIMAL EXAMPLE - all defaults applied
  # ════════════════════════════════════════════════════════════════
  - name: excalidraw
    chart:
      repo: https://pmoscode-helm.github.io/excalidraw/
      version: 0.1.1
    # Resulting defaults:
    #   namespace: excalidraw
    #   chart.name: excalidraw
    #   gateway.hostname: excalidraw.home
    #   homepage.name: Excalidraw
    #   homepage.group: Excalidraw

  # ════════════════════════════════════════════════════════════════
  # FULL EXAMPLE - all fields shown
  # ════════════════════════════════════════════════════════════════
  - name: nextcloud
    namespace: apps                    # Override default

    chart:
      repo: https://nextcloud.github.io/helm
      name: nextcloud                  # Can differ from app name
      version: 5.x
      valuesPath: ""                   # For charts with nested values structure
                                       # e.g., "server" → values go under .Values.server

    gateway:
      enabled: true
      class: internal                  # internal | external
      hostname: cloud.home             # Override default <name>.home
      tls:
        secretName: wildcard-home-tls

    sso:
      enabled: true
      provider: keycloak
      policy: two_factor               # one_factor | two_factor | bypass
      bypassPaths:                     # Skip auth for these paths
        - /api/*
        - /public/*

    storage:
      enabled: true
      class: kadalu.replica2
      size: 500Gi
      accessMode: ReadWriteOnce

    secrets:
      enabled: true                    # Auto-loads secrets/<name>.yaml

    monitoring:
      gatus:
        enabled: true
        interval: 60s
        conditions:
          - "[STATUS] == 200"
          - "[RESPONSE_TIME] < 3000"
        alerts:
          - gotify

    homepage:
      enabled: true
      name: "Cloud Storage"            # Override default titlecase
      group: Apps
      icon: nextcloud.png
      description: "Personal cloud"
      siteMonitor: https://cloud.home/status

    scheduling:
      nodeSelector: {}
      tolerations: []
      affinity: {}

    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 1000m
        memory: 2Gi

    hostNetwork: false                 # Set true for mDNS (Home Assistant)
    privileged: false                  # Set true for USB access

  # ════════════════════════════════════════════════════════════════
  # CHART WITH WEIRD VALUES STRUCTURE
  # ════════════════════════════════════════════════════════════════
  - name: prometheus
    namespace: monitoring
    chart:
      repo: https://prometheus-community.github.io/helm-charts
      name: prometheus
      version: 25.x
      valuesPath: server               # Values wrapped under .Values.server

  # ════════════════════════════════════════════════════════════════
  # EXTERNAL/DMZ APP
  # ════════════════════════════════════════════════════════════════
  - name: send
    namespace: dmz
    chart:
      repo: ghcr.io/timvisee/send
      name: send
      version: 1.x
    gateway:
      class: external
      hostname: send.yourdomain.com
    sso:
      enabled: false
    homepage:
      enabled: false
    monitoring:
      gatus:
        alerts:
          - gotify
          - email
```

#### Generated Resources

For each app in the catalog, the template generates:

1. **Namespace** (if doesn't exist)
2. **HelmRepository** (pointing to chart.repo)
3. **HelmRelease** (with valuesFrom pointing to values/<name>.yaml and secrets/<name>.yaml)
4. **HTTPRoute** (if gateway.enabled, routing to the service)

#### Values Path Handling

Some charts have unconventional structures. The `valuesPath` field handles this:

```yaml
# If valuesPath: server
# Generated values are wrapped:
server:
  ingress:
    enabled: true
    hosts:
      - host: prometheus.home

# If valuesPath: authentik.server (nested)
# Generated values are wrapped:
authentik:
  server:
    ingress:
      enabled: true
```

---

## 2. Networking

### Cilium Configuration

```yaml
# infrastructure/cilium/values.yaml
cluster:
  name: home-cluster
  id: 1

kubeProxyReplacement: true

# Gateway API
gatewayAPI:
  enabled: true

# eBPF features
loadBalancer:
  mode: dsr
  algorithm: maglev

# L2 announcements for LoadBalancer IPs
l2announcements:
  enabled: true

# Hubble observability
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enabled:
      - dns
      - drop
      - tcp
      - flow
      - httpV2

ipam:
  mode: kubernetes

bpf:
  masquerade: true
```

### LoadBalancer IP Pool

```yaml
# infrastructure/cilium/ip-pool.yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  blocks:
    - start: 192.168.1.200
      stop: 192.168.1.220
```

### Dual Gateway Setup

**Internal Gateway (*.home):**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: internal
  namespace: gateway-system
spec:
  gatewayClassName: cilium
  addresses:
    - type: IPAddress
      value: 192.168.1.200
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "*.home"
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-home-tls
      allowedRoutes:
        namespaces:
          from: All
```

**External Gateway (*.yourdomain.com):**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external
  namespace: gateway-system
spec:
  gatewayClassName: cilium
  addresses:
    - type: IPAddress
      value: 192.168.1.201
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "*.yourdomain.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: external-tls
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: dmz
```

---

## 3. Certificate Management

### Self-Signed CA Chain

```yaml
# infrastructure/cert-manager/cluster-issuers.yaml
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: home-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: "Home Lab Root CA"
  secretName: home-root-ca
  duration: 87600h    # 10 years
  privateKey:
    algorithm: ECDSA
    size: 384
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: home-ca
spec:
  ca:
    secretName: home-root-ca
```

### Wildcard Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-home
  namespace: cert-manager
spec:
  secretName: wildcard-home-tls
  duration: 8760h     # 1 year
  renewBefore: 720h   # 30 days
  dnsNames:
    - "*.home"
    - "*.apps.home"
    - "*.media.home"
  issuerRef:
    name: home-ca
    kind: ClusterIssuer
```

**Trust Distribution:** Export CA cert and install on devices (phones, PCs, browsers).

---

## 4. SSO with Keycloak

### Why Keycloak
- Industry standard OIDC/SAML
- Full protocol support for apps that need native OIDC
- Realm export for GitOps configuration
- Well-documented, huge community

### Deployment

```yaml
# security/keycloak/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: keycloak
  namespace: keycloak
spec:
  chart:
    spec:
      chart: keycloak
      sourceRef:
        kind: HelmRepository
        name: bitnami
  values:
    auth:
      adminUser: admin
      existingSecret: keycloak-admin  # SOPS encrypted

    production: true
    proxy: edge

    postgresql:
      enabled: true
      auth:
        existingSecret: keycloak-db  # SOPS encrypted
```

### Realm Configuration (GitOps)

Keycloak realms can be exported as JSON and imported at startup:

```yaml
# security/keycloak/realm/home-realm.json
{
  "realm": "home",
  "enabled": true,
  "ssoSessionIdleTimeout": 86400,
  "clients": [
    {
      "clientId": "nextcloud",
      "enabled": true,
      "protocol": "openid-connect",
      "redirectUris": ["https://cloud.home/*"]
    },
    {
      "clientId": "grafana",
      "enabled": true,
      "protocol": "openid-connect",
      "redirectUris": ["https://grafana.home/*"]
    }
    // ... more clients
  ]
}
```

---

## 5. DMZ Design

### Namespace Configuration

```yaml
# dmz/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dmz
  labels:
    pod-security.kubernetes.io/enforce: restricted
    gateway-access: dmz
    network-zone: dmz
```

### Network Policies (Start Simple)

```yaml
# dmz/network-policies/default-deny.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: dmz
spec:
  endpointSelector: {}
  ingressDeny:
    - {}
  egressDeny:
    - {}
---
# dmz/network-policies/allow-gateway.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-gateway-ingress
  namespace: dmz
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.cilium.k8s.policy.serviceaccount: cilium-gateway
---
# dmz/network-policies/allow-dns.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns
  namespace: dmz
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
```

### DMZ Apps (File Sharing Comparison)

| App | Description | Use Case |
|-----|-------------|----------|
| **Send** | Firefox Send fork, encrypted, self-destructing | Quick secure transfers |
| **PsiTransfer** | Simple upload/download | Lightweight sharing |
| **Pingvin Share** | Feature-rich, accounts, expiring links | More permanent sharing |

All three will be deployed for comparison, then we'll pick a favorite.

---

## 6. Observability Stack

### Components

| Component | Purpose |
|-----------|---------|
| **Prometheus** | Metrics collection and storage |
| **Loki** | Log aggregation |
| **Grafana** | Visualization and dashboards |
| **Hubble** | Cilium network observability |
| **Alloy** | Unified collector (optional) |

### Prometheus + Grafana

```yaml
# observability/prometheus/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: observability
spec:
  chart:
    spec:
      chart: kube-prometheus-stack
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
  values:
    grafana:
      enabled: true
      ingress:
        enabled: false  # Using Gateway API
      # Keycloak OIDC integration
      grafana.ini:
        auth.generic_oauth:
          enabled: true
          name: Keycloak
          client_id: grafana
          scopes: openid profile email
          auth_url: https://auth.home/realms/home/protocol/openid-connect/auth
          token_url: https://auth.home/realms/home/protocol/openid-connect/token
```

### Loki

```yaml
# observability/loki/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: loki
  namespace: observability
spec:
  chart:
    spec:
      chart: loki
      sourceRef:
        kind: HelmRepository
        name: grafana
  values:
    deploymentMode: SingleBinary  # Simple for home lab
    loki:
      auth_enabled: false
      storage:
        type: filesystem
    singleBinary:
      replicas: 1
      persistence:
        storageClass: kadalu.replica2
        size: 50Gi
```

### Gatus (Uptime Monitoring)

```yaml
# observability/gatus/config.yaml
endpoints:
  - name: Nextcloud
    group: Apps
    url: https://cloud.home
    interval: 60s
    conditions:
      - "[STATUS] == 200"
      - "[RESPONSE_TIME] < 2000"
    alerts:
      - type: gotify
        send-on-resolved: true

  - name: Vaultwarden
    group: Apps
    url: https://vault.home
    interval: 60s
    conditions:
      - "[STATUS] == 200"

  - name: Home Assistant
    group: Automation
    url: https://hass.home
    interval: 30s
    conditions:
      - "[STATUS] == 200"
```

---

## 7. Applications

### Internal Apps (*.home)

| App | Namespace | Hostname | SSO | Storage |
|-----|-----------|----------|-----|---------|
| Nextcloud | apps | cloud.home | Keycloak OIDC | 500Gi |
| Immich | apps | photos.home | Keycloak OIDC | 500Gi |
| Vaultwarden | apps | vault.home | Built-in | 2Gi |
| Homepage | apps | home.home | Optional | - |
| Audiobookshelf | media | audiobooks.home | Keycloak | 200Gi |
| Sonarr | media | sonarr.home | Keycloak | 10Gi |
| Radarr | media | radarr.home | Keycloak | 10Gi |
| Prowlarr | media | prowlarr.home | Keycloak | 5Gi |
| qBittorrent | media | qbit.home | Built-in | 1Ti (downloads) |
| Home Assistant | automation | hass.home | Built-in | 10Gi |
| n8n | automation | n8n.home | Keycloak | 10Gi |
| Gotify | automation | notify.home | Built-in | 1Gi |
| Grafana | observability | grafana.home | Keycloak | - |
| Gatus | observability | status.home | None (public) | 5Gi |
| Hubble UI | observability | hubble.home | Keycloak | - |

### DMZ Apps (*.yourdomain.com)

| App | Hostname | Purpose |
|-----|----------|---------|
| Send | send.yourdomain.com | Encrypted file transfers |
| PsiTransfer | transfer.yourdomain.com | Simple file sharing |
| Pingvin Share | share.yourdomain.com | Feature-rich sharing |

### Home Assistant + Zigbee

```yaml
# apps/home-assistant/deployment.yaml
spec:
  template:
    spec:
      hostNetwork: true           # Required for mDNS
      nodeSelector:
        kubernetes.io/hostname: node-1  # Zigbee dongle pinned here
      containers:
        - name: home-assistant
          image: ghcr.io/home-assistant/home-assistant:stable
          volumeMounts:
            - name: config
              mountPath: /config

        - name: zigbee2mqtt
          image: koenkk/zigbee2mqtt:latest
          securityContext:
            privileged: true      # Required for USB
          volumeMounts:
            - name: zigbee-device
              mountPath: /dev/ttyUSB0

        - name: mosquitto
          image: eclipse-mosquitto:2
```

### *arr Stack with Gluetun (ProtonVPN)

```yaml
# apps/arr-stack/gluetun.yaml
containers:
  - name: gluetun
    image: qmcgaw/gluetun:latest
    env:
      - name: VPN_SERVICE_PROVIDER
        value: protonvpn
      - name: VPN_TYPE
        value: wireguard
      - name: WIREGUARD_PRIVATE_KEY
        valueFrom:
          secretKeyRef:
            name: protonvpn-credentials  # SOPS encrypted
            key: private-key
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]

  - name: qbittorrent
    image: linuxserver/qbittorrent:latest
    # Network through Gluetun
```

---

## 8. TODO / Needs Discussion

### High Priority

- [x] **App deployment structure** - ~~Single catalog file vs directory-per-app vs hybrid?~~
  - **DECIDED:** Meta-chart with catalog (`apps/values.yaml`) generating HelmRelease CRs
  - Maximum DRY, smart defaults, handles weird chart value structures
  - Per-app values in `values/<name>.yaml`, secrets in `secrets/<name>.yaml`

- [ ] **Network file storage** - How to mount storage on phone/PC?
  - Options mentioned: penguin-share, Syncthing, Seafile, Samba
  - Consider: sync vs network share, mobile app support, security

### Medium Priority

- [ ] **Cloudflare Tunnel setup** - Implementation details when ready
  - Cloudflared deployment
  - DNS configuration
  - Access policies

- [ ] **Immich vs Nextcloud evaluation** - Deploy both, compare:
  - Immich for photos/videos specifically
  - Nextcloud for files/calendar/contacts
  - Or just one of them?

- [ ] **ELK stack** - Future log monitoring enhancement
  - Elasticsearch, Logstash, Kibana
  - Evaluate if needed alongside Loki

### Low Priority (Future Enhancements)

- [ ] **Zero-trust enhancements** for DMZ
  - Cilium mTLS
  - SPIFFE/SPIRE workload identity
  - Falco runtime monitoring
  - Kyverno policies

- [ ] **Dynamic Zigbee node detection**
  - Node Feature Discovery for USB detection
  - Remove hard-coded node-1 pinning

- [ ] **VPN for all external traffic** (not just torrents)
  - Route specific apps through VPN
  - Split tunneling considerations

---

## 9. Bootstrap Process

```bash
#!/bin/bash
# bootstrap.sh

set -e

KUBECONFIG="${KUBECONFIG:-./talos/clusterconfig/kubeconfig}"

# Prerequisites check
command -v flux >/dev/null || { echo "Install flux CLI"; exit 1; }
command -v sops >/dev/null || { echo "Install sops"; exit 1; }
command -v age >/dev/null || { echo "Install age"; exit 1; }

# Generate age key if not exists
if [ ! -f ~/.config/sops/age/keys.txt ]; then
  mkdir -p ~/.config/sops/age
  age-keygen -o ~/.config/sops/age/keys.txt
  echo "Age key generated. Add public key to .sops.yaml"
fi

# Bootstrap FluxCD
flux bootstrap github \
  --owner=arch-err \
  --repository=cluster-config \
  --branch=main \
  --path=./flux \
  --personal

# Create SOPS secret for FluxCD
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt

echo "=== FluxCD bootstrapped ==="
echo "Watch progress: flux get kustomizations --watch"
```

---

## 10. IP Address Allocation

| IP | Service |
|----|---------|
| 192.168.1.200 | Internal Gateway (*.home) |
| 192.168.1.201 | External Gateway (*.yourdomain.com) |
| 192.168.1.202 | Syncthing sync (if used) |
| 192.168.1.203-220 | Available for services |

---

## Revision History

| Date | Changes |
|------|---------|
| 2026-02-24 | Initial plan created from discussion |
| 2026-02-24 | Added app deployment structure (meta-chart with catalog, smart defaults) |
