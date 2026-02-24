# Plan 1: The Classic GitOps Stack

## Philosophy
This plan embraces battle-tested, well-documented solutions. It prioritizes stability, community support, and ease of troubleshooting over cutting-edge features. Perfect for a home lab that needs to "just work."

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              EXTERNAL TRAFFIC                                │
│                         (Cloudflare Tunnel / Port Forward)                   │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           INGRESS-NGINX (DMZ)                                │
│                    External-facing services only                             │
│                    + Crowdsec bouncer for WAF                                │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
┌─────────────────────────────────────────────────────────────────────────────┐
│                          INGRESS-NGINX (Internal)                            │
│                    All internal *.home services                              │
│                    + Forward Auth to Authentik                               │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
┌──────────────────┬──────────────────┼──────────────────┬────────────────────┐
│                  │                  │                  │                    │
▼                  ▼                  ▼                  ▼                    ▼
┌────────┐   ┌──────────┐   ┌─────────────┐   ┌──────────────┐   ┌───────────┐
│  DMZ   │   │  APPS    │   │  MEDIA      │   │  AUTOMATION  │   │  SYSTEM   │
│        │   │          │   │             │   │              │   │           │
│ Send   │   │ Nextcloud│   │ Audiobookshlf│  │ Home Assistant│  │ ArgoCD    │
│ Vault  │   │ Homepage │   │ *arr stack  │   │ n8n          │   │ Grafana   │
│ warden │   │ Uptime   │   │ qBittorrent │   │ ntfy/Gotify  │   │ Authentik │
└────────┘   └──────────┘   └─────────────┘   └──────────────┘   └───────────┘
```

---

## 1. GitOps Structure

### Tool: ArgoCD with App-of-Apps Pattern

```
cluster-config/
├── bootstrap/
│   ├── argocd/                    # ArgoCD installation (Helm)
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       └── root-app.yaml      # Points to applications/
│   └── install.sh                 # One-command bootstrap
│
├── applications/
│   ├── _catalog.yaml              # ← Single source of truth (your preference!)
│   ├── README.md
│   └── templates/                 # Auto-generated from catalog
│
├── infrastructure/
│   │
│   ├── cilium/
│   │   ├── values.yaml
│   │   └── network-policies/
│   │
│   ├── ingress-nginx/
│   │   ├── internal/
│   │   │   └── values.yaml
│   │   └── external/
│   │   │   └── values.yaml
│   │
│   ├── cert-manager/
│   │   ├── values.yaml
│   │   └── issuers/
│   │       ├── selfsigned-ca.yaml
│   │       └── home-issuer.yaml
│   │
│   ├── external-secrets/
│   │   └── values.yaml
│   │
│   └── authentik/
│       ├── values.yaml
│       └── blueprints/            # SSO configs as code
│
├── apps/
│   ├── nextcloud/
│   ├── vaultwarden/
│   ├── audiobookshelf/
│   ├── home-assistant/
│   ├── arr-stack/
│   ├── homepage/
│   ├── uptime-kuma/
│   ├── n8n/
│   ├── gotify/
│   └── filebrowser/
│
├── dmz/
│   ├── namespace.yaml             # Restricted namespace
│   ├── network-policies.yaml      # Deny-all + explicit allows
│   ├── send/                      # File sharing (internet-facing)
│   └── vaultwarden/               # Password manager (internet-facing)
│
└── observability/
    ├── grafana/
    ├── loki/
    ├── tempo/
    ├── prometheus/
    └── alloy/                     # Unified collector
```

### The Catalog File (_catalog.yaml)

This is your single source of truth - similar to what you have now:

```yaml
# applications/_catalog.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-catalog
  namespace: argocd
data:
  applications: |
    # ══════════════════════════════════════════════════════════════════
    # INFRASTRUCTURE
    # ══════════════════════════════════════════════════════════════════
    - name: cilium
      namespace: kube-system
      source:
        repoURL: https://helm.cilium.io
        chart: cilium
        version: 1.16.x
      sync: auto
      wave: 1

    - name: ingress-nginx-internal
      namespace: ingress-internal
      source:
        repoURL: https://kubernetes.github.io/ingress-nginx
        chart: ingress-nginx
        version: 4.x
      createNamespace: true
      sync: auto
      wave: 2
      components:
        - ingress          # Creates default IngressClass
        - certificates     # Wildcard cert for *.home

    - name: ingress-nginx-external
      namespace: ingress-external
      source:
        repoURL: https://kubernetes.github.io/ingress-nginx
        chart: ingress-nginx
        version: 4.x
      createNamespace: true
      sync: auto
      wave: 2
      components:
        - ingress
        - crowdsec-bouncer # WAF protection

    - name: cert-manager
      namespace: cert-manager
      source:
        repoURL: https://charts.jetstack.io
        chart: cert-manager
        version: 1.x
      createNamespace: true
      sync: auto
      wave: 1
      components:
        - crds
        - issuers          # Self-signed CA chain

    - name: authentik
      namespace: authentik
      source:
        repoURL: https://charts.goauthentik.io
        chart: authentik
        version: 2024.x
      createNamespace: true
      sync: auto
      wave: 3
      components:
        - sso-providers    # OIDC/SAML configs
        - outposts         # Embedded proxy

    # ══════════════════════════════════════════════════════════════════
    # OBSERVABILITY
    # ══════════════════════════════════════════════════════════════════
    - name: kube-prometheus-stack
      namespace: observability
      source:
        repoURL: https://prometheus-community.github.io/helm-charts
        chart: kube-prometheus-stack
        version: 65.x
      createNamespace: true
      sync: auto
      wave: 2

    - name: loki
      namespace: observability
      source:
        repoURL: https://grafana.github.io/helm-charts
        chart: loki
        version: 6.x
      sync: auto
      wave: 2

    - name: tempo
      namespace: observability
      source:
        repoURL: https://grafana.github.io/helm-charts
        chart: tempo
        version: 1.x
      sync: auto
      wave: 2

    - name: alloy
      namespace: observability
      source:
        repoURL: https://grafana.github.io/helm-charts
        chart: alloy
        version: 0.x
      sync: auto
      wave: 2

    # ══════════════════════════════════════════════════════════════════
    # DMZ (Internet-Facing)
    # ══════════════════════════════════════════════════════════════════
    - name: send
      namespace: dmz
      source:
        repoURL: https://github.com/arch-err/cluster-config
        path: apps/dmz/send
        targetRevision: main
      sync: auto
      wave: 10
      dmz: true            # Applies DMZ network policies
      ingress:
        external: true
        host: send.yourdomain.com

    - name: vaultwarden
      namespace: dmz
      source:
        repoURL: https://charts.gabe565.com
        chart: vaultwarden
        version: 1.x
      sync: auto
      wave: 10
      dmz: true
      ingress:
        external: true
        host: vault.yourdomain.com

    # ══════════════════════════════════════════════════════════════════
    # APPLICATIONS
    # ══════════════════════════════════════════════════════════════════
    - name: nextcloud
      namespace: apps
      source:
        repoURL: https://nextcloud.github.io/helm
        chart: nextcloud
        version: 5.x
      sync: auto
      wave: 10
      components:
        - ingress
        - sso              # Authentik OIDC
      storage:
        class: kadalu.replica2
        size: 500Gi

    - name: audiobookshelf
      namespace: media
      source:
        repoURL: https://github.com/arch-err/cluster-config
        path: apps/audiobookshelf
        targetRevision: main
      sync: auto
      wave: 10
      components:
        - ingress
        - sso
      storage:
        class: kadalu.replica2
        size: 200Gi

    - name: arr-stack
      namespace: media
      source:
        repoURL: https://github.com/arch-err/cluster-config
        path: apps/arr-stack
        targetRevision: main
      sync: auto
      wave: 10
      components:
        - sonarr
        - radarr
        - prowlarr
        - qbittorrent
        - recyclarr        # Auto-configure quality profiles
        - gluetun          # VPN container
      storage:
        downloads:
          class: kadalu.replica2
          size: 1Ti
        config:
          class: kadalu.replica2
          size: 10Gi

    - name: home-assistant
      namespace: automation
      source:
        repoURL: https://github.com/arch-err/cluster-config
        path: apps/home-assistant
        targetRevision: main
      sync: auto
      wave: 10
      components:
        - ingress
        - zigbee2mqtt      # USB passthrough to specific node
        - mosquitto        # MQTT broker
      nodeSelector:
        zigbee-dongle: "true"   # Schedule on node with USB dongle
      hostNetwork: true         # Required for mDNS discovery

    - name: homepage
      namespace: apps
      source:
        repoURL: https://jameswynn.github.io/helm-charts
        chart: homepage
        version: 2.x
      sync: auto
      wave: 10
      components:
        - ingress
        - service-discovery  # Auto-discover services

    - name: uptime-kuma
      namespace: apps
      source:
        repoURL: https://github.com/arch-err/cluster-config
        path: apps/uptime-kuma
        targetRevision: main
      sync: auto
      wave: 10
      components:
        - ingress
        - sso

    - name: n8n
      namespace: automation
      source:
        repoURL: https://github.com/arch-err/cluster-config
        path: apps/n8n
        targetRevision: main
      sync: auto
      wave: 10
      components:
        - ingress
        - sso
      storage:
        class: kadalu.replica2
        size: 10Gi

    - name: gotify
      namespace: automation
      source:
        repoURL: https://github.com/arch-err/cluster-config
        path: apps/gotify
        targetRevision: main
      sync: auto
      wave: 10
      components:
        - ingress
      # Note: Using Gotify instead of ntfy - better mobile app,
      # native push notifications, simpler setup

    - name: filebrowser
      namespace: apps
      source:
        repoURL: https://github.com/arch-err/cluster-config
        path: apps/filebrowser
        targetRevision: main
      sync: auto
      wave: 10
      components:
        - ingress
        - sso
        - smb-server       # Samba sidecar for phone/desktop mounting
      storage:
        class: kadalu.replica2
        size: 500Gi
```

### ApplicationSet Generator

ArgoCD ApplicationSet reads the catalog and generates apps:

```yaml
# applications/templates/appset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-apps
  namespace: argocd
spec:
  generators:
    - plugin:
        configMapRef:
          name: app-catalog
        input:
          parameters:
            key: applications
  template:
    metadata:
      name: "{{name}}"
      annotations:
        argocd.argoproj.io/sync-wave: "{{wave}}"
    spec:
      project: default
      source:
        repoURL: "{{source.repoURL}}"
        chart: "{{source.chart}}"
        path: "{{source.path}}"
        targetRevision: "{{source.version}}{{source.targetRevision}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{namespace}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace={{createNamespace}}
```

---

## 2. Networking & Ingress

### Cilium Configuration

```yaml
# infrastructure/cilium/values.yaml
cluster:
  name: home-cluster
  id: 1

ipam:
  mode: kubernetes

kubeProxyReplacement: true

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true

loadBalancer:
  mode: dsr
  algorithm: maglev

bpf:
  masquerade: true

operator:
  replicas: 1

# L2 announcements for LoadBalancer IPs
l2announcements:
  enabled: true

externalIPs:
  enabled: true
```

### Dual Ingress Setup

**Internal Ingress (*.home):**
```yaml
# infrastructure/ingress-nginx/internal/values.yaml
controller:
  ingressClass: internal
  ingressClassResource:
    name: internal
    default: true

  service:
    type: LoadBalancer
    loadBalancerIP: 192.168.1.200  # Static IP for DNS

  config:
    use-forwarded-headers: "true"
    proxy-body-size: "0"           # Unlimited for Nextcloud
    proxy-read-timeout: "3600"
    proxy-send-timeout: "3600"

  # Forward auth to Authentik for SSO
  extraArgs:
    default-ssl-certificate: "cert-manager/wildcard-home-tls"
```

**External Ingress (DMZ):**
```yaml
# infrastructure/ingress-nginx/external/values.yaml
controller:
  ingressClass: external
  ingressClassResource:
    name: external
    default: false

  service:
    type: LoadBalancer
    loadBalancerIP: 192.168.1.201

  config:
    use-forwarded-headers: "true"
    # Cloudflare IPs for X-Forwarded-For
    proxy-real-ip-cidr: "173.245.48.0/20,103.21.244.0/22,..."

  # CrowdSec WAF
  extraVolumes:
    - name: crowdsec-bouncer
      configMap:
        name: crowdsec-bouncer-config
```

---

## 3. Certificate Management

### Self-Signed CA Chain

```yaml
# infrastructure/cert-manager/issuers/selfsigned-ca.yaml
---
# Root CA (offline, just for signing intermediate)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
# Root CA Certificate
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: home-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: "Home Lab Root CA"
  secretName: home-root-ca-secret
  duration: 87600h    # 10 years
  privateKey:
    algorithm: ECDSA
    size: 384
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
---
# Intermediate CA (used for issuing certs)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: home-ca-issuer
spec:
  ca:
    secretName: home-root-ca-secret
---
# Wildcard certificate for *.home
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-home
  namespace: cert-manager
spec:
  secretName: wildcard-home-tls
  duration: 8760h     # 1 year
  renewBefore: 720h   # 30 days
  commonName: "*.home"
  dnsNames:
    - "*.home"
    - "*.apps.home"
    - "*.media.home"
    - "*.automation.home"
  issuerRef:
    name: home-ca-issuer
    kind: ClusterIssuer
```

**Trust Distribution:**
- Export `home-root-ca-secret` CA cert
- Install on phones/PCs/browsers
- Use `trust-manager` to distribute to pods

---

## 4. Secure DMZ Design

### Namespace Configuration

```yaml
# dmz/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dmz
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
    network-zone: dmz
```

### Network Policies (Cilium)

```yaml
# dmz/network-policies.yaml
---
# Default deny all
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: dmz
spec:
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - {}
---
# Allow ingress from external ingress controller only
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-external-ingress
  namespace: dmz
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: ingress-nginx
            io.kubernetes.pod.namespace: ingress-external
---
# Allow DNS
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
---
# Vaultwarden: Allow HTTPS out for push notifications only
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: vaultwarden-egress
  namespace: dmz
spec:
  endpointSelector:
    matchLabels:
      app: vaultwarden
  egress:
    - toFQDNs:
        - matchName: "push.bitwarden.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
---
# Block all inter-pod traffic in DMZ
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: isolate-pods
  namespace: dmz
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: dmz
      # Empty - denies all from same namespace
```

---

## 5. SSO with Authentik

### Why Authentik?
- Beautiful UI
- OIDC, SAML, LDAP, Proxy auth
- Built-in outpost for forward auth
- Blueprints for GitOps

### Configuration

```yaml
# infrastructure/authentik/values.yaml
authentik:
  secret_key: "${AUTHENTIK_SECRET_KEY}"  # From external-secrets
  postgresql:
    password: "${AUTHENTIK_PG_PASSWORD}"

postgresql:
  enabled: true
  persistence:
    storageClass: kadalu.replica2

redis:
  enabled: true

server:
  ingress:
    enabled: true
    ingressClassName: internal
    hosts:
      - auth.home
    tls:
      - secretName: wildcard-home-tls
        hosts:
          - auth.home
```

### Forward Auth Middleware

```yaml
# For apps that don't support OIDC natively
apiVersion: v1
kind: ConfigMap
metadata:
  name: authentik-forward-auth
data:
  nginx-snippet: |
    auth_request /outpost.goauthentik.io/auth/nginx;
    error_page 401 = @goauthentik_proxy_signin;
    auth_request_set $auth_cookie $upstream_http_set_cookie;
    add_header Set-Cookie $auth_cookie;

    # Pass user info to upstream
    auth_request_set $authentik_username $upstream_http_x_authentik_username;
    proxy_set_header X-authentik-username $authentik_username;
```

---

## 6. Application Configurations

### Home Assistant + Zigbee

```yaml
# apps/home-assistant/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: home-assistant
  namespace: automation
spec:
  selector:
    matchLabels:
      app: home-assistant
  template:
    metadata:
      labels:
        app: home-assistant
    spec:
      hostNetwork: true          # Required for mDNS
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        feature.node.kubernetes.io/usb-ff_1a86_55d4.present: "true"  # Zigbee dongle
      containers:
        - name: home-assistant
          image: ghcr.io/home-assistant/home-assistant:stable
          ports:
            - containerPort: 8123
          volumeMounts:
            - name: config
              mountPath: /config
          securityContext:
            privileged: false
            capabilities:
              drop: ["ALL"]

        - name: zigbee2mqtt
          image: koenkk/zigbee2mqtt:latest
          volumeMounts:
            - name: zigbee-config
              mountPath: /app/data
            - name: zigbee-device
              mountPath: /dev/ttyUSB0
          securityContext:
            privileged: true     # Required for USB access

        - name: mosquitto
          image: eclipse-mosquitto:2
          ports:
            - containerPort: 1883
          volumeMounts:
            - name: mosquitto-config
              mountPath: /mosquitto/config

      volumes:
        - name: zigbee-device
          hostPath:
            path: /dev/ttyUSB0
            type: CharDevice
        - name: config
          persistentVolumeClaim:
            claimName: home-assistant-config
        - name: zigbee-config
          persistentVolumeClaim:
            claimName: zigbee2mqtt-config
        - name: mosquitto-config
          configMap:
            name: mosquitto-config
```

**Node labeling for Zigbee:**
```yaml
# In Talos machine config for the node with the dongle
machine:
  nodeLabels:
    zigbee-dongle: "true"

  # USB passthrough
  udev:
    rules:
      - SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="55d4", SYMLINK+="ttyUSB0", MODE="0666"
```

### *arr Stack with VPN

```yaml
# apps/arr-stack/values.yaml
gluetun:
  enabled: true
  vpn:
    provider: mullvad     # Or any WireGuard provider
    type: wireguard
  existingSecret: vpn-credentials

qbittorrent:
  enabled: true
  network:
    useGluetun: true      # Route through VPN
  ingress:
    enabled: true
    className: internal
    host: qbit.home

sonarr:
  enabled: true
  ingress:
    enabled: true
    className: internal
    host: sonarr.home
    annotations:
      nginx.ingress.kubernetes.io/auth-url: "https://auth.home/outpost.goauthentik.io/auth/nginx"

radarr:
  enabled: true
  ingress:
    enabled: true
    className: internal
    host: radarr.home
    annotations:
      nginx.ingress.kubernetes.io/auth-url: "https://auth.home/outpost.goauthentik.io/auth/nginx"

prowlarr:
  enabled: true
  ingress:
    enabled: true
    className: internal
    host: prowlarr.home

# Shared storage between all *arr apps
persistence:
  downloads:
    enabled: true
    storageClass: kadalu.replica2
    size: 1Ti
    accessMode: ReadWriteMany
  media:
    enabled: true
    storageClass: kadalu.replica2
    size: 2Ti
    accessMode: ReadWriteMany
```

### Network Storage (FileBrowser + Samba)

```yaml
# apps/filebrowser/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: filebrowser
  namespace: apps
spec:
  template:
    spec:
      containers:
        - name: filebrowser
          image: filebrowser/filebrowser:latest
          ports:
            - containerPort: 80
          volumeMounts:
            - name: data
              mountPath: /srv
            - name: config
              mountPath: /config

        # Samba sidecar for SMB mounting
        - name: samba
          image: dperson/samba:latest
          ports:
            - containerPort: 445
              hostPort: 445       # Expose on node IP
          env:
            - name: USER
              value: "archerr;password"
            - name: SHARE
              value: "files;/srv;yes;no;no;archerr"
          volumeMounts:
            - name: data
              mountPath: /srv
          securityContext:
            capabilities:
              add: ["NET_ADMIN"]

      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: filebrowser-data
```

**Mounting on devices:**
- **Linux**: `mount -t cifs //node-ip/files /mnt/files -o user=archerr`
- **Android**: Solid Explorer, CX File Explorer with SMB
- **iOS**: Files app → Connect to Server

---

## 7. Observability Stack

### Grafana Alloy (Unified Collector)

```yaml
# observability/alloy/values.yaml
alloy:
  configMap:
    content: |
      // Prometheus scraping
      prometheus.scrape "kubernetes" {
        targets = discovery.kubernetes.pods.targets
        forward_to = [prometheus.remote_write.mimir.receiver]
      }

      // Loki log collection
      loki.source.kubernetes "pods" {
        targets = discovery.kubernetes.pods.targets
        forward_to = [loki.write.local.receiver]
      }

      // Tempo trace collection
      otelcol.receiver.otlp "default" {
        grpc {}
        http {}
      }

      otelcol.exporter.otlp "tempo" {
        client {
          endpoint = "tempo.observability.svc:4317"
        }
      }
```

### Grafana Dashboards

Pre-configured dashboards:
- Kubernetes cluster overview
- Node exporter (per-node metrics)
- Cilium network flows
- ArgoCD sync status
- Home Assistant metrics
- *arr stack health
- Uptime Kuma integration

---

## 8. Notification System

### Gotify (Recommended over ntfy)

**Why Gotify:**
- Native mobile apps (better than ntfy's)
- WebSocket-based (instant delivery)
- Simpler API
- Lower resource usage

```yaml
# apps/gotify/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gotify
  namespace: automation
spec:
  template:
    spec:
      containers:
        - name: gotify
          image: gotify/server:latest
          ports:
            - containerPort: 80
          env:
            - name: GOTIFY_SERVER_SSL_ENABLED
              value: "false"
            - name: GOTIFY_SERVER_PORT
              value: "80"
          volumeMounts:
            - name: data
              mountPath: /app/data
```

**Integration examples:**
- n8n: Native Gotify node
- Home Assistant: REST notification service
- ArgoCD: Webhook to n8n → Gotify
- Uptime Kuma: Gotify notification channel

---

## 9. Bootstrap Process

```bash
#!/bin/bash
# bootstrap/install.sh

set -e

REPO_URL="https://github.com/arch-err/cluster-config"
KUBECONFIG="${KUBECONFIG:-./talos/clusterconfig/kubeconfig}"

echo "=== Installing ArgoCD ==="
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values bootstrap/argocd/values.yaml \
  --wait

echo "=== Applying root application ==="
kubectl apply -f bootstrap/argocd/templates/root-app.yaml

echo "=== Waiting for sync ==="
kubectl wait --for=condition=Healthy application/root \
  --namespace argocd \
  --timeout=600s

echo "=== Done! ==="
echo "ArgoCD UI: https://argocd.home"
echo "Get password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```

---

## Pros & Cons

### Pros
- **Battle-tested**: Every component is widely used and documented
- **Easy debugging**: Large community, lots of Stack Overflow answers
- **Familiar**: If you've used Kubernetes before, this is standard
- **Stable**: Ingress-NGINX and cert-manager are rock solid
- **ArgoCD UI**: Beautiful visualization of your cluster state

### Cons
- **Multiple ingress controllers**: Running two nginx instances uses more resources
- **Not cutting-edge**: Doesn't leverage Gateway API or Cilium's L7 features
- **Authentik weight**: It's a full identity platform (might be overkill)
- **Manual network policies**: Need to maintain Cilium policies separately

---

## Resource Estimates

| Component | CPU Request | Memory Request |
|-----------|-------------|----------------|
| ArgoCD | 500m | 512Mi |
| Ingress-NGINX (x2) | 200m | 256Mi |
| cert-manager | 100m | 128Mi |
| Authentik | 500m | 1Gi |
| Grafana Stack | 500m | 1Gi |
| Apps (total) | 2000m | 4Gi |
| **Total** | **~4 cores** | **~7Gi** |

With 3 nodes × 16GB RAM each = 48GB total, this leaves plenty of headroom.
