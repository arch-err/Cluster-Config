# platform meta-chart

Renders ArgoCD `Application` objects + cross-cutting platform resources from
the `components: [...]` list defined in `kubernetes/apps.yaml` and
`kubernetes/infra.yaml`.

Templates:

- `applications.yaml` — emits one `argoproj.io/Application` per component
- `httproutes.yaml`   — emits the matching `HTTPRoute` (and gethomepage
  dashboard annotations) for any component with a `route:` block
- `extras.yaml`       — opt-in platform resources (gateways, kadalu storage,
  cert-issuers, ns labels for restricted-PSS exceptions, immich postgres, etc.)
- `oidc-bootstrap.yaml` — declarative pocket-id OIDC client registration; see
  below
- `db-postgres.yaml`    — declarative CloudNativePG `Cluster` CR rendering; see
  below

## OIDC client auto-registration (`oidc:` block)

> **Pre-req:** pocket-id is up at `auth.apps.home`, an admin API token has
> been minted in the UI (see `kubernetes/manual/pocket-id/README.md`), and
> the SOPS-encrypted secret `kubernetes/secrets/apps/pocket-id-api-token.yaml`
> has its `POCKET_ID_API_TOKEN` populated.

Add an `oidc:` block to any component in `apps.yaml`:

```yaml
- name: grafana
  namespace: monitoring
  chart: { ... }
  route: { ... }
  oidc:
    enabled: true
    callbackUrls:
      - https://grafana.apps.home/login/generic_oauth
    # All fields below are optional with sensible defaults:
    scopes: [openid, profile, email, groups]   # informational, no API field
    secretName: grafana-oidc-client            # default: <app>-oidc-client
    public: false                              # default: false (confidential)
    pkceEnabled: true                          # default: true
    logoutCallbackUrls: []                     # default: []
```

What gets rendered (only when `enabled: true`):

| Resource         | Namespace      | Purpose                                                  |
|------------------|----------------|----------------------------------------------------------|
| ServiceAccount   | `pocket-id`    | Identity the bootstrap Job runs under                    |
| ConfigMap        | `pocket-id`    | The bootstrap script (`bootstrap.sh`)                    |
| Job (hashed name)| `pocket-id`    | Calls pocket-id REST API + writes the cross-ns Secret    |
| Role             | app namespace  | `secrets` `get/update/patch` on the one named Secret + `create` (resource-name-narrowed where allowed; ns-scoped otherwise) |
| RoleBinding      | app namespace  | Binds the SA above into the app namespace                |

The Job name embeds a sha256-truncated hash of the OIDC inputs, so any change
to `callbackUrls`, `scopes`, etc. produces a fresh Job that ArgoCD applies +
runs. Old Jobs auto-cleanup via `ttlSecondsAfterFinished: 600`. On no-op
syncs the Job is unchanged → not re-run.

## What ends up in the app's Secret

Default name: `<app>-oidc-client` (override via `oidc.secretName`).

```yaml
data:
  client_id:     <app-name>          # deterministic — same as $APP_NAME
  client_secret: <random base64ish>  # only present for confidential clients
  issuer_url:    https://auth.apps.home
```

Reference these keys in your app's helm values, e.g.:

```yaml
# values/apps/grafana.yaml
grafana.ini:
  auth.generic_oauth:
    enabled: true
    client_id: ${OAUTH_CLIENT_ID}
    client_secret: ${OAUTH_CLIENT_SECRET}
extraSecretMounts:
  - name: oidc
    secretName: grafana-oidc-client   # written by the bootstrap Job
    defaultMode: 0440
    mountPath: /etc/secrets/oidc
    readOnly: true
```

…or via `envFrom: secretRef: grafana-oidc-client` for charts that read env vars.

## Idempotence + failure modes

- **Re-run safe:** the script does `GET /api/oidc/clients/<id>` first, then
  `PUT` if 200, `POST` if 404. Anything else aborts.
- **Secret rotation:** by default, an existing `client_secret` in the app's
  Secret is reused — the Job won't churn it on every sync. To force rotation,
  delete the Secret in the app ns; next Job run mints a fresh one via
  `POST /api/oidc/clients/<id>/secret`.
- **Public clients (SPAs / native):** `oidc.public: true` skips secret
  generation; Secret only contains `client_id` + `issuer_url`.
- **Pocket-ID briefly down (e.g. during pod rollover):** Job has
  `backoffLimit: 5`, retries with exponential backoff.
- **Bad API token:** Job exits non-zero, ArgoCD shows the Job as failed; user
  re-issues the token (see manual README) and re-syncs.

## Manual still required

The OIDC client itself auto-registers. What does NOT auto-register:

- **Group → role/scope mapping inside the app** — schemas vary too much
  across apps to encode in `apps.yaml`. Per-app, in pocket-id UI:
  Applications → `<app>` → assign user-group access + custom claims.
- **First-run admin enrollment + the API token itself** — see
  `kubernetes/manual/pocket-id/README.md` steps 1-2.

## Pocket-ID REST endpoints used

Verified against pocket-id source @ v2.6.2:

| Method | Path                                | Purpose                          |
|--------|-------------------------------------|----------------------------------|
| GET    | `/api/oidc/clients/{id}`            | Existence check                  |
| POST   | `/api/oidc/clients`                 | Create (with explicit `id`)      |
| PUT    | `/api/oidc/clients/{id}`            | Update (idempotent)              |
| POST   | `/api/oidc/clients/{id}/secret`     | Mint client_secret               |

Auth header: `X-API-Key: <token>` (NOT `Authorization: Bearer`).

## Postgres database (`db:` block)

> **Pre-req:** the `cnpg` infra component is deployed (CloudNativePG operator
> in `cnpg-system`, watching cluster-wide). The operator's CRDs
> (`clusters.postgresql.cnpg.io` et al.) must be registered before any
> `db.enabled: true` component syncs.

Add a `db:` block to any component in `apps.yaml`:

```yaml
- name: forgejo
  namespace: forgejo
  chart: { ... }
  route: { ... }
  db:
    enabled: true
    version: "16"                              # major (default "16")
    storage:
      size: 20Gi                               # required
      storageClass: kadalu.replica2-retain     # default kadalu.replica2-retain
    instances: 1                               # default 1; bump for HA later
    # Optional override; baked-in floor is 200m/512Mi req, 1000m/1Gi limit
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { memory: 1Gi }
```

Postgres-only for v1 — no `db.type:` knob (left as design space for future
engines without a refactor).

What gets rendered (only when `enabled: true`):

| Resource              | Namespace      | Purpose                                                     |
|-----------------------|----------------|-------------------------------------------------------------|
| Cluster (cnpg)        | app namespace  | Drives postgres StatefulSet + Services + auto-minted Secrets |

Cluster name is `<component>-db`. The cnpg operator then mints these
resources in the same namespace:

- StatefulSet `<component>-db-N` (postgres pods)
- Secrets:
  - `<component>-db-app`        — per-app credentials (the one apps consume)
  - `<component>-db-superuser`  — postgres superuser credentials
  - `<component>-db-ca` / `-server` / `-replication` — TLS material
- Services:
  - `<component>-db-rw`         — primary (writes)
  - `<component>-db-ro`         — read-only replicas (none with `instances: 1`)
  - `<component>-db-r`          — any-instance reads (incl. primary)

The DB itself is bootstrapped via cnpg's `initdb` block:
- `database` = `<component>` (e.g. `forgejo`)
- `owner`    = `<component>` (role owning that DB; password in the `-app` secret)

## What ends up in the app's Secret

The `<component>-db-app` Secret (cnpg-minted, NOT SOPS) contains:

```yaml
data:
  username: <app-role>           # = component name
  password: <random>
  host:     <component>-db-rw    # cluster-internal primary Service
  port:     "5432"
  dbname:   <app-role>           # = component name
  uri:      postgresql://user:pass@host:5432/dbname
  jdbc-uri: jdbc:postgresql://...
  pgpass:   ...
```

Reference these keys in your app's helm values, e.g.:

```yaml
# values/apps/forgejo.yaml
gitea:
  config:
    database:
      DB_TYPE: postgres
envFrom:
  - secretRef:
      name: forgejo-db-app
# …or wire individual keys via `secretKeyRef:` if the chart needs specific env names.
```

## Idempotence + failure modes

- **Cluster CR is declarative.** ArgoCD applies it; cnpg reconciles. Changes
  to `instances` / `resources` / `storage.size` are handled by the operator
  (storage size only grows). `storage.storageClass` is immutable post-create.
- **Secret rotation:** cnpg owns the `<cluster>-app` Secret. To rotate the
  app password, delete it; cnpg re-creates with a fresh value on next reconcile.
- **PVC reclaim:** PVCs created from the Cluster's storage template inherit
  the SC's reclaim policy. `kadalu.replica2-retain` is Retain → safe default
  for CRITICAL data.
- **Operator briefly down:** the Cluster CR persists; the operator catches up
  on next start. App pods consuming `<cluster>-app` Secret will CrashLoop
  while the operator is bootstrapping (secret not yet minted) — use sync
  waves / startup probes so the app retries.
- **Bad image version:** the template's `imageByVersion` map fails fast at
  `helm template` time with a clear message — bump the map when adding
  support for a new postgres major.

## Image pinning

Postgres images are pinned per-major in `templates/db-postgres.yaml`'s
`imageByVersion` dict, sourced from cnpg's official
`ClusterImageCatalog-bookworm.yaml`. Upgrade by editing those strings.

## Render-test

```bash
# baseline: no db-enabled apps → zero cnpg Cluster CRs
helm template platform-test kubernetes/platform -f kubernetes/apps.yaml \
  | grep -c 'kind: Cluster$'   # → 0

# with overlay enabling db on a synthetic app:
helm template platform-test kubernetes/platform \
  -f kubernetes/apps.yaml -f /tmp/db-test-overlay.yaml \
  --show-only templates/db-postgres.yaml \
  | kubectl apply --dry-run=server -f -
```

## Render-test (OIDC)

```bash
# baseline: no oidc-enabled apps → zero oidc resources
helm template platform-test kubernetes/platform -f kubernetes/apps.yaml \
  | grep -c oidc-bootstrap   # → 0

# with overlay enabling oidc on a synthetic app:
helm template platform-test kubernetes/platform \
  -f kubernetes/apps.yaml -f /tmp/oidc-test-overlay.yaml \
  --show-only templates/oidc-bootstrap.yaml \
  | kubectl apply --dry-run=server -f -
```
