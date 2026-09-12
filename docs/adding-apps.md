# Adding or re-enabling a service

Create a directory under `kubernetes/services/<service>/` for an application or under the appropriate `kubernetes/platform/<capability>/` category for a shared capability. Group supporting components, such as an OAuth proxy, with the service they support.

## Declare the service

```yaml
# kubernetes/services/example/service.yaml
owner: apps
enabled: true
components:
  - name: example
    namespace: example
    chart:
      repo: https://charts.example.org
      name: example
      version: "1.2.3"
    valuesFile: values.yaml
    route:
      hostname: example.apps.home
      gateway: apps
      service: example
      port: 8080
```

Create `values.yaml` beside the declaration using the selected upstream chart's schema. An additional proxy component can reference `oauth2-proxy.values.yaml` in the same directory. Keep existing component names and owners when reorganizing deployed services.

Specify route gateways explicitly: `apps` or `infra`. The historical template default, `internal`, is not a configured gateway. Route configuration also supports dashboard annotations and optional gRPC routing. The discarded Homepage discovery fix was not incorporated into this refactor.

## Storage and supporting resources

Put additional manifests/templates in `resources/*.yaml`. These render under the service's existing owner when `enabled: true`. The shared renderer supports the current `extras` inputs; follow a neighboring resource-only service or an existing application when extending it.

Choose storage explicitly. `local-bulk` uses retained NODE-2 storage; `local-path` has Delete reclaim policy and no replication. A database block belongs on the component:

```yaml
db:
  enabled: true
  version: "16"
  instances: 1
  storage:
    size: 10Gi
    storageClass: local-bulk
```

The CNPG operator and namespace must exist before the database can reconcile. Wire the `<component>-db-app` Secret into the application's values. Select storage explicitly; the database renderer defaults to `local-bulk`. See [storage](pvc-reclaim-policy.md).

## Identity and secrets

Complete [Pocket ID setup](../kubernetes/platform/identity/pocket-id/README.md), then add the component's `oidc` declaration:

```yaml
oidc:
  enabled: true
  callbackUrls: [https://example.apps.home/oauth/callback]
  groupRestriction:
    allowedGroups: [apps_users, administrators]
```

Use the real application callback path. The job creates the client and `<component>-oidc-client` Secret by default; `clientId` and `secretName` allow explicit overrides. App-side role mappings remain separate from IDP client restrictions.

Put SOPS-encrypted manifests in the service's `secrets/` directory. Its secret root is selected by `owner`, independently of whether the service is enabled. See [secrets](secrets.md).

## Disabled services

Set the service's `enabled` flag to false to suppress its component and extra-resource output. Retained secrets remain represented. This controls desired output; it is not permission to delete existing resources or data.

Before re-enabling a retained service, review its storage, namespaces, secrets, routes, and external dependencies. Some retained services still assume retired Kadalu storage. Shared resources have their own declarations and must be reviewed separately.

## Review

Run `just check`, validate the selected upstream chart, inspect rendered resource identities and ownership, and update the [service inventory](services.md) and service README. During this refactor, follow the [zero-diff gate](refactoring.md); adding or re-enabling a service is a runtime change requiring a separate explicit exception before synchronization.
