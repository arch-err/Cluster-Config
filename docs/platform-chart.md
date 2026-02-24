# Platform Chart

The platform chart is a meta-chart that generates ArgoCD Applications and supporting resources. It uses convention over configuration to minimize boilerplate.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Platform Chart                             │
│                  kubernetes/platform/                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Values File (infra.yaml or apps.yaml)                        │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │ repoURL: https://github.com/arch-err/Cluster-Config.git │  │
│   │ targetRevision: v2                                       │  │
│   │ valuesPath: values/infra  ◄── Convention!               │  │
│   │                                                          │  │
│   │ components:                                              │  │
│   │   - name: grafana        ◄── Loads values/infra/grafana.yaml
│   │     chart: ...                                           │  │
│   │     route:                                               │  │
│   │       hostname: grafana.home                             │  │
│   └─────────────────────────────────────────────────────────┘  │
│                           │                                     │
│                           ▼                                     │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │              templates/applications.yaml                 │  │
│   │                                                          │  │
│   │  Generates ArgoCD Application for each component         │  │
│   │  - Sources Helm chart from component.chart.repo          │  │
│   │  - Values from: $repo/{valuesPath}/{name}.yaml           │  │
│   └─────────────────────────────────────────────────────────┘  │
│                           │                                     │
│                           ▼                                     │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │              templates/httproutes.yaml                   │  │
│   │                                                          │  │
│   │  Generates HTTPRoute for components with route config    │  │
│   └─────────────────────────────────────────────────────────┘  │
│                           │                                     │
│                           ▼                                     │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │              templates/extras.yaml                       │  │
│   │                                                          │  │
│   │  Conditional resources (gateways, certs, external svcs)  │  │
│   └─────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Convention Over Configuration

### Values File Naming

The chart uses a naming convention to locate values files:

```
{valuesPath}/{component.name}.yaml
```

Example:
```yaml
# infra.yaml
valuesPath: values/infra

components:
  - name: grafana
    # → Loads: values/infra/grafana.yaml

  - name: cert-manager
    # → Loads: values/infra/cert-manager.yaml
```

### Namespace Defaults

If `namespace` is not specified, it defaults to the component name:

```yaml
components:
  - name: grafana
    # namespace defaults to: grafana

  - name: cilium
    namespace: kube-system  # Explicit override
```

### Service Name Defaults

For HTTPRoutes, `service` defaults to the component name:

```yaml
components:
  - name: grafana
    route:
      hostname: grafana.home
      port: 3000
      # service defaults to: grafana

  - name: argocd
    route:
      hostname: argocd.home
      service: argocd-server  # Explicit override
      port: 80
```

## Component Schema

```yaml
components:
  - name: string           # Required: component name (also used for values file)
    namespace: string      # Optional: defaults to name
    syncWave: string       # Optional: ArgoCD sync wave (default: "0")
    chart:
      repo: string         # Required: Helm repository URL
      name: string         # Required: Chart name
      version: string      # Optional: Version constraint (default: "*")
    extraArgs:             # Optional: Additional Helm parameters
      - "key=value"
    route:                 # Optional: Creates HTTPRoute
      hostname: string     # Required if route specified
      gateway: string      # Optional: defaults to "internal"
      service: string      # Optional: defaults to component name
      port: number         # Optional: defaults to 80
```

## Templates

### applications.yaml

Generates an ArgoCD Application for each component:

```yaml
{{- range .Values.components }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: argocd
spec:
  sources:
    # Values from Git repo
    - repoURL: {{ $root.Values.repoURL }}
      targetRevision: {{ $root.Values.targetRevision }}
      ref: repo

    # Helm chart
    - repoURL: {{ .chart.repo }}
      targetRevision: {{ .chart.version | default "*" }}
      chart: {{ .chart.name }}
      helm:
        valueFiles:
          - $repo/{{ $root.Values.valuesPath }}/{{ .name }}.yaml
{{- end }}
```

### httproutes.yaml

Generates HTTPRoutes for components with `route` config:

```yaml
{{- range .Values.components }}
{{- if .route }}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .name }}
  namespace: {{ .namespace | default .name }}
spec:
  parentRefs:
    - name: {{ .route.gateway | default "internal" }}
      namespace: gateway-system
  hostnames:
    - {{ .route.hostname }}
  rules:
    - backendRefs:
        - name: {{ .route.service | default .name }}
          port: {{ .route.port | default 80 }}
{{- end }}
{{- end }}
```

### extras.yaml

Conditional resources enabled via `extras.*`:

```yaml
extras:
  gateways: true        # L2 policy, IP pool, gateways
  certIssuers: true     # ClusterIssuer, wildcard certificate
  externalServices: true # External service proxying
```

## Two Instances

The platform chart is instantiated twice:

### 1. Infrastructure (`infra`)

```yaml
# kubernetes/infra.yaml
repoURL: https://github.com/arch-err/Cluster-Config.git
targetRevision: v2
valuesPath: values/infra

components:
  - name: cilium
    namespace: kube-system
    chart:
      repo: https://helm.cilium.io
      name: cilium
      version: 1.16.x
    route:
      hostname: hubble.home
      service: hubble-ui
      port: 80

  - name: cert-manager
    namespace: cert-manager
    chart:
      repo: https://charts.jetstack.io
      name: cert-manager
    extraArgs:
      - installCRDs=true

  - name: argocd
    namespace: argocd
    chart:
      repo: https://argoproj.github.io/argo-helm
      name: argo-cd
    route:
      hostname: argocd.home
      service: argocd-server
      port: 80

extras:
  gateways: true
  certIssuers: true
  externalServices: true

gateway:
  pool:
    start: "192.168.1.200"
    stop: "192.168.1.220"
  internal:
    ip: "192.168.1.200"
    domain: home
    tlsSecret: wildcard-home-tls

external:
  dockerHost: "192.168.1.60"
  passthroughIP: "192.168.1.202"
  services:
    - name: homeassistant
      hostname: homeassistant.home
    # ...
```

### 2. Applications (`apps`)

```yaml
# kubernetes/apps.yaml
repoURL: https://github.com/arch-err/Cluster-Config.git
targetRevision: v2
valuesPath: values/apps

components: []
  # Add applications here:
  # - name: homepage
  #   chart:
  #     repo: https://jameswynn.github.io/helm-charts
  #     name: homepage
  #   route:
  #     hostname: home.home
  #     port: 3000
```

## Extras Detail

### Gateways (`extras.gateways`)

Creates:
- `gateway-system` namespace
- `CiliumL2AnnouncementPolicy`
- `CiliumLoadBalancerIPPool`
- `ReferenceGrant` (for cross-namespace TLS cert access)
- `internal` Gateway (TLS termination)

### Cert Issuers (`extras.certIssuers`)

Creates:
- `home-ca` ClusterIssuer (uses pre-existing root CA secret)
- `wildcard-home` Certificate

### External Services (`extras.externalServices`)

Creates:
- `external` namespace
- `docker-traefik` Service + EndpointSlice (pointing to Docker host)
- `passthrough` Gateway (TLS passthrough)
- TLSRoute for each external service

## Sync Wave Order

Resources sync in this order:

1. **Wave 0**: ArgoCD Applications
2. **Wave 1**: L2 Policy, IP Pool
3. **Wave 3**: ClusterIssuer
4. **Wave 4**: Certificate, ReferenceGrant
5. **Wave 5**: Gateways
6. **Wave 6**: TLSRoutes
7. **Wave 10**: HTTPRoutes (for apps)

## Extending

### Adding a New Extra

1. Add toggle in values:
   ```yaml
   extras:
     myExtra: true
   ```

2. Add conditional block in `extras.yaml`:
   ```yaml
   {{- if .Values.extras.myExtra }}
   ---
   # Your resources here
   {{- end }}
   ```

### Adding Component Parameters

1. Update component schema in templates
2. Use in `applications.yaml`:
   ```yaml
   {{- if .myNewParam }}
   # Use it
   {{- end }}
   ```
