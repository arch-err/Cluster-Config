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

Requires Bash, Helm, yq (Mike Farah's Go implementation), and Python 3's standard library. Checks render all four roots, validate resource identities/source paths/manual-sync policy, exercise service enablement, and check shell syntax. They do not contact the cluster or render upstream charts.

## Current migration rule

All 65 live Applications use this repository's `main` branch with auto-sync off. **No workload sync with unapproved differences.** See [refactoring rules and baseline](docs/refactoring.md). Software versions and runtime behavior are preserved; existing baseline drift remains blocked.

The old `main` is preserved by `archive/main-2026-09-06`. The `v2` branch remains available because deployed Grafana and Homepage consumers still reference its files. See [repository state](docs/repository-state.md).
