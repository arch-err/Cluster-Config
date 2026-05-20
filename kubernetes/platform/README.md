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

## Forgejo admin-token bootstrap (`forgejoAdmin:` block)

> **Pre-req:** forgejo is deployed (phase 3) and the SOPS-encrypted secret
> `kubernetes/secrets/apps/forgejo-admin-bootstrap.yaml` carries `username`,
> `password`, `email`, and `ADMIN_PASSWORD` keys. The codeberg/forgejo
> chart's `gitea.admin.existingSecret` (set in `values/apps/forgejo.yaml`)
> consumes the first three to auto-create the `cluster-bootstrap` admin on
> first pod boot. The `ADMIN_PASSWORD` key is consumed by the bootstrap
> Job below.

Add a `forgejoAdmin:` block to the forgejo component in `apps.yaml`:

```yaml
- name: forgejo
  namespace: forgejo
  chart: { ... }
  route: { ... }
  db: { ... }
  forgejoAdmin:
    enabled: true
    username: cluster-bootstrap                    # default `cluster-bootstrap`
    email: cluster-bootstrap@apps.home             # default `<user>@apps.home`
    passwordSecret: forgejo-admin-bootstrap        # default `forgejo-admin-bootstrap`
    tokenSecretName: forgejo-admin-token           # default `forgejo-admin-token`
    tokenSecretNamespace: crossplane-system        # default `crossplane-system`
    # Optional: override forgejo URL (default http://forgejo-http.<ns>.svc:3000)
    # forgejoUrl: http://forgejo-http.forgejo.svc:3000
    # Optional: token name on forgejo's side (default `crossplane`)
    # tokenName: crossplane
```

What gets rendered (only when `enabled: true`):

| Resource         | Namespace        | Purpose                                                    |
|------------------|------------------|------------------------------------------------------------|
| ServiceAccount   | forgejo ns       | Identity the bootstrap Job runs under                      |
| ConfigMap        | forgejo ns       | The bootstrap script (`bootstrap.sh`)                      |
| Job (hashed name)| forgejo ns       | Basic-auths to forgejo's REST API, mints API token, writes Secret |
| Role             | tokenNs          | `secrets` `get/update/patch` on the one named Secret + `create` |
| RoleBinding      | tokenNs          | Binds the forgejo-ns SA into tokenNs                       |

What ends up in the rendered Secret (`tokenSecretNamespace/tokenSecretName`):

```yaml
data:
  token:       <forgejo-issued-token>   # ~40-char hex sha1
  username:    cluster-bootstrap
  forgejo-url: https://git.apps.home
```

Idempotence:

- Both forgejo-side token + k8s-side Secret present → exit 0, no-op
- forgejo-side token missing → mint fresh, write Secret
- forgejo-side token present but Secret missing/empty → delete forgejo-side
  token (plaintext is unreadable post-create), re-mint, write Secret
- Job name embeds a sha256-truncated hash of the inputs; ArgoCD recreates
  on spec changes, `ttlSecondsAfterFinished: 600` auto-cleans

## Forgejo REST endpoints used

Verified against forgejo swagger @ v15.0.2:

| Method | Path                                        | Purpose                          |
|--------|---------------------------------------------|----------------------------------|
| GET    | `/api/v1/version`                           | Readiness probe                  |
| GET    | `/api/v1/user`                              | Admin auth check                 |
| GET    | `/api/v1/users/{user}/tokens`               | List tokens                      |
| POST   | `/api/v1/users/{user}/tokens`               | Mint token (returns plaintext once) |
| DELETE | `/api/v1/users/{user}/tokens/{name}`        | Delete token by name             |

Auth: HTTP Basic with `cluster-bootstrap:$ADMIN_PASSWORD`.

## Forgejo runner-token bootstrap (`forgejoRunner:` block)

> **Pre-req:** forgejo is deployed (phase 3) AND its admin API token has been
> minted into `crossplane-system/forgejo-admin-token` by the
> `forgejoAdmin:` bootstrap Job (phase 3.5). The runner ns `forgejo-runner`
> is rendered by `extras.forgejoRunner: true` in `apps.yaml`.

Add a `forgejoRunner:` block to a component in `apps.yaml`:

```yaml
- name: forgejo-runner
  namespace: forgejo-runner
  chart: { ... bjw-s app-template ... }
  forgejoRunner:
    enabled: true
    tokenSecretName: forgejo-runner-token       # default `forgejo-runner-token`
    adminTokenRef:
      namespace: crossplane-system              # default `crossplane-system`
      name: forgejo-admin-token                 # default `forgejo-admin-token`
      key: token                                # default `token`
    # Optional override; default http://forgejo-http.forgejo.svc:3000
    forgejoURL: http://forgejo-http.forgejo.svc:3000
```

What gets rendered (only when `enabled: true`):

| Resource         | Namespace        | Purpose                                                   |
|------------------|------------------|-----------------------------------------------------------|
| ServiceAccount   | runner ns        | Identity the bootstrap Job runs under                     |
| ConfigMap        | runner ns        | The bootstrap script (`bootstrap.sh`)                     |
| Role             | runner ns        | `secrets` get/update/patch + create (target Secret)       |
| RoleBinding      | runner ns        | Binds the SA above                                        |
| Role             | adminTokenRef ns | `secrets` `get` on the one admin-token Secret             |
| RoleBinding      | adminTokenRef ns | Lets the runner-ns SA read the admin token cross-ns       |
| Job (hashed name)| runner ns        | Calls forgejo admin API, writes target Secret             |

The Job calls `GET /api/v1/admin/runners/registration-token` (token-auth via
the admin API token) and writes the response's `token` field into the
target Secret.

Idempotence:

- Target Secret already has a non-empty `token` → exit 0, no-op
- Target Secret missing/empty → mint and write
- The forgejo registration-token endpoint is a **global** token (not
  consumed-on-use), but re-minting on every sync would churn the Secret
  needlessly — the short-circuit above prevents that. To force a re-mint,
  delete the Secret in the runner ns and let ArgoCD re-create.

## Runner architecture decision (podman sidecar, NOT dind)

The runner pod (rendered by `values/apps/forgejo-runner.yaml`) is a
two-container shape:

- `runner` — `code.forgejo.org/forgejo/runner:12.10.1`, the actual
  forgejo-runner daemon. Uses `DOCKER_HOST=unix:///run/podman/podman.sock`
  to talk to the sidecar.
- `podman` — `quay.io/podman/stable:v5.8.2`, runs `podman system service`
  to serve the docker API over a UNIX socket. Rootless (uid 1000), drops
  ALL caps, RuntimeDefault seccomp, `readOnlyRootFilesystem: true`.

**NO `privileged: true`, NO `SYS_ADMIN` cap, NO `anyuid`-equivalent.**
Restricted-PSS clean.

Why podman sidecar instead of `docker:dind`?

1. `docker:dind` requires `privileged: true` to mount overlayfs — instantly
   rejects on enterprise OCP under `restricted-v2` SCC.
2. Rootless podman serves the same docker-API surface that forgejo-runner's
   underlying `act` runtime expects, but does it without privileged or
   `SYS_ADMIN`. Storage driver `overlay` works natively on modern kernels
   (Talos here, RHEL/OCP at $work); fuse-overlayfs via the
   `kubernetes-fuse-device-plugin` is the OCP fallback (NOT `SYS_ADMIN`).
3. We never fall back to `vfs` — it works without any caps but tanks
   performance and would tank the OCP pitch story.

The homelab build doubles as the reference implementation for a parallel
pitch at $work — see `~/.agents/cluster-builder/notes/forgejo-runners-ocp-pitch.md`
for the OCP-portability constraints + the buildah-as-step "image builds
only" off-ramp.

Chart choice: the existing wrenix `forgejo-runner` chart at
`oci://codeberg.org/wrenix/helm-charts/forgejo-runner` defaults to
`securityContext.privileged: true` with a baked-in dind sidecar and has no
clean knob for a podman alternative — so we wrap with `bjw-s/app-template`
v4.6.2 (the cluster's standard non-charted-app pattern) and explicitly
declare both containers + the shared `/run/podman` emptyDir volume.

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

## Repos-as-code (`organizations:`)

> **Pre-req:** forgejo is deployed (phase 3) AND provider-gitea is installed
> + healthy in `crossplane-system` (phase 4, infra component `provider-gitea`)
> with ProviderConfig `default` pointed at `https://git.apps.home` and creds
> in `crossplane-system/forgejo-admin-token` (phase 3.5 admin-bootstrap Job).

Forgejo orgs, repos, webhooks, and collaborators are declared declaratively in
a sibling values overlay: `kubernetes/values/forgejo-orgs.yaml`. It's wired
into the apps Application via `helm.valueFiles` in
`kubernetes/bootstrap/argocd.yaml` so its top-level `organizations:` key
merges into the platform chart's `.Values` alongside `apps.yaml`'s
`components:`. The walker template
`platform/templates/forgejo-orgs.yaml` emits one Crossplane managed-resource
per item; the provider-gitea controller reconciles them into real forgejo
state.

Add an entry to `organizations:` in `kubernetes/values/forgejo-orgs.yaml`:

```yaml
organizations:
  - name: arch-err
    visibility: private                # public | limited | private
    description: "personal projects"
    repositories:
      - name: example-repo
        private: true
        defaultBranch: main
        description: ""
        # All boolean knobs default to forgejo's sensible defaults
        # (hasIssues=true, hasWiki=false, etc.) — override per-repo.
        webhooks:
          - url: https://example.invalid/hook
            type: gitea               # gitea | slack | discord | telegram
            contentType: json
            events: [push, pull_request, release]
            active: true
        collaborators:
          - user: cluster-bootstrap   # must already exist in forgejo
            permission: admin         # read | write | admin
```

See the full schema (every field + default) in
`kubernetes/values/forgejo-orgs.yaml`'s header comment.

What gets rendered (only when an item exists in `organizations:`):

| Resource                   | Scope          | API                                                     |
|----------------------------|----------------|---------------------------------------------------------|
| `Organization`             | `crossplane-system` ns | `organization.gitea.crossplane.io/v1alpha1` |
| `Repository`               | `crossplane-system` ns | `repository.gitea.crossplane.io/v1alpha1`   |
| `Webhook`                  | Cluster-scoped | `webhook.gitea.crossplane.io/v1alpha1`                  |
| `RepositoryCollaborator`   | Cluster-scoped | `repositorycollaborator.gitea.crossplane.io/v1alpha1`   |

All MRs reference `providerConfigRef.name: default`. Sync waves:
`6` (Organization) → `7` (Repository) → `8` (Webhook + RepositoryCollaborator)
so the parent resources exist before dependents try to attach.

## What ends up in forgejo

For every `organizations[i]` entry: a forgejo org with the given name +
visibility + description. For every `repositories[j]`: an empty repo on
first reconcile (with `autoInit: true` so the `defaultBranch` actually
exists). Subsequent edits to the values file roll forward into forgejo via
the provider's update-on-drift loop.

## Mirror configuration

The schema includes a `mirror:` block per repo for future-compatibility, but
**provider-gitea v0.6.0-final does NOT support mirror reconciliation** — the
Repository CRD's `spec.forProvider` has no `cloneAddr` / `mirror` / pull-mirror
fields. The values-file block is currently a NO-OP. To mirror a repo for v1:
declare the repo here (empty shell) then use forgejo UI's
"Migrate repository → From URL with mirror" as a one-time manual step.

## Idempotence + failure modes

- **Declarative end-to-end.** Edits to `organizations:` propagate via ArgoCD
  → MR spec change → provider reconcile → forgejo API call. No drift between
  Git and forgejo for the fields the provider models.
- **Re-run safe.** The provider does `GET` before `POST`/`PATCH`. Re-applying
  an unchanged spec is a no-op against forgejo.
- **Deletion.** Default `deletionPolicy: Delete` (Crossplane default) — when
  an entry is removed from the values file, ArgoCD prunes the MR, and the
  provider deletes the underlying forgejo object. To detach (keep in forgejo,
  drop from k8s state), add `deletionPolicy: Orphan` on the MR — not exposed
  in the values schema yet; raise a follow-up if needed.
- **User must exist for `RepositoryCollaborator`.** The username referenced
  here must exist in forgejo (OIDC first-login, manual admin UI). MR sits in
  `False/ReconcileError` until the user appears, then reconciles cleanly. No
  k8s-side `dependsOn`; provider re-tries on its own loop.
- **Provider down.** Crashlooping provider → MRs apply (API server accepts
  the CRs) but stay statusless. Reconcile resumes when the provider Pod is
  back up. Errors surface in `kubectl describe <kind> <name>`.

## How to add a new org/repo

1. Edit `kubernetes/values/forgejo-orgs.yaml` — add the entry under
   `organizations:`.
2. `git add kubernetes/values/forgejo-orgs.yaml && git commit -m "feat(forgejo-orgs): add <org>/<repo>" && git push origin v2`.
3. ArgoCD auto-syncs from `v2`. Within ~30s the new MR(s) land in
   `crossplane-system` (and Webhook/RepositoryCollaborator cluster-scoped).
   Provider reconciles within another ~30-60s.
4. Verify: `kubectl get organization.organization.gitea.crossplane.io
   <name> -n crossplane-system -o yaml` — `status.conditions[Ready]=True`
   means the forgejo-side object exists.

## Render-test (forgejo-orgs)

```bash
# baseline: empty organizations: list → zero MRs
helm template platform-test kubernetes/platform \
  -f kubernetes/apps.yaml -f kubernetes/values/forgejo-orgs.yaml \
  | grep -cE '^kind: (Organization|Repository|RepositoryCollaborator|Webhook)$'
  # → 0

# with overlay containing a synthetic org+repo+webhook+collaborator:
helm template platform-test kubernetes/platform \
  -f kubernetes/apps.yaml -f kubernetes/values/forgejo-orgs.yaml \
  -f /tmp/forgejo-orgs-test.yaml \
  --show-only templates/forgejo-orgs.yaml \
  | kubectl apply --dry-run=server -f -
```
