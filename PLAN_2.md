# Plan 2: Cilium-Native Gateway API Stack

## Philosophy
Embrace Cilium's full potential as a unified networking layer. Gateway API replaces Ingress, Cilium handles L7, and FluxCD provides a more Kubernetes-native GitOps experience. This is the "cloud-native" approach that aligns with where the ecosystem is heading.

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
│                         CILIUM GATEWAY API                                   │
│    ┌─────────────────────┐              ┌─────────────────────┐             │
│    │   DMZ Gateway       │              │   Internal Gateway  │             │
│    │   (external class)  │              │   (internal class)  │             │
│    │   L7 WAF Rules      │              │   mTLS, Auth        │             │
│    └─────────────────────┘              └─────────────────────┘             │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                   ┌──────────────────┼──────────────────┐
                   │                  │                  │
                   ▼                  ▼                  ▼
          ┌───────────────┐  ┌───────────────┐  ┌───────────────┐
          │  HTTPRoutes   │  │  HTTPRoutes   │  │  HTTPRoutes   │
          │  (DMZ)        │  │  (Apps)       │  │  (Media)      │
          └───────────────┘  └───────────────┘  └───────────────┘
                   │                  │                  │
                   ▼                  ▼                  ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                          CILIUM SERVICE MESH                                  │
│                    mTLS between all services                                  │
│                    eBPF-based load balancing                                  │
│                    Hubble observability                                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 1. GitOps Structure

### Tool: FluxCD with Kustomize + HelmReleases

FluxCD is more Kubernetes-native than ArgoCD - it uses CRDs rather than a separate UI.

```
cluster-config/
├── flux/
│   ├── flux-system/               # FluxCD bootstrap
│   │   ├── gotk-components.yaml
│   │   ├── gotk-sync.yaml
│   │   └── kustomization.yaml
│   │
│   ├── sources/                   # HelmRepositories, GitRepositories
│   │   ├── helm/
│   │   │   ├── cilium.yaml
│   │   │   ├── grafana.yaml
│   │   │   ├── jetstack.yaml
│   │   │   └── bitnami.yaml
│   │   └── git/
│   │       └── cluster-config.yaml
│   │
│   └── kustomizations/            # What to deploy and when
│       ├── infrastructure.yaml    # Wave 1
│       ├── security.yaml          # Wave 2
│       ├── observability.yaml     # Wave 3
│       └── apps.yaml              # Wave 4
│
├── infrastructure/
│   ├── kustomization.yaml         # Base layer
│   │
│   ├── cilium/
│   │   ├── helmrelease.yaml
│   │   ├── gateway-classes.yaml
│   │   ├── gateways.yaml
│   │   └── l2-announcements.yaml
│   │
│   ├── cert-manager/
│   │   ├── helmrelease.yaml
│   │   └── cluster-issuers/
│   │
│   └── external-secrets/
│       └── helmrelease.yaml
│
├── security/
│   ├── kustomization.yaml
│   │
│   ├── keycloak/                  # SSO (lighter than Authentik)
│   │   ├── helmrelease.yaml
│   │   └── realm-config/
│   │
│   ├── dmz/
│   │   ├── namespace.yaml
│   │   ├── cilium-policies/
│   │   └── gateway-routes.yaml
│   │
│   └── network-policies/
│       ├── default-deny.yaml
│       └── baseline/
│
├── observability/
│   ├── kustomization.yaml
│   │
│   ├── grafana-operator/
│   │   └── helmrelease.yaml
│   │
│   ├── grafana-stack/
│   │   ├── grafana.yaml           # GrafanaDashboard CRs
│   │   ├── loki.yaml
│   │   ├── tempo.yaml
│   │   └── mimir.yaml
│   │
│   └── hubble/                    # Cilium observability
│       └── ui-config.yaml
│
├── apps/
│   ├── kustomization.yaml
│   ├── _apps.yaml                 # ← Your single source of truth!
│   │
│   ├── base/                      # Reusable templates
│   │   ├── web-app/
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── httproute.yaml
│   │   └── stateful-app/
│   │       ├── statefulset.yaml
│   │       ├── service.yaml
│   │       └── httproute.yaml
│   │
│   └── overlays/
│       ├── nextcloud/
│       ├── vaultwarden/
│       ├── audiobookshelf/
│       ├── home-assistant/
│       ├── arr-stack/
│       ├── homepage/
│       ├── gatus/                 # Uptime (better than Uptime Kuma)
│       ├── n8n/
│       ├── apprise/               # Notifications (better than ntfy/Gotify)
│       └── seafile/               # Network storage (simpler than Nextcloud for just files)
│
└── dmz/
    ├── kustomization.yaml
    └── overlays/
        ├── send/
        └── vaultwarden/
```

### The Apps Definition (_apps.yaml)

```yaml
# apps/_apps.yaml
# Single source of truth - FluxCD Kustomization generates from this
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-definitions
  namespace: flux-system
data:
  apps: |
    # ══════════════════════════════════════════════════════════════════
    # FORMAT:
    # - name: app-name
    #   namespace: target-namespace
    #   type: helm | kustomize | raw
    #   source: { repo: ..., chart: ..., version: ... }
    #   gateway: internal | external | none
    #   hostname: app.home (auto-generates HTTPRoute)
    #   sso: true | false (injects Keycloak auth)
    #   storage: { class: ..., size: ... }
    #   depends: [list of app names]
    # ══════════════════════════════════════════════════════════════════

    # ─────────────────────────────────────────────────────────────────
    # INFRASTRUCTURE (managed separately, listed for reference)
    # ─────────────────────────────────────────────────────────────────

    # ─────────────────────────────────────────────────────────────────
    # CORE APPS
    # ─────────────────────────────────────────────────────────────────
    - name: nextcloud
      namespace: apps
      type: helm
      source:
        repo: https://nextcloud.github.io/helm
        chart: nextcloud
        version: "5.x"
      gateway: internal
      hostname: cloud.home
      sso: true
      storage:
        data:
          class: kadalu.replica2
          size: 500Gi
      values:
        nextcloud:
          host: cloud.home
        internalDatabase:
          enabled: false
        postgresql:
          enabled: true
        redis:
          enabled: true

    - name: homepage
      namespace: apps
      type: helm
      source:
        repo: https://jameswynn.github.io/helm-charts
        chart: homepage
        version: "2.x"
      gateway: internal
      hostname: home.home  # or dashboard.home
      sso: false           # Homepage handles auth differently
      config:
        # Auto-discover services with annotations
        kubernetes:
          mode: cluster
        customCSS: |
          /* Dark theme tweaks */

    - name: seafile
      namespace: apps
      type: kustomize
      path: apps/overlays/seafile
      gateway: internal
      hostname: files.home
      sso: true
      storage:
        data:
          class: kadalu.replica2
          size: 500Gi
      notes: |
        Seafile instead of FileBrowser - native sync clients,
        better mobile apps, built-in sharing and versioning.
        Can mount via SeaDrive on desktop.

    # ─────────────────────────────────────────────────────────────────
    # MEDIA
    # ─────────────────────────────────────────────────────────────────
    - name: audiobookshelf
      namespace: media
      type: kustomize
      path: apps/overlays/audiobookshelf
      gateway: internal
      hostname: audiobooks.home
      sso: true
      storage:
        data:
          class: kadalu.replica2
          size: 200Gi
        config:
          class: kadalu.replica2
          size: 1Gi

    - name: arr-stack
      namespace: media
      type: kustomize
      path: apps/overlays/arr-stack
      gateway: internal
      components:
        - name: sonarr
          hostname: sonarr.home
          sso: true
        - name: radarr
          hostname: radarr.home
          sso: true
        - name: prowlarr
          hostname: prowlarr.home
          sso: true
        - name: qbittorrent
          hostname: qbit.home
          sso: false  # Built-in auth
        - name: gluetun
          vpn: true   # WireGuard tunnel for qBittorrent
      storage:
        downloads:
          class: kadalu.replica2
          size: 1Ti
          accessMode: ReadWriteMany

    # ─────────────────────────────────────────────────────────────────
    # AUTOMATION
    # ─────────────────────────────────────────────────────────────────
    - name: home-assistant
      namespace: automation
      type: kustomize
      path: apps/overlays/home-assistant
      gateway: internal
      hostname: hass.home
      sso: false           # HA has its own auth
      hostNetwork: true    # For mDNS discovery
      nodeAffinity:
        zigbee: true       # Schedule on node with USB dongle
      components:
        - zigbee2mqtt
        - mosquitto
      storage:
        config:
          class: kadalu.replica2
          size: 10Gi

    - name: n8n
      namespace: automation
      type: helm
      source:
        repo: https://community.n8n.io/helm-charts
        chart: n8n
        version: "0.x"
      gateway: internal
      hostname: n8n.home
      sso: true
      storage:
        data:
          class: kadalu.replica2
          size: 10Gi

    - name: apprise
      namespace: automation
      type: kustomize
      path: apps/overlays/apprise
      gateway: internal
      hostname: notify.home
      sso: false  # API-based
      notes: |
        Apprise instead of ntfy/Gotify - unified notification gateway.
        Supports 80+ services: Pushover, Discord, Telegram, Email,
        Slack, Matrix, SMS, and more. Single API, any destination.

    # ─────────────────────────────────────────────────────────────────
    # MONITORING
    # ─────────────────────────────────────────────────────────────────
    - name: gatus
      namespace: monitoring
      type: helm
      source:
        repo: https://miniclip.github.io/gatus-chart
        chart: gatus
        version: "3.x"
      gateway: internal
      hostname: status.home
      sso: false  # Public status page
      notes: |
        Gatus instead of Uptime Kuma:
        - Config-as-code (GitOps friendly!)
        - Kubernetes-native service discovery
        - Better alerting integrations
        - Lower resource usage
        - Conditions are more powerful

    # ─────────────────────────────────────────────────────────────────
    # DMZ (Internet-Facing)
    # ─────────────────────────────────────────────────────────────────
    - name: send
      namespace: dmz
      type: kustomize
      path: dmz/overlays/send
      gateway: external
      hostname: send.yourdomain.com
      dmz: true
      notes: |
        Mozilla Send fork - encrypted file sharing.
        Self-destruct after download, password protection.

    - name: vaultwarden
      namespace: dmz
      type: helm
      source:
        repo: https://charts.gabe565.com
        chart: vaultwarden
        version: "1.x"
      gateway: external
      hostname: vault.yourdomain.com
      dmz: true
      storage:
        data:
          class: kadalu.replica2
          size: 1Gi
```

### FluxCD Kustomization Generator

```yaml
# flux/kustomizations/apps.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: cluster-config
  path: ./apps
  prune: true
  dependsOn:
    - name: infrastructure
    - name: security
    - name: observability
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: app-definitions
```

---

## 2. Gateway API with Cilium

### Why Gateway API over Ingress?
- **Role-based**: Infrastructure team manages Gateways, app teams manage Routes
- **Expressive**: More features than Ingress (header manipulation, traffic splitting)
- **Future**: Ingress is "done", Gateway API is actively developed
- **Cilium-native**: Deep integration with eBPF networking

### Gateway Classes

```yaml
# infrastructure/cilium/gateway-classes.yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium-internal
spec:
  controllerName: io.cilium/gateway-controller
  parametersRef:
    group: cilium.io
    kind: CiliumGatewayConfiguration
    name: internal-config
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium-external
spec:
  controllerName: io.cilium/gateway-controller
  parametersRef:
    group: cilium.io
    kind: CiliumGatewayConfiguration
    name: external-config
---
# Internal gateway config - relaxed
apiVersion: cilium.io/v2alpha1
kind: CiliumGatewayConfiguration
metadata:
  name: internal-config
spec:
  xffNumTrustedHops: 0

---
# External gateway config - hardened
apiVersion: cilium.io/v2alpha1
kind: CiliumGatewayConfiguration
metadata:
  name: external-config
spec:
  xffNumTrustedHops: 1  # Trust one hop (Cloudflare)
```

### Gateways

```yaml
# infrastructure/cilium/gateways.yaml
---
# Internal Gateway - all *.home traffic
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: internal
  namespace: gateway-system
  annotations:
    cert-manager.io/cluster-issuer: home-ca-issuer
spec:
  gatewayClassName: cilium-internal
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

    - name: https-apps
      port: 443
      protocol: HTTPS
      hostname: "*.apps.home"
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-home-tls
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: apps

---
# External Gateway - DMZ traffic only
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external
  namespace: gateway-system
spec:
  gatewayClassName: cilium-external
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
          - name: external-tls  # From Let's Encrypt or Cloudflare
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: dmz  # Only DMZ namespace
```

### HTTPRoutes (Auto-Generated from _apps.yaml)

```yaml
# Example generated HTTPRoute for Nextcloud
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nextcloud
  namespace: apps
spec:
  parentRefs:
    - name: internal
      namespace: gateway-system
  hostnames:
    - cloud.home
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: nextcloud
          port: 80
      filters:
        # Keycloak auth filter (when sso: true)
        - type: ExtensionRef
          extensionRef:
            group: cilium.io
            kind: CiliumEnvoyFilter
            name: keycloak-auth
```

### L7 Policies with Cilium

```yaml
# security/network-policies/l7-example.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: nextcloud-api-policy
  namespace: apps
spec:
  endpointSelector:
    matchLabels:
      app: nextcloud
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: n8n
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/ocs/v2.php/.*"  # Only OCS API
              - method: "POST"
                path: "/ocs/v2.php/.*"
```

---

## 3. Cilium Full Configuration

```yaml
# infrastructure/cilium/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cilium
  namespace: kube-system
spec:
  interval: 1h
  chart:
    spec:
      chart: cilium
      version: "1.16.x"
      sourceRef:
        kind: HelmRepository
        name: cilium
        namespace: flux-system
  values:
    cluster:
      name: home-cluster
      id: 1

    # Replace kube-proxy entirely
    kubeProxyReplacement: true

    # Gateway API
    gatewayAPI:
      enabled: true
      secretsNamespace:
        create: true
        name: cilium-secrets

    # eBPF-based load balancing
    loadBalancer:
      mode: dsr
      algorithm: maglev

    # L2 announcements for LoadBalancer IPs
    l2announcements:
      enabled: true

    l2AnnouncementPolicies:
      - name: default
        interfaces:
          - ^eth[0-9]+
        loadBalancerIPs: true

    # Hubble observability
    hubble:
      enabled: true
      relay:
        enabled: true
      ui:
        enabled: true
        ingress:
          enabled: false  # We'll use Gateway API
      metrics:
        enabled:
          - dns
          - drop
          - tcp
          - flow
          - port-distribution
          - icmp
          - httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload

    # Service mesh features
    authentication:
      mutual:
        spire:
          enabled: false  # Can enable for mTLS

    # Enable L7 proxy for HTTP policies
    envoy:
      enabled: true

    # IP masquerading
    bpf:
      masquerade: true
      hostLegacyRouting: false

    # IPAM
    ipam:
      mode: kubernetes

    # Operator
    operator:
      replicas: 1
```

### L2 Announcements for LoadBalancer IPs

```yaml
# infrastructure/cilium/l2-announcements.yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default
spec:
  interfaces:
    - ^eth[0-9]+
  loadBalancerIPs: true
  externalIPs: true
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  blocks:
    - start: 192.168.1.200
      stop: 192.168.1.220
```

---

## 4. SSO with Keycloak

### Why Keycloak over Authentik?
- **Industry standard**: Used in enterprise, massive documentation
- **Lighter**: Less resource usage than Authentik
- **Realm export**: Full GitOps config-as-code
- **Broader protocol support**: OIDC, SAML, LDAP, Kerberos
- **Better for Gateway API**: Native integration with Envoy

```yaml
# security/keycloak/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: keycloak
  namespace: keycloak
spec:
  interval: 1h
  chart:
    spec:
      chart: keycloak
      version: "22.x"
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: flux-system
  values:
    auth:
      adminUser: admin
      existingSecret: keycloak-admin-secret

    production: true
    proxy: edge  # Behind Gateway

    postgresql:
      enabled: true
      auth:
        existingSecret: keycloak-db-secret

    extraEnvVars:
      - name: KC_FEATURES
        value: "token-exchange,admin-fine-grained-authz"
```

### Keycloak Realm Configuration (GitOps)

```yaml
# security/keycloak/realm-config/home-realm.yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: KeycloakRealmImport
metadata:
  name: home-realm
  namespace: keycloak
spec:
  keycloakCRName: keycloak
  realm:
    realm: home
    enabled: true
    displayName: Home Lab

    # SSO session settings
    ssoSessionIdleTimeout: 86400     # 24 hours
    ssoSessionMaxLifespan: 604800    # 7 days

    # Clients (applications)
    clients:
      - clientId: nextcloud
        name: Nextcloud
        enabled: true
        protocol: openid-connect
        publicClient: false
        standardFlowEnabled: true
        directAccessGrantsEnabled: false
        rootUrl: https://cloud.home
        redirectUris:
          - https://cloud.home/*
        webOrigins:
          - https://cloud.home

      - clientId: n8n
        name: n8n Automation
        enabled: true
        protocol: openid-connect
        publicClient: false
        standardFlowEnabled: true
        rootUrl: https://n8n.home
        redirectUris:
          - https://n8n.home/*

      - clientId: audiobookshelf
        name: Audiobookshelf
        enabled: true
        protocol: openid-connect
        standardFlowEnabled: true
        rootUrl: https://audiobooks.home
        redirectUris:
          - https://audiobooks.home/*

      - clientId: grafana
        name: Grafana
        enabled: true
        protocol: openid-connect
        standardFlowEnabled: true
        rootUrl: https://grafana.home
        redirectUris:
          - https://grafana.home/*

    # Default groups
    groups:
      - name: admins
        attributes:
          app_access: ["*"]
      - name: users
        attributes:
          app_access: ["nextcloud", "audiobookshelf", "seafile"]
      - name: media
        attributes:
          app_access: ["sonarr", "radarr", "qbittorrent"]

    # Authentication flows
    authenticationFlows:
      - alias: browser-with-2fa
        topLevel: true
        builtIn: false
        authenticationExecutions:
          - authenticator: auth-cookie
            requirement: ALTERNATIVE
          - authenticator: auth-username-password-form
            requirement: REQUIRED
          - authenticator: auth-otp-form
            requirement: CONDITIONAL
```

### Gateway API Auth Filter

```yaml
# security/keycloak/gateway-auth-filter.yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumEnvoyConfig
metadata:
  name: keycloak-auth
  namespace: gateway-system
spec:
  services:
    - name: "*"  # Apply to all services in routes that reference this
      namespace: "*"
  resources:
    - "@type": type.googleapis.com/envoy.extensions.filters.http.oauth2.v3.OAuth2
      config:
        token_endpoint:
          cluster: keycloak
          uri: https://auth.home/realms/home/protocol/openid-connect/token
        authorization_endpoint: https://auth.home/realms/home/protocol/openid-connect/auth
        credentials:
          client_id: gateway-proxy
          token_secret:
            name: keycloak-gateway-secret
        redirect_uri: "%REQ(x-forwarded-proto)%://%REQ(:authority)%/oauth2/callback"
        signout_path:
          path:
            exact: /oauth2/sign_out
```

---

## 5. DMZ Architecture

### Namespace with Gateway Access

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

### Cilium Network Policies

```yaml
# dmz/cilium-policies/default.yaml
---
# Deny all by default
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-all
  namespace: dmz
spec:
  endpointSelector: {}
  ingressDeny:
    - {}
  egressDeny:
    - {}
---
# Allow from Gateway only
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-gateway-ingress
  namespace: dmz
spec:
  endpointSelector: {}
  ingress:
    - fromEntities:
        - cluster
      fromEndpoints:
        - matchLabels:
            io.cilium.k8s.policy.serviceaccount: cilium-gateway
---
# Allow DNS egress only
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns-egress
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
# Vaultwarden push notifications
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: vaultwarden-push
  namespace: dmz
spec:
  endpointSelector:
    matchLabels:
      app: vaultwarden
  egress:
    - toFQDNs:
        - matchName: push.bitwarden.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
---
# Send - no egress needed (stores locally)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: send-isolated
  namespace: dmz
spec:
  endpointSelector:
    matchLabels:
      app: send
  egress: []  # Completely isolated
```

---

## 6. Certificate Management

### Self-Signed CA with Trust Distribution

```yaml
# infrastructure/cert-manager/cluster-issuers/home-ca.yaml
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
  subject:
    organizations:
      - Home Lab
  secretName: home-root-ca
  duration: 87600h  # 10 years
  renewBefore: 8760h
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
  name: home-ca-issuer
spec:
  ca:
    secretName: home-root-ca
```

### Trust-Manager for Distribution

```yaml
# infrastructure/cert-manager/trust-manager/bundle.yaml
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: home-ca-bundle
spec:
  sources:
    - secret:
        name: home-root-ca
        key: ca.crt
  target:
    configMap:
      key: ca-certificates.crt
    namespaceSelector:
      matchLabels:
        trust-injection: enabled
```

---

## 7. Observability with Grafana Stack

### Grafana Operator Approach

```yaml
# observability/grafana-operator/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: grafana-operator
  namespace: observability
spec:
  interval: 1h
  chart:
    spec:
      chart: grafana-operator
      version: "5.x"
      sourceRef:
        kind: HelmRepository
        name: grafana
        namespace: flux-system
```

### Grafana Instance

```yaml
# observability/grafana-stack/grafana.yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: observability
spec:
  config:
    server:
      root_url: https://grafana.home
    auth.generic_oauth:
      enabled: "true"
      name: Keycloak
      client_id: grafana
      client_secret: ${GRAFANA_OAUTH_SECRET}
      scopes: openid profile email
      auth_url: https://auth.home/realms/home/protocol/openid-connect/auth
      token_url: https://auth.home/realms/home/protocol/openid-connect/token
      api_url: https://auth.home/realms/home/protocol/openid-connect/userinfo
      role_attribute_path: contains(groups[*], 'admins') && 'Admin' || 'Viewer'
```

### Hubble Integration

```yaml
# observability/grafana-stack/hubble-dashboard.yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: hubble-network-flows
  namespace: observability
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  json: |
    {
      "title": "Hubble Network Flows",
      "panels": [
        {
          "title": "Traffic by Namespace",
          "type": "piechart",
          "targets": [
            {
              "expr": "sum by (destination_namespace) (rate(hubble_flows_processed_total[5m]))"
            }
          ]
        },
        {
          "title": "Dropped Packets",
          "type": "timeseries",
          "targets": [
            {
              "expr": "rate(hubble_drop_total[5m])"
            }
          ]
        }
      ]
    }
```

---

## 8. Application Highlights

### Apprise - Unified Notifications

**Why Apprise instead of ntfy/Gotify:**
- Single API endpoint, routes to 80+ services
- Discord, Telegram, Pushover, Email, SMS, Matrix, Slack, etc.
- No app needed - uses existing apps
- Config as code

```yaml
# apps/overlays/apprise/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: apprise-config
  namespace: automation
data:
  apprise.yml: |
    version: 1
    urls:
      # Primary: Pushover (best iOS experience)
      - pover://${PUSHOVER_USER_KEY}@${PUSHOVER_API_TOKEN}:
          - tag: urgent
          - tag: default

      # Backup: Discord webhook
      - discord://${DISCORD_WEBHOOK_ID}/${DISCORD_WEBHOOK_TOKEN}/:
          - tag: default
          - tag: alerts

      # Email for important stuff
      - mailto://${SMTP_USER}:${SMTP_PASS}@${SMTP_HOST}?to=you@email.com:
          - tag: critical

      # Telegram for quick updates
      - tgram://${TELEGRAM_BOT_TOKEN}/${TELEGRAM_CHAT_ID}/:
          - tag: quick
```

### Gatus - GitOps-Native Uptime

**Why Gatus instead of Uptime Kuma:**
- Config-as-code (perfect for GitOps)
- Kubernetes service discovery
- More powerful conditions
- Lower resource usage

```yaml
# apps/overlays/gatus/config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gatus-config
  namespace: monitoring
data:
  config.yaml: |
    storage:
      type: sqlite
      path: /data/gatus.db

    endpoints:
      # Kubernetes service discovery
      - name: Nextcloud
        group: Apps
        url: https://cloud.home
        interval: 60s
        conditions:
          - "[STATUS] == 200"
          - "[RESPONSE_TIME] < 2000"
        alerts:
          - type: custom
            endpoint-url: http://apprise.automation.svc:8000/notify/urgent
            send-on-resolved: true

      - name: Vaultwarden
        group: DMZ
        url: https://vault.yourdomain.com
        interval: 30s
        conditions:
          - "[STATUS] == 200"
          - "[CERTIFICATE_EXPIRATION] > 72h"
        alerts:
          - type: custom
            endpoint-url: http://apprise.automation.svc:8000/notify/critical

      - name: Home Assistant
        group: Automation
        url: https://hass.home
        interval: 30s
        conditions:
          - "[STATUS] == 200"

      # Kubernetes-native checks
      - name: Kadalu Storage
        group: Infrastructure
        url: tcp://server-replica2-0-0.kadalu.svc:24007
        interval: 60s
        conditions:
          - "[CONNECTED] == true"

    kubernetes:
      auto-discover: true
      cluster-mode: current
      excluded-service-suffixes:
        - -headless
```

### Seafile - Better Network Storage

**Why Seafile instead of just FileBrowser:**
- Native sync clients (like Dropbox)
- SeaDrive for virtual drive mount
- Better mobile apps
- File versioning
- Sharing with expiration

```yaml
# apps/overlays/seafile/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: seafile
  namespace: apps
spec:
  template:
    spec:
      containers:
        - name: seafile
          image: seafileltd/seafile-mc:11
          env:
            - name: DB_HOST
              value: mariadb
            - name: SEAFILE_SERVER_HOSTNAME
              value: files.home
            - name: SEAFILE_ADMIN_EMAIL
              valueFrom:
                secretKeyRef:
                  name: seafile-admin
                  key: email
            - name: SEAFILE_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: seafile-admin
                  key: password
          volumeMounts:
            - name: data
              mountPath: /shared/seafile
          ports:
            - containerPort: 80

        - name: mariadb
          image: mariadb:10.11
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: seafile-db
                  key: root-password
          volumeMounts:
            - name: db
              mountPath: /var/lib/mysql

        - name: memcached
          image: memcached:1.6
```

---

## 9. Bootstrap Process

```bash
#!/bin/bash
# flux/bootstrap.sh

set -e

GITHUB_REPO="arch-err/cluster-config"
KUBECONFIG="${KUBECONFIG:-./talos/clusterconfig/kubeconfig}"

# Check prerequisites
command -v flux >/dev/null || { echo "Install flux CLI first"; exit 1; }
command -v kubectl >/dev/null || { echo "Install kubectl first"; exit 1; }

# Bootstrap FluxCD
flux bootstrap github \
  --owner=arch-err \
  --repository=cluster-config \
  --branch=main \
  --path=./flux \
  --personal

echo "=== FluxCD bootstrapped ==="
echo ""
echo "Watch progress with:"
echo "  flux get kustomizations --watch"
echo ""
echo "View Grafana: https://grafana.home"
echo "View Hubble: https://hubble.home"
```

---

## Pros & Cons

### Pros
- **Future-proof**: Gateway API is the future of Kubernetes ingress
- **Unified networking**: Cilium handles L3, L4, L7, and observability
- **True GitOps**: FluxCD is more Kubernetes-native than ArgoCD
- **Powerful policies**: Cilium L7 policies are very expressive
- **eBPF performance**: Faster than iptables-based solutions
- **Single pane**: Hubble gives deep network visibility

### Cons
- **Learning curve**: Gateway API is newer, less documentation
- **No UI**: FluxCD has no built-in UI (use Weave GitOps or Capacitor)
- **Cilium complexity**: More moving parts than simple ingress
- **Keycloak weight**: Still a significant footprint
- **Gateway API maturity**: Some features still in beta

---

## Resource Estimates

| Component | CPU Request | Memory Request |
|-----------|-------------|----------------|
| FluxCD | 200m | 256Mi |
| Cilium (w/ Hubble) | 500m | 512Mi |
| cert-manager | 100m | 128Mi |
| Keycloak | 500m | 768Mi |
| Grafana Stack | 500m | 1Gi |
| Apps (total) | 2000m | 4Gi |
| **Total** | **~4 cores** | **~7Gi** |

Similar footprint to Plan 1, but more unified architecture.
