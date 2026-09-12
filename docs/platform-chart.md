# Source layout and Helm rendering

The repository uses one source Helm chart at [kubernetes/](../kubernetes/README.md). That chart describes the existing ArgoCD Applications and supporting resources; upstream application charts remain separate child sources.

## Service directories

```text
kubernetes/services/booklore/
├── service.yaml
├── values.yaml
├── oauth2-proxy.values.yaml
├── resources/
│   └── booklore.yaml
└── secrets/
    ├── booklore-db.yaml
    └── booklore-oauth2-cookie.yaml
```

`service.yaml` contains:

- `owner`: `apps` or `infra`, preserving the current Argo parent regardless of folder location.
- `enabled`: explicit boolean controlling all components and supporting resources in this directory.
- `components`: the existing component declarations, including chart coordinates, routes, database/OIDC blocks, and a relative `valuesFile` per component.
- `extras`: service-specific resource inputs retained from the previous meta-chart. Their templates now live in the service's `resources/` directory.

A service may contain only supporting resources, with no upstream Helm component. Related charts share a service directory. Shared namespaces, gateways, and storage have explicit platform homes.

## Rendering

The root value files in `kubernetes/releases/` select `owner` and either `render: resources` or `render: secrets`. They also retain small owner-wide network/storage settings. Common repository URL and revision defaults live in `kubernetes/values.yaml`.

`templates/_context.tpl` validates declarations and assembles the input expected by the shared renderers. It rejects duplicate component names, invalid owners/enablement, duplicate extra keys for an owner, and missing values files. Component values paths resolve relative to `service.yaml` and become `$repo/kubernetes/<service-directory>/<values-file>` in the child Application.

`templates/render.yaml` invokes shared Application, route, database, and OIDC renderers, then renders each enabled service's resource files through Helm `tpl`. These files can use the existing `.Values.extras` and root-wide settings without moving resource ownership. Document order is not resource identity; sync waves remain explicit in manifests.

**Disabled services retain their secrets.** Secret-root rendering copies `secrets/*.yaml` unchanged for the selected owner, independently of `enabled`. This preserves the old separate secret-root behavior. It does not prove that a retained namespace or PVC currently exists.

`reference/` files and static assets are excluded from Helm. The historical CA copy is deliberately under a `reference/` directory rather than a managed `secrets/` directory.

## Boundaries preserved by the refactor

Application names, Helm release names, namespaces, resource identities, chart/image versions, and root ownership stay unchanged. Moving a service under `platform/` does not transfer it between `apps` and `infra`. Both old root Applications and both secret roots remain in use.

The database renderer defaults to `local-bulk`; new declarations should select storage explicitly. Runtime behavior changes, ownership transfers, re-enablement, and policy changes are separate work subject to the [zero-diff rule](refactoring.md).

## Validation

```sh
just check
helm template apps kubernetes -f kubernetes/releases/apps.yaml
helm template infra kubernetes -f kubernetes/releases/infra.yaml
```

The local check also renders both secret roots and tests enablement behavior. It does not validate upstream chart schemas, live API behavior, or a clean cluster rebuild. Before a workload sync, use the complete live comparison process in the refactoring protocol.
