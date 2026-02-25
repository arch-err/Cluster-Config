# Adding Applications

This guide explains how to deploy new applications to the cluster.

## Quick Start

Adding an app is a two-step process:

1. **Add component to `apps.yaml`**
2. **Create values file in `values/apps/`**

### Example: Adding Grafana

#### Step 1: Add to apps.yaml

```yaml
# kubernetes/apps.yaml
components:
  - name: grafana
    namespace: monitoring
    chart:
      repo: https://grafana.github.io/helm-charts
      name: grafana
    route:
      hostname: grafana.home
      port: 3000
```

#### Step 2: Create values file

```yaml
# kubernetes/values/apps/grafana.yaml
replicas: 1

persistence:
  enabled: true
  size: 1Gi

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://prometheus-server.monitoring:80
```

#### Step 3: Commit and push

```bash
git add kubernetes/apps.yaml kubernetes/values/apps/grafana.yaml
git commit -m "feat: add grafana"
git push
```

ArgoCD will automatically sync and deploy Grafana.

## Component Options

### Minimal Component

```yaml
- name: my-app
  chart:
    repo: https://charts.example.com
    name: my-chart
```

This will:
- Create namespace `my-app`
- Load values from `values/apps/my-app.yaml`
- Deploy the Helm chart

### Full Component Options

```yaml
- name: my-app
  namespace: custom-namespace    # Override namespace
  syncWave: "5"                  # Control sync order
  chart:
    repo: https://charts.example.com
    name: my-chart
    version: "1.2.x"             # Version constraint
  extraArgs:
    - "someKey=someValue"        # Extra Helm parameters
  route:
    hostname: my-app.home        # Creates HTTPRoute
    gateway: internal            # Which gateway (default: internal)
    service: my-app-frontend     # Service name if different
    port: 8080                   # Service port
```

## Finding Helm Charts

### Common Chart Repositories

| Repository | URL |
|------------|-----|
| Bitnami | https://charts.bitnami.com/bitnami |
| Grafana | https://grafana.github.io/helm-charts |
| Prometheus | https://prometheus-community.github.io/helm-charts |
| Jetstack | https://charts.jetstack.io |
| Ingress-NGINX | https://kubernetes.github.io/ingress-nginx |

### Searching for Charts

```bash
# Add repo and search
helm repo add bitnami https://charts.bitnami.com/bitnami
helm search repo bitnami/

# Get default values
helm show values bitnami/postgresql > postgresql-values.yaml
```

## HTTPRoute Configuration

### Basic Route

```yaml
route:
  hostname: app.home
  port: 3000
```

Creates:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app
spec:
  parentRefs:
    - name: internal
      namespace: gateway-system
  hostnames:
    - app.home
  rules:
    - backendRefs:
        - name: my-app
          port: 3000
```

### Custom Service Name

Some charts create services with different names:

```yaml
- name: argocd
  route:
    hostname: argocd.home
    service: argocd-server  # Chart creates "argocd-server" not "argocd"
    port: 80
```

### No Route

For backend services that don't need external access:

```yaml
- name: postgresql
  chart:
    repo: https://charts.bitnami.com/bitnami
    name: postgresql
  # No route - internal only
```

## Values Files

### Location

Values files are loaded from the `valuesPath` specified in apps.yaml:
```
{valuesPath}/{name}.yaml
```

For apps (valuesPath: `kubernetes/values/apps`):
```
kubernetes/values/apps/{name}.yaml
```

### Finding Default Values

```bash
# Get chart's default values
helm show values grafana/grafana > grafana-defaults.yaml

# Or from ArtifactHub
# https://artifacthub.io/packages/helm/grafana/grafana
```

### Common Patterns

#### Persistence

```yaml
persistence:
  enabled: true
  storageClass: ""  # Uses default StorageClass
  size: 10Gi
```

#### Resources

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi
```

#### Ingress Disabled

Since we use Gateway API, disable chart ingress:

```yaml
ingress:
  enabled: false
```

## Examples

### PostgreSQL Database

```yaml
# apps.yaml
- name: postgresql
  namespace: databases
  chart:
    repo: https://charts.bitnami.com/bitnami
    name: postgresql
```

```yaml
# kubernetes/values/apps/postgresql.yaml
auth:
  existingSecret: postgresql-credentials  # Reference SopsSecret
  database: myapp

primary:
  persistence:
    enabled: true
    size: 10Gi
```

For credentials, create a SopsSecret in `kubernetes/secrets/apps/postgresql.yaml`.

### Homepage Dashboard

```yaml
# apps.yaml
- name: homepage
  chart:
    repo: https://jameswynn.github.io/helm-charts
    name: homepage
  route:
    hostname: home.home
    port: 3000
```

```yaml
# values/apps/homepage.yaml
config:
  services:
    - Infrastructure:
        - ArgoCD:
            href: https://argocd.home
            icon: argocd
        - Hubble:
            href: https://hubble.home
            icon: cilium
```

### Prometheus Stack

```yaml
# apps.yaml
- name: kube-prometheus-stack
  namespace: monitoring
  chart:
    repo: https://prometheus-community.github.io/helm-charts
    name: kube-prometheus-stack
```

```yaml
# values/apps/kube-prometheus-stack.yaml
prometheus:
  prometheusSpec:
    retention: 7d
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 50Gi

grafana:
  enabled: true
  ingress:
    enabled: false  # Using Gateway API
```

Then add a route separately in apps.yaml:
```yaml
- name: kube-prometheus-stack
  # ...
  route:
    hostname: grafana.home
    service: kube-prometheus-stack-grafana
    port: 80
```

## Debugging

### Check ArgoCD Status

```bash
# List all applications
kubectl -n argocd get applications

# Get app details
kubectl -n argocd describe application my-app

# View in ArgoCD UI
just argocd-ui
```

### Common Issues

#### Values file not found

```
Error: open values/apps/my-app.yaml: no such file or directory
```

Create the values file, even if empty:
```bash
touch kubernetes/values/apps/my-app.yaml
```

#### Wrong service name

```
HTTPRoute stuck in "Accepted: False"
```

Check what service the chart actually creates:
```bash
kubectl -n my-app get svc
```

Update the route with the correct service name.

#### Sync wave ordering

If an app needs another app to exist first:
```yaml
- name: app-depends-on-db
  syncWave: "10"  # Higher = syncs later
```

## Best Practices

1. **Always check default values** before creating your values file
2. **Disable chart ingress** - use Gateway API routes instead
3. **Use version constraints** like `1.2.x` for stability
4. **Keep values minimal** - only override what you need
5. **Use SOPS for secrets** - don't commit passwords in plain text
