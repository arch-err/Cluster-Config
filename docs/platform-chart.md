# Platform chart

The local chart in [kubernetes/platform](../kubernetes/platform/) renders the desired GitOps resources from two value sets: [infra.yaml](../kubernetes/infra.yaml) and [apps.yaml](../kubernetes/apps.yaml).

## Inputs

- `repoURL`, `targetRevision`, `valuesPath`: Git source and the per-component values directory.
- `components`: upstream Helm charts with optional namespace, sync wave, route, database, and OIDC configuration.
- `disabledComponents`: suppresses a component's Application, routes, database, and OIDC bootstrap resources.
- `extras`: switches and settings for supporting platform resources.
- `disabledExtras`: masks named extras separately from component enablement.

Values are loaded as `$repo/{valuesPath}/{component.name}.yaml`. Namespace defaults to component name. Upstream chart revision defaults to `*` if omitted; preserve existing revisions during this cleanup and make revision choices explicit for new components.

## Templates

| Template | Responsibility |
| --- | --- |
| `applications.yaml` | Child Applications, chart/value sources, sync options, diff exclusions |
| `httproutes.yaml` | HTTPRoutes, optional GRPCRoutes, dashboard annotations |
| `extras.yaml` | Gateways, certificates, CoreDNS, static storage, namespaces, and app-specific supporting resources |
| `db-postgres.yaml` | CloudNativePG Cluster declarations for enabled `db` blocks |
| `oidc-bootstrap.yaml` | Pocket ID registration jobs and cross-namespace credential access |

For route, database, and OIDC usage, see [adding applications](adding-apps.md). Keep app-specific Helm settings in their values files instead of expanding the meta-chart unnecessarily.

## Important boundaries

Disabling a component and disabling its extras are separate operations. Existing data can remain after resources stop rendering. Review every affected resource and PVC when retiring or re-enabling a service.

The database template still defaults to the retired `kadalu.replica2-retain` StorageClass. Active Grafana and n8n explicitly select `local-bulk`; new database declarations must select an appropriate class rather than inherit that legacy default.

OIDC registration depends on a manually supplied Pocket ID API token. Group restrictions are declarative through `oidc.groupRestriction.allowedGroups`; manual changes to the corresponding client allowlist are overwritten when the job runs. App-side role mappings remain in each app's configuration.

See [Kubernetes](kubernetes.md) for reconciliation limitations and [repository state](repository-state.md) for deferred fixes.

## Validation

```sh
just check
helm template infra kubernetes/platform -f kubernetes/infra.yaml
helm template apps kubernetes/platform -f kubernetes/apps.yaml
```

These render the local chart only. Upstream chart values/schema checks, live API validation, sync ordering, and rebuild testing are separate checks.
