# Adding or re-enabling applications

Choose `kubernetes/apps.yaml` for user services or `kubernetes/infra.yaml` for platform services. Each component's upstream chart values live at `kubernetes/values/<scope>/<name>.yaml`.

## Component and route

A minimal example (replace the chart coordinates with the selected chart):

```yaml
components:
  - name: example
    namespace: example
    chart:
      repo: https://charts.example.org
      name: example
      version: "1.2.3"
    route:
      hostname: example.apps.home
      gateway: apps
      service: example
      port: 8080
```

Create the matching `kubernetes/values/apps/example.yaml` using that chart's schema. Prefer explicit chart revisions. Set `route.gateway` explicitly to `apps` or `infra`; the template's historical default, `internal`, is not one of the currently configured gateways.

The route template also supports `route.grpc` and `route.dashboard`. Dashboard visibility defaults to the apps gateway; infra routes need an explicit dashboard opt-in. Homepage admin discovery has an outstanding fix (PR #4); see [repository state](repository-state.md).

## Storage

Select persistence explicitly. `local-bulk` provisions retained data on NODE-2's external disk. `local-path` provisions node-local data under `/opt/local-path-provisioner` with `Delete` reclaim policy. Neither provides storage replication.

For a CNPG database, add a `db` block to the component and wire the generated `<component>-db-app` Secret into the app's values:

```yaml
db:
  enabled: true
  version: "16"
  instances: 1
  storage:
    size: 10Gi
    storageClass: local-bulk
```

The database template renders `<component>-db` with database/owner named after the component. Its version-to-image map is in `db-postgres.yaml`. The CNPG operator and namespace must exist before the Cluster resource can reconcile. Do not rely on the legacy default StorageClass; see [storage](pvc-reclaim-policy.md).

## Identity

For OIDC, first complete [Pocket ID bootstrap](../kubernetes/manual/pocket-id/README.md), then add:

```yaml
oidc:
  enabled: true
  callbackUrls:
    - https://example.apps.home/oauth/callback
  groupRestriction:
    allowedGroups: [apps_users, administrators]
```

Use the application's actual callback path. The job writes `client_id`, `client_secret` (confidential clients), and `issuer_url` to `<component>-oidc-client` by default. `clientId` overrides the registration identity and default Secret prefix; `secretName` overrides the Secret name. Other supported inputs include `public`, `pkceEnabled`, `logoutCallbackUrls`, and `scopes`.

The job reconciles the Pocket ID client allowlist by group name. Empty or omitted `allowedGroups` makes the client unrestricted at the IDP. App-side permissions and role mappings are separate; configure them in the application's values or manual setup notes.

## Disabled services

A retained values file does not mean an application is deployed. Check both `disabledComponents` and `disabledExtras`. Several disabled services still reference retired Kadalu storage or old integrations. Before re-enabling one, review its storage, secrets, routes, prerequisites, and preserved data. Do not remove disable flags as a bulk cleanup.

## Review and publish

1. Run `just check` and inspect both rendered configurations.
2. Validate the upstream chart with the selected version and values; the local chart check only renders the child Application reference.
3. Review resource deletion, PVC ownership, routing, and authentication changes.
4. Update the [service inventory](services.md) and relevant manual setup notes.
5. Commit and publish to the branch the root Applications track. During migration, follow [repository state](repository-state.md).

Changing desired state is distinct from confirming a successful deployment: inspect ArgoCD status and the affected workloads after reconciliation.
