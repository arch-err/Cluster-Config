# Public Pocket ID

Pocket ID at `https://auth.3rr.dev` is the independent identity provider for
Internet-facing services. It deliberately shares no users, passkeys, groups,
database, encryption key, or API credentials with the internal instance at
`https://auth.apps.home`.

The deployment uses Pocket ID v2.14.0 through the immutable Anza Labs chart
v2.2.1. Both versions are pinned, and the application image is additionally
pinned by its multi-architecture OCI digest.

## Storage and failure model

SQLite and uploaded assets use a 1 GiB `local-path-retain` PVC on one node's
internal NVMe storage. `WaitForFirstConsumer` lets the scheduler choose the
initial node; the resulting local PV then keeps the StatefulSet on that node.
The StorageClass and StatefulSet retain the data if the claim or workload is
removed, but they do not provide replication. A failed node makes public login
unavailable until the node returns or the data is restored elsewhere.

## First enrollment

Wait for the Application, StatefulSet, PVC, HTTPRoute, and generated Secret to
be healthy. Then visit `https://auth.3rr.dev/setup` and create the initial `J`
administrator with a passkey. Application configuration is persisted in the
SQLite database and editable through the admin UI. Leave user signups disabled
and create users only on demand.

Create these initial groups in the Pocket ID UI:

- `users` for ordinary application access
- `administrators` for applications that support administrator role mapping

Add J to both groups. Groups describe access tiers, not individual apps; add a
narrower group only when an application genuinely has a different audience.

## API token for future client integration

Client registration is intentionally outside this deployment. When an
integration is ready, create a scoped Pocket ID API key and store it as a
regular Kubernetes Secret in this namespace. Do not reuse the internal Pocket
ID token.

```sh
read -rs POCKET_ID_PUBLIC_API_TOKEN
kubectl -n pocket-id-public create secret generic pocket-id-public-api-token \
  --from-literal=POCKET_ID_API_TOKEN="$POCKET_ID_PUBLIC_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
unset POCKET_ID_PUBLIC_API_TOKEN
```

## Verification

Before adding clients, verify:

```sh
kubectl -n pocket-id-public rollout status statefulset/pocket-id-public
kubectl -n pocket-id-public get pvc,pod,service,httproute
curl -fsS https://auth.3rr.dev/healthz
curl -fsS https://auth.3rr.dev/.well-known/openid-configuration | jq .issuer
```

The issuer must be exactly `https://auth.3rr.dev`. Verify passkey login in a
fresh browser session and preserve recovery material plus a database backup
outside the cluster before relying on this instance for public services.
