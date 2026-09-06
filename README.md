# Cluster-Config

Declarative configuration for a three-node Talos Kubernetes cluster, managed with Helm and ArgoCD.

The maintained repository is based on the former `v2` configuration. The previous `main` is preserved at the annotated tag **`archive/main-2026-09-06`** (`a502d0e`), and its history remains reachable through the promotion merge.

## Start here

- [Documentation index](docs/README.md)
- [Architecture, networking, and GitOps](docs/kubernetes.md)
- [Configured services](docs/services.md)
- [Storage and retention](docs/pvc-reclaim-policy.md)
- [Adding or re-enabling an application](docs/adding-apps.md)
- [Repository state and branch migration](docs/repository-state.md)

## Layout

| Path | Purpose |
| --- | --- |
| `talos/` | Talhelper machine configuration and encrypted Talos secrets |
| `kubernetes/bootstrap/` | Initial Cilium and ArgoCD installation values |
| `kubernetes/infra.yaml`, `kubernetes/apps.yaml` | Component lists, routes, databases, OIDC clients, and optional resources |
| `kubernetes/platform/` | Local Helm chart that renders ArgoCD Applications and supporting resources |
| `kubernetes/values/{infra,apps}/` | Per-component upstream Helm values |
| `kubernetes/secrets/{infra,apps}/` | SOPS-encrypted SopsSecret manifests |
| `kubernetes/manual/` | Setup that still requires operator input |
| `scripts/`, `justfile` | Operator commands; inspect a recipe before running it |

## Working on the repository

Use `just --list` to discover commands and `just check` for local chart rendering and shell syntax checks. These checks require Bash and Helm; they do not contact the cluster or render upstream charts.

For cluster commands, load `.envrc` with your normal direnv workflow or `source .envrc`. It selects the local generated kubeconfig and the age key path; neither is included in Git. See [secrets](docs/secrets.md) and [Talos](docs/talos.md) for prerequisites.

This cleanup changes documentation and repository branch references, **not software versions**. The live ArgoCD Git sources now follow `main` with auto-sync disabled for the [state-preserving refactor](docs/refactoring.md). Existing workload drift remains blocked; no workload sync was performed during the switch. A successful local render does not certify a clean rebuild or live health.
