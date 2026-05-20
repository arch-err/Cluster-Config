# forgejo — deployment plan

handover doc for the build agent(s). target branch `v2`, ArgoCD auto-syncs.
written 2026-05-19 by cluster-builder, user-aligned on every decision below.

once the platform is green this file gets superseded by a `README.md` in the
rebuild-guide style (per `kubernetes/manual/README.md`).

---

## goals

self-hosted git platform at `git.apps.home` with:

1. forgejo (repos + LFS + built-in OCI registry + actions API)
2. **repos-as-code** via `crossplane-contrib/provider-gitea` — orgs, repos,
   webhooks, collaborators declared in YAML in this repo, reconciled by
   crossplane MRs
3. **forgejo actions** with in-cluster rootless-podman runners
4. **forgejo-pages** community daemon (defer if it resists)
5. backup-org pattern (`arch-err-github-mirror`) for pulling all github
   state local — repos via forgejo's built-in pull-mirror, ghcr/release
   artifacts via a scheduled forgejo-actions workflow running skopeo

user fills in the actual orgs/users/repos/mirror list **after** the
platform is live. this plan is platform-only.

## decisions (locked)

| # | question                | answer                                          |
|---|-------------------------|-------------------------------------------------|
| 1 | runner executor         | rootless podman sidecar (no dind, no privileged) |
| 2 | pages                   | forgejo-pages community daemon                  |
| 3 | database                | **cnpg-managed via new platform `db:` block** (postgres-only for v1; renumbered phases below) |
| 4 | initial mirror list     | empty — user fills in later                     |
| 5 | branch                  | v2 (no PR dance)                                |

**design pivot (2026-05-19, mid-build):** original plan deployed a bare
`forgejo-postgres` Deployment (phase 1, commit `ed794eb`). After hitting
initdb's POSTGRES_DB auto-create silent-fail under restricted PSS, user
greenlit a broader architectural change: install **cnpg operator** as
infra + extend platform chart with a `db:` block on app entries. Bare
postgres deploy retired (PVC discard-authorized, empty schema, zero user
data). All future stateful apps get postgres via `db: { enabled: true }`
on their apps.yaml entry — operator handles bootstrap, credentials,
HA, backups.

bonus motivation: runner pattern doubles as a reference implementation for
a parallel OCP pitch at $work. OCP-portability notes live at
`~/.agents/cluster-builder/notes/forgejo-runners-ocp-pitch.md` — keep the
podman path scc-clean on the homelab build so it ports.

---

## architecture

```
                            ┌─────────────────────┐
                            │ pocket-id           │
                            │ auth.apps.home      │
                            └─────────┬───────────┘
                                      │ OIDC (platform `oidc:` block →
                                      │  bootstrap job writes secret)
                                      ▼
   ┌─────────────────┐    ┌───────────────────────┐    ┌──────────────────────┐
   │ user            │───▶│ forgejo               │◀──▶│ cnpg Cluster         │
   │ browser / git / │    │ git.apps.home         │    │ (rendered by platform │
   │ docker / oci    │    │ - repos / LFS         │    │  `db:` block, mgr by  │
   └─────────────────┘    │ - OCI registry        │    │  cnpg operator infra) │
                                                       └──────────────────────┘
                          │ - actions API         │
                          └──────┬──────────┬─────┘
                                 │          │ register runner via token
                                 │          ▼
                                 │     ┌──────────────────────────────┐
                                 │     │ forgejo-runner deploy        │
                                 │     │ + rootless podman sidecar    │
                                 │     │ (docker socket over emptyDir)│
                                 │     └──────────────────────────────┘
                                 │
                                 │ admin API token (bootstrap job → cross-ns secret)
                                 ▼
                          ┌────────────────────────┐    ┌──────────────────┐
                          │ provider-gitea         │───▶│ Organization /   │
                          │ (crossplane provider)  │    │ Repository MRs   │
                          └────────────────────────┘    │ in this repo     │
                                                        └──────────────────┘

                          ┌────────────────────────┐
                          │ forgejo-pages          │
                          │ pages.apps.home/<repo> │
                          │ serves `pages` branch  │
                          └────────────────────────┘
```

---

## phases

each phase = one or more single-line conventional commits. don't merge a
phase that doesn't reconcile green. straight to `v2` per the solo-dev
convention.

### phase 1 — cnpg operator (NEW)

- new infra component. chart: `cnpg/cloudnative-pg` (apache 2.0), pin
  latest stable
- new file `kubernetes/values/infra/cnpg.yaml`, entry in `infra.yaml`
- chart creates its own `cnpg-system` ns; operator pod runs non-root by
  default — restricted-PSS clean out of the box (verify before merge)
- no providers/operands installed yet — phase 2 adds the first cnpg
  `Cluster` CR for forgejo
- verification: operator pod 1/1, CRD `clusters.postgresql.cnpg.io`
  registered, `kubectl get crd | grep cnpg` shows expected set

### phase 2 — platform `db:` block + retire bare forgejo-postgres (NEW)

Two things in one phase because they're load-bearing on each other.

**A. platform chart extension:**

- new template `kubernetes/platform/templates/db-postgres.yaml` walking
  the components list, emitting one cnpg `Cluster` CR per entry with
  `db.enabled: true`
- schema added to apps.yaml entries (postgres-only for v1, kept under
  generic `db:` key to leave design space for future types without
  refactor):
  ```yaml
  db:
    enabled: true
    version: "16"
    storage: { size: 20Gi, storageClass: kadalu.replica2-retain }
    instances: 1                        # bump to 2+ for HA later
    # cnpg auto-mints <app>-db-app Secret with keys:
    #   username, password, host, port, dbname, uri, jdbc-uri, pgpass
    # app refs via envFrom or specific keys
  ```
- cnpg `Cluster` rendered in the same ns as the app component;
  ownership / sync-wave aligns so the DB lands before the app pod
- platform/README.md gets a new section documenting the block (mirror
  the OIDC block docs in style)

**B. retire bare forgejo-postgres (destructive — user pre-authorized):**

- DELETE `kubernetes/values/apps/forgejo-postgres.yaml`
- DELETE `kubernetes/secrets/apps/forgejo-db.yaml`
- REMOVE `forgejo-postgres` component from `kubernetes/apps.yaml`
- KEEP the `forgejo` ns block in `platform/templates/extras.yaml`
  (still needed for phase 3)
- after ArgoCD prunes, `kubectl delete pvc forgejo-postgres -n forgejo`
  then `kubectl delete pv pvc-42efd9d6-8cc7-400c-9c46-1b9ff9dfd085`
  (PV is Released w/ Retain — manual delete required). zero user data
  on it (empty `forgejo` DB created via `psql`, never connected to)

### phase 3 — forgejo

- chart: `codeberg/forgejo` (codeberg helm registry), pin minor
- values: `kubernetes/values/apps/forgejo.yaml`
- knobs:
  - `gitea.config.database.*` from cnpg-rendered `forgejo-db-app` secret
    via envFrom (keys: `username`, `password`, `host`, `port`, `dbname`
    — forgejo chart wants `DB_TYPE`/`HOST`/`NAME`/`USER`/`PASSWD`, map
    via specific envvar references not bulk envFrom)
  - `gitea.config.server.ROOT_URL=https://git.apps.home`,
    `DOMAIN=git.apps.home`
  - **SSH future-proofing** (v1 doesn't expose SSH externally, but the
    pod/service shape lands NOW so the flip is purely a Gateway change):
    - `gitea.config.server.START_SSH_SERVER=true` (built-in Go SSH server,
      default — keep it on)
    - `gitea.config.server.SSH_PORT=22` (advertised port in clone URLs —
      `git@git.apps.home:org/repo.git`. stable from day 1 so no URL churn
      when SSH flips on)
    - `gitea.config.server.SSH_LISTEN_PORT=2222` (actual pod-side port,
      unprivileged)
    - `gitea.config.server.SSH_DOMAIN=git.apps.home`
    - host keys live on the persistent volume (forgejo default —
      `/data/ssh/`). verify the chart places them there and NOT in
      emptyDir, otherwise host-key churn on every pod restart
    - **Service shape**: forgejo Service exposes port `ssh` (22) →
      targetPort `2222`. ClusterIP, no NodePort, no LoadBalancer.
      future TCPRoute attaches to this Service:22
    - **explicit non-goals for v1**: NO Gateway listener on :22, NO
      TCPRoute, NO NodePort hack. flip is documented in a follow-up note
      below. UI clone URLs will SHOW `git@…` but it won't be reachable
      until the flip — users use HTTPS clone (also shown in UI) for v1
  - `gitea.config.packages.ENABLED=true` (built-in OCI registry)
  - `gitea.config.actions.ENABLED=true`
  - `gitea.config.service.DISABLE_REGISTRATION=true`
  - `gitea.config.service.REQUIRE_SIGNIN_VIEW=true`
  - `gitea.config.oauth2_client.*` from `forgejo-oidc-client` secret
    written by the platform's oidc-bootstrap job
  - `postgresql.enabled=false`, `redis-cluster.enabled=false`
    (re-enable redis later if perf demands it)
  - `persistence.enabled=true`, **SC `kadalu.replica2-retain`**, 100 GiB
    (holds repos + LFS + registry blobs)
- `apps.yaml` entry, including:
  ```yaml
  - name: forgejo
    namespace: forgejo
    chart: { repo: https://code.forgejo.org/forgejo-helm, name: forgejo, version: <pin> }
    route: { host: git.apps.home, port: 3000 }
    oidc:
      enabled: true
      callbackUrls: [ https://git.apps.home/user/oauth2/pocket-id/callback ]
      secretName: forgejo-oidc-client
    db:
      enabled: true
      version: "16"
      storage: { size: 20Gi, storageClass: kadalu.replica2-retain }
      instances: 1
  ```
- restricted-PSS clean. forgejo image runs uid 1000 by default. cnpg
  operator handles its own pod's PSS posture in cnpg-system ns; the
  `Cluster`-spawned postgres pods land in the app's ns (`forgejo`) and
  need to be restricted-PSS-compatible. cnpg defaults are restricted-clean
  but verify in phase 1.

### phase 3.5 — first-admin + API token bootstrap

mirror the pocket-id pattern. forgejo's install wizard runs once on first
boot when the DB is empty.

- manual step (becomes a README step post-deploy): browse `git.apps.home`,
  walk install wizard, create `cluster-bootstrap` admin user using the
  password in SOPS secret `forgejo-admin-bootstrap` — keep this in
  `kubernetes/secrets/apps/` so it's reproducible
- automated step: a hashed-name job in the platform chart
  (`templates/forgejo-admin-bootstrap.yaml`) that
  - waits for `/api/v1/version` 200
  - mints an API token via `POST /api/v1/users/cluster-bootstrap/tokens`
    named `crossplane` with scope `admin`, idempotent (list first,
    reuse the existing cluster-side secret if a `crossplane` token already
    exists)
  - writes secret `forgejo-admin-token` into **`crossplane-system` ns**
    (where the provider lives)
  - SA + Role in crossplane-system narrowed to that one secret
- structure should mirror `templates/oidc-bootstrap.yaml`. gate on a new
  top-level `forgejoAdmin:` block in `apps.yaml` so it's opt-in

### phase 4 — provider-gitea

- install via crossplane Provider CR + ProviderConfig
- recommend a new file: `kubernetes/values/infra/provider-gitea.yaml`
  emitting the two CRs (Provider + ProviderConfig), wired into
  `infra.yaml` as a new component
- pin provider version to a known release
- **TLS trust gotcha** — provider pod must trust home-ca. preferred path:
  `DeploymentRuntimeConfig` mounting the home-ca-bundle ConfigMap (managed
  by trust-manager) into the provider pod's ca-certificates path.
  fallback: `insecure: true` on the ProviderConfig (works but smells).
  validate the runtime-config path on the actual provider image first;
  this is the same flavor of trust hurdle as the booklore JVM truststore
  (see commit `a4ff45d`)
- verification: provider HEALTHY in `kubectl get providers.pkg.crossplane.io`;
  apply a hand-rolled `Organization` MR for `arch-err`, watch it reconcile,
  see the org in the forgejo UI within 60s

### phase 5 — repos-as-code schema

- new file: `kubernetes/values/forgejo-orgs.yaml` (sibling of `apps.yaml`)
- new template: `kubernetes/platform/templates/forgejo-orgs.yaml` walking
  the `organizations:` list and emitting crossplane MRs
- starter schema (user fills in later — empty lists OK):
  ```yaml
  organizations:
    - name: arch-err
      visibility: private
      description: "personal projects"
      repositories:
        - name: example-repo
          private: true
          defaultBranch: main
          mirror:
            enabled: false
            cloneAddr: ""
            interval: "24h"
            credentialsSecret: ""
          webhooks: []
          collaborators: []

    - name: arch-err-github-mirror
      visibility: private
      description: "read-only pull-mirrors of github upstream"
      repositories: []
  ```
- render-test:
  ```bash
  helm template platform-test kubernetes/platform \
    -f kubernetes/apps.yaml -f kubernetes/values/forgejo-orgs.yaml \
    | kubectl apply --dry-run=server -f -
  ```
- before writing the template, **verify the resource kinds available in the
  pinned provider version** — `Organization`, `Repository`, `Webhook`,
  `RepositoryCollaborator` are the baseline; `BranchProtection` and
  `RepositoryFile` may or may not exist depending on version. document the
  available kinds in the values-file header

### phase 6 — forgejo-runner (rootless podman)

- new ns `forgejo-runner` (separate ns keeps blast radius small + lets
  the PSS posture stay narrow). restricted-PSS clean — no `privileged`,
  no `anyuid`-equivalent
- chart: `codeberg/forgejo-runner` if it accepts the sidecar block cleanly,
  else bjw-s app-template wrapping the runner + podman containers in one
  pod. verify chart values surface area first — bjw-s wrap is the fallback
- pod shape (single replica to start, scale once stable):
  ```
  pod
  ├── init: register runner against forgejo API using a one-shot
  │         registration token (minted by sibling job, written to secret
  │         forgejo-runner-token in forgejo-runner ns)
  ├── container: forgejo-runner
  │   - env DOCKER_HOST=unix:///run/podman/podman.sock
  │   - volumeMount /run/podman shared
  └── sidecar: podman
      - image quay.io/podman/stable
      - command: podman system service --time=0 unix:///run/podman/podman.sock
      - volumeMount /run/podman shared
      - storage driver: overlay (kernel overlay native; if blocked, try
        fuse-overlayfs via /dev/fuse exposure; never fall back to vfs as v1
        target — too slow, would tank the OCP pitch)
      - runtime: crun
      - runAsNonRoot, drop ALL caps, RuntimeDefault seccomp
  ```
- registration token: second hashed-name bootstrap job
  (`platform/templates/forgejo-runner-bootstrap.yaml`), hitting
  `POST /api/v1/admin/runners/registration-token` with the admin token
  from phase 3.5. writes `forgejo-runner-token` secret into `forgejo-runner` ns
- resource floor: runner 500m / 1Gi, podman 1000m / 2Gi. revisit after first
  real CI job
- **smoke test workflow** to validate before declaring phase done: a tiny
  `.forgejo/workflows/smoke.yml` in a test repo that runs
  `runs-on: docker` (default), `uses: actions/checkout@v4`, `run: echo hi`
  inside an alpine container. if alpine spins up in the podman sidecar
  and exits 0, the executor works
- **second smoke test**: a buildah-in-host-executor workflow that builds a
  hello-world Dockerfile and pushes to `git.apps.home/<user>/test:latest` —
  proves the registry-push path works without the podman sidecar at all
  (the "image builds only" off-ramp from the OCP notes)

### phase 7 — forgejo-pages

- community `forgejo-pages` daemon serves any repo's `pages` branch at
  `pages.apps.home/<owner>/<repo>/`
- no official helm chart → wrap with bjw-s app-template
  (`kubernetes/values/apps/forgejo-pages.yaml`)
- needs read-only forgejo token → third bootstrap job minting a scoped
  token, secret `forgejo-pages-token` in `forgejo` ns
- hostname `pages.apps.home`, HTTPRoute via platform chart `route:` block
- **defer if it resists** — pages is the most experimental piece. ship
  phases 1-6 first, circle back. user pre-agreed

### phase 8 — github backup workflow (post-platform, user-driven)

NOT built by the build agent. listed for completeness.

once the user fills in `forgejo-orgs.yaml` with the actual GH mirror list:

- repo mirrors handled by forgejo's pull-mirror cron (per-repo
  `mirror.enabled: true`)
- ghcr images + github release artifacts: a `arch-err-github-mirror/mirror-jobs`
  repo with a nightly `.forgejo/workflows/mirror.yml` running `skopeo sync`
  and `gh release download && tea release create`
- secrets: `GITHUB_TOKEN` (read-only PAT) + forgejo admin token

---

## secrets inventory

| secret                       | ns                  | source                     | used by                      |
|------------------------------|---------------------|----------------------------|------------------------------|
| `forgejo-db-app`             | `forgejo`           | cnpg operator (auto-minted)| forgejo (DB creds)           |
| `forgejo-oidc-client`        | `forgejo`           | platform oidc-bootstrap job| forgejo (auth config)        |
| `forgejo-admin-bootstrap`    | `forgejo`           | SOPS                       | install-wizard password (manual step) |
| `forgejo-admin-token`        | `crossplane-system` | forgejo-admin-bootstrap job| provider-gitea ProviderConfig|
| `forgejo-runner-token`       | `forgejo-runner`    | runner-bootstrap job       | runner registration          |
| `forgejo-pages-token`        | `forgejo`           | pages-bootstrap job        | forgejo-pages daemon         |

all SOPS-encrypted secrets follow the existing `kubernetes/secrets/apps/`
pattern (isindir.github.com/v1alpha3 SopsSecret, age recipient already
configured).

---

## data destruction discipline

- every PVC in phases 1+2 lands on **`kadalu.replica2-retain` SC** — CRITICAL
  tier (git history + DB are user data). do NOT use the default
  `kadalu.replica2` SC for these
- if any agent encounters an existing PVC that needs to be replaced (e.g.
  schema change demanding StatefulSet rename), per-PVC `preserve | discard`
  call required from user before any destructive action — per the hard
  rule in identity.md
- no `kubectl delete pvc` or namespace teardown without re-verifying

## verification

phase is "done" when:

- [ ] phase 1: cnpg operator pod 1/1 in `cnpg-system`, `clusters.postgresql.cnpg.io` CRD present
- [ ] phase 2: bare `forgejo-postgres` retired (no Deployment / PVC / PV);
      `db-postgres.yaml` platform template render-tests clean with both
      empty + synthetic `db: enabled` component fixtures
- [ ] phase 3: `https://git.apps.home` loads, install wizard reachable;
      cnpg-managed postgres pod 1/1 in `forgejo` ns; `forgejo-db-app`
      secret materialized
- [ ] phase 3.5: `cluster-bootstrap` admin exists; `forgejo-admin-token`
      secret present in `crossplane-system` ns
- [ ] phase 4: `kubectl get providers.pkg.crossplane.io provider-gitea`
      HEALTHY; test `Organization` MR reconciles within 60s
- [ ] phase 5: `helm template … | kubectl apply --dry-run=server` clean
      with empty `organizations:` list (no MRs emitted)
- [ ] phase 6 smoke A: alpine `echo hi` workflow exits 0 with logs in UI
- [ ] phase 6 smoke B: buildah workflow pushes image to
      `git.apps.home/<user>/test:latest`, image pullable from runner pod
- [ ] phase 7: `pages.apps.home/<user>/<test-repo>/` serves a static HTML
      from the `pages` branch of the test repo

oidc redirect chain: `curl -skI https://git.apps.home/` → 302 to
`auth.apps.home/authorize?client_id=forgejo` with PKCE S256.

## open questions for the build agent

resolve during implementation, no need to block on user:

1. **postgres chart pattern** — match cluster convention (bjw-s wrap is the
   prevailing one) over going straight to bitnami/postgresql. verify what
   the immich postgres / booklore mariadb wraps look like and follow.
2. **provider-gitea version pin** — pick latest stable from
   `crossplane-contrib/provider-gitea` releases, document the resource
   kinds available in that version in the values-file header.
3. **TLS trust path** — DeploymentRuntimeConfig with CA bundle mount first;
   `insecure: true` only as documented fallback if that path is blocked.
4. **runner storage driver** — overlay → fuse-overlayfs → bail if both
   require privileged or anyuid. don't ship with vfs (kills the OCP pitch).
5. **forgejo-runner chart vs bjw-s wrap** — check codeberg's chart first;
   if its values don't cleanly express the podman sidecar shape, fall
   back to bjw-s.

## phase 5 surfaced limitations (provider-gitea v0.6.0-final)

discovered during phase 5 schema build — not blockers for phase 5 itself
(schema is forward-compatible) but the user should know:

1. **No mirror support on Repository CRD.** v0.6.0-final's
   `Repository.spec.forProvider` does NOT expose `cloneAddr` /
   `mirror` / pull-mirror fields. The `mirror:` block in
   `kubernetes/values/forgejo-orgs.yaml`'s schema is a reserved slot,
   currently no-op. For v1: declare repo as empty shell, then use
   forgejo UI's Migrate-from-URL flow as a manual step. Revisit when
   provider-gitea lands mirror reconciliation (track upstream).
2. **Webhook secret is plaintext-only.** `Webhook.spec.forProvider.secret`
   is a string field — no `secretRef:` indirection. Template leaves it
   commented; set via UI/API post-apply if needed.
3. **RepositoryCollaborator user-must-exist ordering.** Provider has no
   User MR for OIDC-backed users (only AdminUser for password-auth). A
   collaborator referenced before the user has logged in via pocket-id
   leaves the MR in ReconcileError; auto-recovers once user appears.
4. **Provider crashloop encountered 2026-05-20.** The phase-4 provider
   install at commit `12ffb0b` was healthy at commit time, but during
   phase 5 live smoke test the controller was found CrashLoopBackOff
   with `failed to wait for managed/accesstoken caches to sync: timed
   out waiting for cache to be synced for Kind *v1alpha1.AccessToken`.
   No `accesstokens.accesstoken.gitea.crossplane.io` CRD installed even
   though the controller expects one. Render-tests + server-side
   dry-run apply ALL passed (CRDs accept the four kinds this template
   emits); reconciliation cannot complete until the provider Pod is
   back up. Outside phase-5 scope — needs phase-4 investigation
   (possibly resolved by the in-flight arch-err/provider-gitea fork +
   image mirror).

## manual steps that stay manual (extract to README later)

1. install wizard → create `cluster-bootstrap` admin with SOPS-stored pw
2. link OIDC identity to admin user (one-time login via pocket-id)
3. fill in `forgejo-orgs.yaml`
4. branch protection / merge style / other per-repo settings the provider
   doesn't cover yet — list discovered gaps in the README as they surface

## post-v1: enabling SSH on :22

NOT done by the build agent. for when the user wants `git@git.apps.home:…`
working. all forgejo-side config landed in phase 3 — this is pure gateway
work:

1. add a TCP listener on port 22 to the apps Gateway (verify Cilium
   gatewayClass supports TCPRoute — it does as of Cilium 1.15+)
2. add a `TCPRoute` in `forgejo` ns pointing at Service `forgejo:22`
3. confirm `nc -v git.apps.home 22` returns the SSH banner from outside
4. `ssh-keyscan git.apps.home` returns the host keys from the PVC
5. existing clone URLs already advertised by the UI just start working —
   no forgejo restart, no URL update, no user-facing churn
