# Plan 3: Zero-Trust Security-First Architecture

## Philosophy
Security is not a feature, it's the foundation. This plan implements defense-in-depth with mutual TLS everywhere, workload identity, secrets management with HashiCorp Vault, and strict least-privilege policies. Every connection is authenticated, every secret is managed, every action is audited.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              EXTERNAL TRAFFIC                                │
│                    Cloudflare Tunnel (Zero Trust Access)                     │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         ENVOY GATEWAY                                        │
│                   Gateway API + OAuth2 Filter                                │
│                   WAF Rules + Rate Limiting                                  │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
┌─────────────────────────────────────────────────────────────────────────────┐
│                      CILIUM SERVICE MESH + mTLS                              │
│    ┌─────────────────────────────────────────────────────────────────┐      │
│    │                    SPIFFE/SPIRE                                  │      │
│    │              Workload Identity for all pods                      │      │
│    │         Every service has a cryptographic identity               │      │
│    └─────────────────────────────────────────────────────────────────┘      │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
        ▼                             ▼                             ▼
┌───────────────┐           ┌───────────────┐           ┌───────────────┐
│    VAULT      │           │   AUTHELIA    │           │   POLICIES    │
│               │           │               │           │               │
│ Secret Store  │           │  Lightweight  │           │ OPA Gatekeeper│
│ Dynamic Creds │           │     SSO       │           │ Kyverno       │
│ PKI Engine    │           │  2FA/WebAuthn │           │ Falco Runtime │
└───────────────┘           └───────────────┘           └───────────────┘
        │                             │                             │
        └─────────────────────────────┼─────────────────────────────┘
                                      │
┌─────────────────────────────────────────────────────────────────────────────┐
│                           NAMESPACE ISOLATION                                │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐          │
│  │ vault   │  │  dmz    │  │  apps   │  │  media  │  │ automate│          │
│  │         │  │         │  │         │  │         │  │         │          │
│  │ Strict  │  │ Isolated│  │ Standard│  │ Media   │  │ Internal│          │
│  │ No Egr. │  │ Limited │  │ Policies│  │ Specific│  │ Only    │          │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 1. GitOps Structure

### Tool: ArgoCD with ApplicationSets + Kyverno Policies

```
cluster-config/
├── bootstrap/
│   ├── argocd/
│   │   ├── values.yaml            # Hardened ArgoCD config
│   │   └── rbac.yaml              # Strict RBAC
│   ├── vault/
│   │   └── init-job.yaml          # Vault auto-unseal
│   └── install.sh
│
├── policies/                       # Cluster-wide policies
│   ├── kustomization.yaml
│   │
│   ├── kyverno/
│   │   ├── helmrelease.yaml
│   │   └── cluster-policies/
│   │       ├── require-labels.yaml
│   │       ├── require-probes.yaml
│   │       ├── require-resource-limits.yaml
│   │       ├── disallow-privileged.yaml
│   │       ├── disallow-host-namespaces.yaml
│   │       ├── restrict-image-registries.yaml
│   │       └── require-ro-rootfs.yaml
│   │
│   ├── opa-gatekeeper/            # Alternative to Kyverno
│   │   └── constraints/
│   │
│   └── falco/                     # Runtime security
│       ├── helmrelease.yaml
│       └── rules/
│           ├── home-lab-rules.yaml
│           └── crypto-mining-detect.yaml
│
├── security/
│   ├── kustomization.yaml
│   │
│   ├── vault/
│   │   ├── helmrelease.yaml
│   │   ├── vault-config/
│   │   │   ├── auth-kubernetes.tf
│   │   │   ├── pki-engine.tf
│   │   │   └── secrets-engines.tf
│   │   └── external-secrets/
│   │       └── cluster-secret-store.yaml
│   │
│   ├── spire/
│   │   ├── server/
│   │   └── agent/
│   │
│   ├── authelia/
│   │   ├── helmrelease.yaml
│   │   └── config/
│   │
│   └── crowdsec/
│       ├── helmrelease.yaml
│       └── collections/
│
├── infrastructure/
│   ├── cilium/
│   │   ├── helmrelease.yaml
│   │   └── mesh-config/
│   │       └── mtls-policy.yaml
│   │
│   ├── envoy-gateway/
│   │   ├── helmrelease.yaml
│   │   ├── gateways/
│   │   └── security-policies/
│   │
│   └── cert-manager/
│       ├── helmrelease.yaml
│       └── vault-issuer.yaml      # Vault PKI integration
│
├── observability/
│   ├── grafana-stack/
│   │   ├── loki/
│   │   ├── tempo/
│   │   ├── mimir/
│   │   └── grafana/
│   │
│   └── security-dashboards/
│       ├── falco-dashboard.yaml
│       ├── vault-audit.yaml
│       └── network-policies.yaml
│
├── apps/
│   ├── _manifest.yaml             # Single source of truth
│   └── overlays/
│       └── ...
│
└── dmz/
    ├── namespace.yaml
    ├── network-policies/
    ├── security-context/
    └── apps/
```

### The Manifest (_manifest.yaml)

```yaml
# apps/_manifest.yaml
# Security-focused application definitions
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-manifest
  namespace: argocd
data:
  applications: |
    # ══════════════════════════════════════════════════════════════════
    # SECURITY CONFIGURATION OPTIONS:
    #
    # vault:
    #   secrets: true              # Inject secrets from Vault
    #   dynamicCreds: true         # Use dynamic database credentials
    #   pki: true                  # Get certificates from Vault PKI
    #
    # mesh:
    #   mtls: strict | permissive | disable
    #   spiffe: true               # SPIFFE identity
    #
    # network:
    #   tier: dmz | internal | restricted
    #   egressPolicy: deny-all | allow-list | allow-all
    #   allowedEgress: [list of FQDNs or CIDRs]
    #
    # runtime:
    #   readOnlyRootFilesystem: true
    #   runAsNonRoot: true
    #   dropCapabilities: all
    #   seccompProfile: RuntimeDefault
    # ══════════════════════════════════════════════════════════════════

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
      gateway:
        class: internal
        hostname: cloud.home
        authentication:
          provider: authelia
          policy: two_factor
      vault:
        secrets: true
        dynamicCreds: true        # Postgres creds from Vault
      mesh:
        mtls: strict
        spiffe: true
      network:
        tier: internal
        egressPolicy: allow-list
        allowedEgress:
          - "*.home"              # Internal services
          - "cdn.nextcloud.com"   # Updates
      runtime:
        readOnlyRootFilesystem: false  # Nextcloud needs write
        runAsNonRoot: true
      storage:
        class: kadalu.replica2
        size: 500Gi
        encrypted: true           # Encrypted PV via Vault

    - name: homepage
      namespace: apps
      type: helm
      source:
        repo: https://jameswynn.github.io/helm-charts
        chart: homepage
        version: "2.x"
      gateway:
        class: internal
        hostname: home.home
        authentication:
          provider: authelia
          policy: one_factor
      vault:
        secrets: true
      mesh:
        mtls: strict
      network:
        tier: internal
        egressPolicy: allow-list
        allowedEgress:
          - "kubernetes.default.svc"  # Service discovery only
      runtime:
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        dropCapabilities: all

    - name: actual-budget
      namespace: apps
      type: kustomize
      path: apps/overlays/actual-budget
      gateway:
        class: internal
        hostname: budget.home
        authentication:
          provider: authelia
          policy: two_factor      # Financial data = 2FA required
      vault:
        secrets: true
      mesh:
        mtls: strict
      network:
        tier: restricted          # Most isolated
        egressPolicy: deny-all    # No external access ever
      runtime:
        readOnlyRootFilesystem: true
        runAsNonRoot: true
      storage:
        class: kadalu.replica2
        size: 5Gi
        encrypted: true
      notes: |
        Actual Budget instead of generic password manager access.
        Financial data gets highest security tier.

    # ─────────────────────────────────────────────────────────────────
    # MEDIA (Less strict, still secured)
    # ─────────────────────────────────────────────────────────────────
    - name: audiobookshelf
      namespace: media
      type: kustomize
      path: apps/overlays/audiobookshelf
      gateway:
        class: internal
        hostname: audiobooks.home
        authentication:
          provider: authelia
          policy: one_factor
      vault:
        secrets: true
      mesh:
        mtls: permissive          # Some clients don't support mTLS
      network:
        tier: internal
        egressPolicy: allow-list
        allowedEgress:
          - "*.audible.com"       # Metadata fetching
          - "*.goodreads.com"
      storage:
        class: kadalu.replica2
        size: 200Gi

    - name: arr-stack
      namespace: media
      type: kustomize
      path: apps/overlays/arr-stack
      components:
        - sonarr
        - radarr
        - prowlarr
        - qbittorrent
        - gluetun
        - recyclarr
      gateway:
        class: internal
        hostnames:
          sonarr: sonarr.home
          radarr: radarr.home
          prowlarr: prowlarr.home
          qbittorrent: qbit.home
        authentication:
          provider: authelia
          policy: one_factor
          bypassPaths:
            - "/api/*"            # API access with tokens
      vault:
        secrets: true
        paths:
          vpn-credentials: secret/media/vpn
          api-keys: secret/media/arr-keys
      mesh:
        mtls: permissive
      network:
        tier: internal
        # qBittorrent isolated network via Gluetun
        isolatedComponents:
          - qbittorrent
      storage:
        class: kadalu.replica2
        size: 1Ti

    # ─────────────────────────────────────────────────────────────────
    # AUTOMATION
    # ─────────────────────────────────────────────────────────────────
    - name: home-assistant
      namespace: automation
      type: kustomize
      path: apps/overlays/home-assistant
      gateway:
        class: internal
        hostname: hass.home
        authentication:
          provider: none          # HA has built-in auth
      vault:
        secrets: true
        paths:
          integrations: secret/automation/hass
      mesh:
        mtls: permissive          # IoT devices don't support mTLS
      network:
        tier: internal
        egressPolicy: allow-list
        allowedEgress:
          - "*.home-assistant.io"
          - "*.nabucasa.com"      # Cloud backup (optional)
          - "192.168.1.0/24"      # Local network for IoT
      hostNetwork: true
      nodeAffinity:
        zigbee: true
      components:
        - zigbee2mqtt
        - mosquitto

    - name: n8n
      namespace: automation
      type: helm
      source:
        repo: https://community.n8n.io/helm-charts
        chart: n8n
        version: "0.x"
      gateway:
        class: internal
        hostname: n8n.home
        authentication:
          provider: authelia
          policy: two_factor      # Automation = sensitive
      vault:
        secrets: true
        dynamicCreds: true
      mesh:
        mtls: strict
      network:
        tier: internal
        egressPolicy: allow-list
        allowedEgress:
          - "*.home"
          - "api.telegram.org"
          - "api.pushover.net"
          - "hooks.slack.com"
      storage:
        class: kadalu.replica2
        size: 10Gi

    - name: ntfy
      namespace: automation
      type: kustomize
      path: apps/overlays/ntfy
      gateway:
        class: internal
        hostname: ntfy.home
        authentication:
          provider: none          # ntfy has built-in auth
      vault:
        secrets: true
      mesh:
        mtls: permissive
      network:
        tier: internal
        egressPolicy: allow-list
        allowedEgress:
          - "fcm.googleapis.com"  # Firebase push
          - "mtalk.google.com"
      notes: |
        Keeping ntfy in this plan because it supports UnifiedPush.
        UnifiedPush = no Google/Apple push dependency.
        Better for privacy-focused setup.

    # ─────────────────────────────────────────────────────────────────
    # MONITORING
    # ─────────────────────────────────────────────────────────────────
    - name: uptime-kuma
      namespace: monitoring
      type: kustomize
      path: apps/overlays/uptime-kuma
      gateway:
        class: internal
        hostname: status.home
        authentication:
          provider: authelia
          policy: one_factor
      vault:
        secrets: true
      mesh:
        mtls: strict
      network:
        tier: internal
        egressPolicy: allow-list
        allowedEgress:
          - "*.home"
          - "*.yourdomain.com"    # External monitoring
      storage:
        class: kadalu.replica2
        size: 5Gi
      notes: |
        Keeping Uptime Kuma here because the UI is excellent
        for non-technical family members to see status.

    # ─────────────────────────────────────────────────────────────────
    # DMZ (Maximum Isolation)
    # ─────────────────────────────────────────────────────────────────
    - name: send
      namespace: dmz
      type: kustomize
      path: dmz/apps/send
      gateway:
        class: external
        hostname: send.yourdomain.com
        rateLimiting:
          requestsPerMinute: 30
        waf:
          enabled: true
          ruleset: owasp-crs
      vault:
        secrets: true
      mesh:
        mtls: strict
      network:
        tier: dmz
        egressPolicy: deny-all
      runtime:
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        dropCapabilities: all
        seccompProfile: RuntimeDefault
      storage:
        class: kadalu.replica2
        size: 50Gi
        encrypted: true

    - name: vaultwarden
      namespace: dmz
      type: helm
      source:
        repo: https://charts.gabe565.com
        chart: vaultwarden
        version: "1.x"
      gateway:
        class: external
        hostname: vault.yourdomain.com
        rateLimiting:
          requestsPerMinute: 60
          burstSize: 20
        waf:
          enabled: true
        authentication:
          provider: none          # Bitwarden handles auth
      vault:
        secrets: true
        paths:
          admin-token: secret/dmz/vaultwarden
      mesh:
        mtls: strict
      network:
        tier: dmz
        egressPolicy: allow-list
        allowedEgress:
          - "push.bitwarden.com"
          - "api.pwnedpasswords.com"  # HIBP checks
      runtime:
        readOnlyRootFilesystem: false
        runAsNonRoot: true
      storage:
        class: kadalu.replica2
        size: 2Gi
        encrypted: true

    # ─────────────────────────────────────────────────────────────────
    # NETWORK STORAGE
    # ─────────────────────────────────────────────────────────────────
    - name: syncthing
      namespace: apps
      type: kustomize
      path: apps/overlays/syncthing
      gateway:
        class: internal
        hostname: sync.home
        authentication:
          provider: authelia
          policy: one_factor
      vault:
        secrets: true
      mesh:
        mtls: permissive
      network:
        tier: internal
        egressPolicy: allow-list
        allowedEgress:
          - "discovery.syncthing.net"
          - "relay*.syncthing.net"
      hostPorts:
        - 22000/tcp             # Sync protocol
        - 21027/udp             # Discovery
      storage:
        class: kadalu.replica2
        size: 500Gi
      notes: |
        Syncthing instead of SMB/Samba:
        - Encrypted sync, no network shares
        - Works across internet
        - Better mobile apps
        - Conflict resolution
        - Zero server-side exposure
```

---

## 2. HashiCorp Vault Integration

### Vault Setup

```yaml
# security/vault/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: vault
  namespace: vault
spec:
  interval: 1h
  chart:
    spec:
      chart: vault
      version: "0.28.x"
      sourceRef:
        kind: HelmRepository
        name: hashicorp
        namespace: flux-system
  values:
    server:
      ha:
        enabled: true
        replicas: 3
        raft:
          enabled: true
          config: |
            storage "raft" {
              path = "/vault/data"
              retry_join {
                leader_api_addr = "https://vault-0.vault-internal:8200"
              }
              retry_join {
                leader_api_addr = "https://vault-1.vault-internal:8200"
              }
              retry_join {
                leader_api_addr = "https://vault-2.vault-internal:8200"
              }
            }

      dataStorage:
        storageClass: kadalu.replica2
        size: 10Gi

      # Auto-unseal with Kubernetes
      extraEnvironmentVars:
        VAULT_SEAL_TYPE: transit
        VAULT_AWSKMS_SEAL_KEY_ID: ""  # Or use cloud KMS

    injector:
      enabled: true
      replicas: 2
```

### Vault Configuration (Terraform)

```hcl
# security/vault/vault-config/auth-kubernetes.tf
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "config" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = "https://kubernetes.default.svc"
  kubernetes_ca_cert = file("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
}

# Role for each namespace
resource "vault_kubernetes_auth_backend_role" "apps" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "apps"
  bound_service_account_names      = ["*"]
  bound_service_account_namespaces = ["apps"]
  token_policies                   = ["apps-read"]
  token_ttl                        = 3600
}

resource "vault_kubernetes_auth_backend_role" "dmz" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "dmz"
  bound_service_account_names      = ["*"]
  bound_service_account_namespaces = ["dmz"]
  token_policies                   = ["dmz-read"]
  token_ttl                        = 1800  # Shorter TTL for DMZ
}
```

```hcl
# security/vault/vault-config/pki-engine.tf
# Root CA
resource "vault_mount" "pki_root" {
  path                  = "pki-root"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000  # 10 years
}

resource "vault_pki_secret_backend_root_cert" "root" {
  backend     = vault_mount.pki_root.path
  type        = "internal"
  common_name = "Home Lab Root CA"
  ttl         = "87600h"
  key_type    = "ec"
  key_bits    = 384
}

# Intermediate CA for service certs
resource "vault_mount" "pki_int" {
  path                  = "pki-int"
  type                  = "pki"
  max_lease_ttl_seconds = 157680000  # 5 years
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int" {
  backend     = vault_mount.pki_int.path
  type        = "internal"
  common_name = "Home Lab Intermediate CA"
  key_type    = "ec"
  key_bits    = 384
}

resource "vault_pki_secret_backend_root_sign_intermediate" "int" {
  backend     = vault_mount.pki_root.path
  csr         = vault_pki_secret_backend_intermediate_cert_request.int.csr
  common_name = "Home Lab Intermediate CA"
  ttl         = "43800h"
}

# Role for issuing service certificates
resource "vault_pki_secret_backend_role" "services" {
  backend          = vault_mount.pki_int.path
  name             = "services"
  allowed_domains  = ["home", "svc.cluster.local"]
  allow_subdomains = true
  max_ttl          = "720h"  # 30 days
  key_type         = "ec"
  key_bits         = 256
}
```

```hcl
# security/vault/vault-config/secrets-engines.tf
# KV secrets for applications
resource "vault_mount" "secret" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "KV Version 2 secret engine mount"
}

# Dynamic PostgreSQL credentials
resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

resource "vault_database_secret_backend_connection" "postgres" {
  backend       = vault_mount.database.path
  name          = "postgres"
  allowed_roles = ["nextcloud", "n8n", "keycloak"]

  postgresql {
    connection_url = "postgres://{{username}}:{{password}}@postgres.database.svc:5432/postgres"
  }

  data = {
    username = "vault_admin"
    password = var.postgres_password
  }
}

resource "vault_database_secret_backend_role" "nextcloud" {
  backend             = vault_mount.database.path
  name                = "nextcloud"
  db_name             = vault_database_secret_backend_connection.postgres.name
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT ALL PRIVILEGES ON DATABASE nextcloud TO \"{{name}}\";",
  ]
  default_ttl         = 3600
  max_ttl             = 86400
}
```

### External Secrets Integration

```yaml
# security/vault/external-secrets/cluster-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault
spec:
  provider:
    vault:
      server: "https://vault.vault.svc:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
# Example: Vaultwarden secrets
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: vaultwarden
  namespace: dmz
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault
  target:
    name: vaultwarden-secrets
    creationPolicy: Owner
  data:
    - secretKey: ADMIN_TOKEN
      remoteRef:
        key: dmz/vaultwarden
        property: admin-token
    - secretKey: SMTP_PASSWORD
      remoteRef:
        key: dmz/vaultwarden
        property: smtp-password
```

---

## 3. Envoy Gateway

### Why Envoy Gateway?
- **Native Gateway API**: First-class support
- **Extensible**: OAuth2, rate limiting, WAF via filters
- **Performance**: Battle-tested in production
- **Security features**: Built-in mTLS, RBAC, auth

```yaml
# infrastructure/envoy-gateway/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: envoy-gateway
  namespace: envoy-gateway-system
spec:
  interval: 1h
  chart:
    spec:
      chart: gateway-helm
      version: "1.x"
      sourceRef:
        kind: HelmRepository
        name: envoy-gateway
        namespace: flux-system
  values:
    config:
      envoyGateway:
        gateway:
          controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

### Security Policies

```yaml
# infrastructure/envoy-gateway/security-policies/rate-limiting.yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: dmz-rate-limit
  namespace: gateway-system
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: external
  rateLimit:
    type: Global
    global:
      rules:
        - clientSelectors:
            - headers:
                - name: x-forwarded-for
                  type: Distinct
          limit:
            requests: 100
            unit: Minute
---
# WAF via external auth
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: dmz-security
  namespace: gateway-system
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: external
  extAuth:
    http:
      backendRef:
        name: crowdsec-bouncer
        port: 8080
      headersToBackend:
        - x-forwarded-for
        - x-real-ip
```

### Gateways

```yaml
# infrastructure/envoy-gateway/gateways/internal.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: internal
  namespace: gateway-system
spec:
  gatewayClassName: envoy-gateway
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
            namespace: cert-manager
      allowedRoutes:
        namespaces:
          from: All
---
# infrastructure/envoy-gateway/gateways/external.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external
  namespace: gateway-system
  annotations:
    # Apply security policy
    gateway.envoyproxy.io/security-policy: dmz-security
spec:
  gatewayClassName: envoy-gateway
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

## 4. Authelia - Lightweight SSO

### Why Authelia over Keycloak/Authentik?
- **Lightweight**: ~50MB RAM vs 1GB+
- **Simple**: Config file, not a database
- **Security-focused**: Built for forward auth
- **WebAuthn/FIDO2**: Native hardware key support
- **TOTP**: Standard 2FA support

```yaml
# security/authelia/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: authelia
  namespace: authelia
spec:
  interval: 1h
  chart:
    spec:
      chart: authelia
      version: "0.9.x"
      sourceRef:
        kind: HelmRepository
        name: authelia
        namespace: flux-system
  values:
    domain: home

    ingress:
      enabled: true
      className: internal
      tls:
        enabled: true
        secret: wildcard-home-tls

    pod:
      extraVolumeMounts:
        - name: config
          mountPath: /config
      extraVolumes:
        - name: config
          configMap:
            name: authelia-config
```

### Authelia Configuration

```yaml
# security/authelia/config/configuration.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authelia-config
  namespace: authelia
data:
  configuration.yml: |
    theme: dark
    default_2fa_method: totp

    server:
      host: 0.0.0.0
      port: 9091

    log:
      level: info

    authentication_backend:
      file:
        path: /config/users_database.yml
        password:
          algorithm: argon2id
          iterations: 3
          memory: 65536
          parallelism: 4

    access_control:
      default_policy: deny
      rules:
        # Status page - public
        - domain: status.home
          policy: bypass

        # Admin apps - 2FA required
        - domain:
            - n8n.home
            - vault.home
            - grafana.home
          policy: two_factor
          subject:
            - "group:admins"

        # Standard apps - 1FA
        - domain:
            - cloud.home
            - audiobooks.home
            - files.home
          policy: one_factor
          subject:
            - "group:users"
            - "group:admins"

        # Media - 1FA
        - domain:
            - sonarr.home
            - radarr.home
            - prowlarr.home
            - qbit.home
          policy: one_factor
          subject:
            - "group:media"
            - "group:admins"

    session:
      name: authelia_session
      domain: home
      same_site: lax
      expiration: 1h
      inactivity: 5m
      remember_me_duration: 1M
      redis:
        host: redis
        port: 6379

    regulation:
      max_retries: 3
      find_time: 2m
      ban_time: 5m

    storage:
      local:
        path: /config/db.sqlite3

    notifier:
      smtp:
        host: smtp.fastmail.com
        port: 465
        username: ${SMTP_USERNAME}
        password: ${SMTP_PASSWORD}
        sender: "Auth <auth@home>"

    identity_providers:
      oidc:
        hmac_secret: ${OIDC_HMAC_SECRET}
        issuer_private_key: ${OIDC_PRIVATE_KEY}
        clients:
          - id: nextcloud
            description: Nextcloud
            secret: ${NEXTCLOUD_OIDC_SECRET}
            authorization_policy: one_factor
            redirect_uris:
              - https://cloud.home/apps/oidc_login/oidc
            scopes:
              - openid
              - profile
              - email
              - groups
```

### Users Database (GitOps)

```yaml
# security/authelia/config/users.yaml
apiVersion: v1
kind: Secret
metadata:
  name: authelia-users
  namespace: authelia
type: Opaque
stringData:
  users_database.yml: |
    users:
      archerr:
        displayname: "Archerr"
        password: "$argon2id$v=19$m=65536,t=3,p=4$..."
        email: you@email.com
        groups:
          - admins
          - users
          - media

      family:
        displayname: "Family Member"
        password: "$argon2id$..."
        email: family@email.com
        groups:
          - users
```

---

## 5. Cilium mTLS Service Mesh

```yaml
# infrastructure/cilium/helmrelease.yaml (extended)
values:
  # ... base config from Plan 2 ...

  # Enable mTLS
  authentication:
    mutual:
      spire:
        enabled: true
        install:
          enabled: true
          namespace: spire
          server:
            dataStorage:
              storageClass: kadalu.replica2
```

### mTLS Policies

```yaml
# infrastructure/cilium/mesh-config/mtls-policy.yaml
---
# Require mTLS for all internal traffic
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: require-mtls
  namespace: apps
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - {}
      authentication:
        mode: required
---
# Allow permissive mode for IoT/media
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: permissive-mtls
  namespace: automation
spec:
  endpointSelector:
    matchLabels:
      app: home-assistant
  ingress:
    - fromEndpoints:
        - {}
      authentication:
        mode: optional
```

---

## 6. Runtime Security with Falco

```yaml
# policies/falco/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: falco
  namespace: falco
spec:
  interval: 1h
  chart:
    spec:
      chart: falco
      version: "4.x"
      sourceRef:
        kind: HelmRepository
        name: falcosecurity
        namespace: flux-system
  values:
    driver:
      kind: ebpf

    falco:
      grpc:
        enabled: true
      grpcOutput:
        enabled: true

    falcosidekick:
      enabled: true
      config:
        webhook:
          address: http://ntfy.automation.svc:8080/falco
```

### Custom Rules

```yaml
# policies/falco/rules/home-lab-rules.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-rules
  namespace: falco
data:
  home-lab.yaml: |
    - rule: Shell spawned in DMZ
      desc: Detect shell access in DMZ namespace
      condition: >
        spawned_process and
        shell_procs and
        k8s.ns.name = "dmz"
      output: >
        Shell spawned in DMZ (user=%user.name command=%proc.cmdline
        container=%container.name namespace=%k8s.ns.name)
      priority: CRITICAL
      tags: [shell, dmz]

    - rule: Unexpected network connection from DMZ
      desc: DMZ pod connecting to non-approved destination
      condition: >
        outbound and
        k8s.ns.name = "dmz" and
        not (fd.sip in (push.bitwarden.com, api.pwnedpasswords.com))
      output: >
        DMZ pod making unexpected connection
        (container=%container.name dest=%fd.sip:%fd.sport)
      priority: WARNING

    - rule: Sensitive file access
      desc: Access to sensitive files like /etc/shadow
      condition: >
        open_read and
        (fd.name startswith /etc/shadow or
         fd.name startswith /etc/passwd or
         fd.name contains "id_rsa")
      output: >
        Sensitive file accessed (file=%fd.name container=%container.name)
      priority: WARNING

    - rule: Crypto mining detection
      desc: Detect potential crypto mining
      condition: >
        spawned_process and
        (proc.name in (xmrig, minerd, cpuminer) or
         proc.cmdline contains "stratum+tcp")
      output: >
        Potential crypto mining detected (command=%proc.cmdline)
      priority: CRITICAL
```

---

## 7. Kyverno Policies

```yaml
# policies/kyverno/cluster-policies/require-labels.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-app-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "All pods must have 'app' label"
        pattern:
          metadata:
            labels:
              app: "?*"
---
# policies/kyverno/cluster-policies/require-resource-limits.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-limits
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "CPU and memory limits are required"
        pattern:
          spec:
            containers:
              - resources:
                  limits:
                    memory: "?*"
                    cpu: "?*"
---
# policies/kyverno/cluster-policies/restrict-registries.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce
  rules:
    - name: allowed-registries
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Images must come from approved registries"
        pattern:
          spec:
            containers:
              - image: "ghcr.io/* | docker.io/library/* | quay.io/* | gcr.io/* | registry.k8s.io/*"
---
# policies/kyverno/cluster-policies/require-readonly-rootfs.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-readonly-rootfs
spec:
  validationFailureAction: Audit  # Start with audit, move to Enforce
  rules:
    - name: readonly-rootfs
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - dmz
      validate:
        message: "DMZ pods must have readOnlyRootFilesystem"
        pattern:
          spec:
            containers:
              - securityContext:
                  readOnlyRootFilesystem: true
```

---

## 8. Application Security Contexts

### Generated Security Context (from manifest)

```yaml
# Auto-generated based on runtime settings in manifest
apiVersion: v1
kind: Pod
metadata:
  name: example-app
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault

  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL

      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache

  volumes:
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 100Mi
    - name: cache
      emptyDir: {}
```

---

## 9. Syncthing for Network Storage

### Why Syncthing over SMB/Samba?
- **Zero network shares**: No SMB ports exposed
- **End-to-end encrypted**: Data encrypted in transit
- **Works everywhere**: Sync across internet, not just LAN
- **Conflict resolution**: Smart handling of simultaneous edits
- **Mobile apps**: Excellent Android/iOS apps
- **No server dependency**: Peer-to-peer, cluster just provides storage

```yaml
# apps/overlays/syncthing/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: syncthing
  namespace: apps
spec:
  replicas: 1
  template:
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000

      containers:
        - name: syncthing
          image: syncthing/syncthing:latest
          ports:
            - containerPort: 8384   # Web UI
            - containerPort: 22000  # Sync
              protocol: TCP
            - containerPort: 22000
              protocol: UDP
            - containerPort: 21027  # Discovery
              protocol: UDP
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
          volumeMounts:
            - name: config
              mountPath: /var/syncthing/config
            - name: data
              mountPath: /var/syncthing/data
          securityContext:
            readOnlyRootFilesystem: false  # Syncthing needs write
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]

      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: syncthing-config
        - name: data
          persistentVolumeClaim:
            claimName: syncthing-data
---
# Service for web UI (internal only)
apiVersion: v1
kind: Service
metadata:
  name: syncthing
  namespace: apps
spec:
  ports:
    - name: web
      port: 8384
  selector:
    app: syncthing
---
# Service for sync (needs external access)
apiVersion: v1
kind: Service
metadata:
  name: syncthing-sync
  namespace: apps
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.1.210
  ports:
    - name: tcp
      port: 22000
      protocol: TCP
    - name: udp
      port: 22000
      protocol: UDP
    - name: discovery
      port: 21027
      protocol: UDP
  selector:
    app: syncthing
```

**Setup on devices:**
1. Install Syncthing on phone/PC
2. Add cluster's device ID
3. Share folders
4. Sync happens automatically

---

## 10. Observability

### Security-Focused Dashboards

```yaml
# observability/security-dashboards/overview.yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: security-overview
  namespace: observability
spec:
  json: |
    {
      "title": "Security Overview",
      "panels": [
        {
          "title": "Falco Alerts (24h)",
          "type": "stat",
          "targets": [{
            "expr": "sum(increase(falco_events_total[24h]))"
          }]
        },
        {
          "title": "Failed Auth Attempts",
          "type": "timeseries",
          "targets": [{
            "expr": "rate(authelia_authentication_failures_total[5m])"
          }]
        },
        {
          "title": "Network Policy Denies",
          "type": "timeseries",
          "targets": [{
            "expr": "rate(hubble_drop_total{reason=\"Policy denied\"}[5m])"
          }]
        },
        {
          "title": "Vault Audit Events",
          "type": "logs",
          "targets": [{
            "expr": "{job=\"vault\"} |= \"auth\""
          }]
        },
        {
          "title": "DMZ Traffic Analysis",
          "type": "table",
          "targets": [{
            "expr": "topk(10, sum by (destination_fqdn) (rate(hubble_flows_processed_total{source_namespace=\"dmz\"}[1h])))"
          }]
        }
      ]
    }
```

---

## 11. Bootstrap Process

```bash
#!/bin/bash
# bootstrap/install.sh

set -e

echo "=== Phase 1: Core Infrastructure ==="

# Install ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values bootstrap/argocd/values.yaml \
  --wait

# Apply root app
kubectl apply -f bootstrap/argocd/root-app.yaml

echo "=== Phase 2: Initialize Vault ==="

# Wait for Vault pods
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault \
  --namespace vault --timeout=300s

# Initialize Vault
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > vault-keys.json

echo "IMPORTANT: Save vault-keys.json securely and delete this file!"

# Unseal Vault (in production, use auto-unseal)
for i in 0 1 2; do
  for key in $(jq -r '.unseal_keys_b64[0:3][]' vault-keys.json); do
    kubectl exec -n vault vault-$i -- vault operator unseal $key
  done
done

echo "=== Phase 3: Configure Vault ==="

# Run Terraform for Vault config
cd security/vault/vault-config
terraform init
terraform apply -auto-approve

echo "=== Phase 4: Wait for sync ==="

kubectl wait --for=condition=Healthy application/root \
  --namespace argocd --timeout=600s

echo "=== Done! ==="
echo ""
echo "Access:"
echo "  ArgoCD:   https://argocd.home"
echo "  Grafana:  https://grafana.home"
echo "  Authelia: https://auth.home"
echo "  Vault:    https://vault.home"
```

---

## Pros & Cons

### Pros
- **Maximum security**: Defense in depth at every layer
- **Zero trust**: Every connection is authenticated
- **Secrets management**: Vault handles all secrets, dynamic creds
- **Audit trail**: Full visibility into all security events
- **Compliance-ready**: Would pass security audits
- **Workload identity**: SPIFFE gives cryptographic identity to pods
- **Runtime protection**: Falco catches runtime anomalies

### Cons
- **Complexity**: Many moving parts to understand and maintain
- **Resource overhead**: Vault HA (3 replicas), Falco, SPIRE agents
- **Learning curve**: Vault, SPIFFE, Kyverno all require learning
- **Operational burden**: Vault unsealing, key rotation, policy updates
- **Over-engineered**: Might be overkill for a home lab
- **Debugging harder**: mTLS everywhere makes tcpdump useless

---

## Resource Estimates

| Component | CPU Request | Memory Request |
|-----------|-------------|----------------|
| ArgoCD | 500m | 512Mi |
| Vault (3 replicas) | 750m | 1.5Gi |
| Cilium (w/ mesh) | 600m | 768Mi |
| Envoy Gateway | 200m | 256Mi |
| Authelia | 100m | 128Mi |
| Falco | 200m | 512Mi |
| Kyverno | 200m | 256Mi |
| External Secrets | 100m | 128Mi |
| Grafana Stack | 500m | 1Gi |
| Apps (total) | 2000m | 4Gi |
| **Total** | **~5 cores** | **~9Gi** |

Higher than other plans, but still fits comfortably in 3 × 16GB nodes.

---

## When to Choose This Plan

**Choose this if:**
- You work in security and want to practice enterprise patterns
- You plan to expose services to the internet beyond Cloudflare Tunnel
- You handle sensitive data (financial, health, etc.)
- You want to learn Vault, SPIFFE, and zero-trust architectures
- You enjoy the operational complexity

**Don't choose this if:**
- You want a simple, low-maintenance home lab
- You're new to Kubernetes
- You just want things to work
- Resource usage is a concern
