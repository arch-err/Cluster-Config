# Cluster-Config

Talos Kubernetes configuration managed with Helm and ArgoCD. Sources are grouped by service; deployed resource ownership is explicit and independent of the folder layout.

```text
.
├── docs/                       # Architecture and cluster-wide runbooks
├── scripts/                    # Operator commands and validation
├── talos/                      # Machine configuration and encrypted Talos secrets
├── justfile
└── kubernetes/                 # One source Helm chart
    ├── Chart.yaml
    ├── values.yaml             # Repository source defaults
    ├── releases/               # Selectors/settings for the four existing Argo roots
    ├── templates/              # Shared Applications, routes, database, OIDC rendering
    ├── bootstrap/              # Initial Cilium and ArgoCD installation
    ├── services/               # Booklore, Home Assistant, n8n, etc.
    └── platform/               # GitOps, networking, identity, storage, observability
```

Each service directory contains a `service.yaml` declaration and, as needed, Helm values, `resources/`, encrypted `secrets/`, assets, and a README. Supporting components such as an OAuth proxy share the service directory. There is no separate chart per service or build-time manifest generator.

Start with the [documentation index](docs/README.md), [source layout](docs/platform-chart.md), [service inventory](docs/services.md), and [adding services](docs/adding-apps.md).

## Validate locally

```sh
just check
```

Requires Bash, Helm, yq (Mike Farah's Go implementation), and Python 3's standard library. Checks render all four roots, validate resource identities/source paths, pinned chart versions, and automation/deletion guards, exercise service enablement, and check shell syntax. They do not contact the cluster or render upstream charts.

## Current GitOps policy

All 47 live Applications use this repository's `main` branch with auto-sync and self-healing enabled. **Automatic pruning is off; deletion guards remain.** Reviewed changes pushed to `main` can deploy automatically. Chart versions are pinned to the verified deployed versions, and Gateway API specs are visible in diffs. See [operating policy and migration history](docs/refactoring.md).

The old `main` is preserved by `archive/main-2026-09-06`. The former `v2` baseline is preserved by `archive/v2-2026-09-14`; Grafana and Homepage now fetch their files from `main`. See [repository state](docs/repository-state.md).
