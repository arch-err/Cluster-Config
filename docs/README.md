# Documentation

The documents describe committed configuration, not a live cluster inventory. The production baseline for this cleanup is `v2` at `1688b23` (2026-09-06 review); no software upgrades are part of it.

| Guide | Covers |
| --- | --- |
| [Kubernetes](kubernetes.md) | Network, gateways, GitOps ownership, and operational checks |
| [Configured services](services.md) | Enabled and disabled components from the committed configuration |
| [Talos](talos.md) | Nodes, generation, bootstrap boundaries, and host storage |
| [Platform chart](platform-chart.md) | Chart inputs, templates, and reconciliation behavior |
| [Adding applications](adding-apps.md) | Values, routing, identity, storage, and validation |
| [Secrets](secrets.md) | SOPS/age and generated or manually supplied credentials |
| [Storage](pvc-reclaim-policy.md) | Local storage, retained data, and legacy configuration |
| [Backup status](backup-manual.md) | Existing script limitations and recovery requirements |
| [Repository state](repository-state.md) | Archive, branch dispositions, cutover, and known gaps |
| [Manual setup](../kubernetes/manual/README.md) | Pocket ID, ArgoCD, Jellyfin, and CoreDNS notes |

Keep operational details next to the YAML that owns them. Link to configuration instead of copying large manifests into documentation; update this index when adding a runbook.
