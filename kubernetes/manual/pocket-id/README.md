# Pocket ID manual setup

Pocket ID is the identity provider at `https://auth.apps.home`. Helm settings live in `kubernetes/values/apps/pocket-id.yaml`; the configured existing claim is `pocket-id-local`. Its database contains identity/enrollment state that cannot be reconstructed from Git alone.

## First enrollment

After restoring or deploying Pocket ID, verify its persistent data before initiating a new setup. For an empty installation, use `/setup` to enroll the first administrator with a passkey. Preserve administrator recovery access outside the cluster.

## Bootstrap API token

Create an API token with the access required by the platform job to manage OIDC clients and resolve user groups. Store it in your password manager. It is intentionally supplied as a regular Kubernetes Secret, not committed to this repository.

```sh
read -rs POCKET_ID_API_TOKEN
kubectl -n pocket-id create secret generic pocket-id-api-token \
  --from-literal=POCKET_ID_API_TOKEN="$POCKET_ID_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
unset POCKET_ID_API_TOKEN
```

The Secret's key is `POCKET_ID_API_TOKEN`. For rotation, replace it, deliberately rerun and verify the relevant bootstrap jobs, then revoke the old token. A normal sync does not by itself prove a previously completed job has run again.

## Groups and application access

Create the groups referenced by the current component declarations: `administrators`, `apps_users`, and `infra_users`, with intended user memberships. Matching is by group `name`; avoid guessing capitalization from display labels.

The platform's `oidc.groupRestriction.allowedGroups` is authoritative for client restrictions. The job resolves names to IDs and reconciles the allowlist. Empty or omitted restrictions clear that client restriction. Manual allowlist changes can be overwritten by a later job.

App-side role mapping is separate. For example, ArgoCD grants admin to `administrators` and `infra_users`. Grafana's current mapping still checks `Administrators` with a capital A; that inconsistency needs verification against real IDP claims before changing it. This documentation cleanup does not alter access policy.

Use the IDP's enrollment/signup flow for additional users, assign memberships, and verify actual access with an account from each intended tier. App-specific first-run setup, such as Jellyfin's plugin settings, remains separate.

## What is automated

For enabled component OIDC blocks, the platform job registers or updates the client, callback URLs, and group restriction, then writes the application's client credential Secret. See [adding applications](../../../docs/adding-apps.md).

## Recovery

Preserve and restore the Pocket ID database, the private age key for repository secrets, and out-of-cluster administrator recovery material. Re-supply the bootstrap API token after cluster-state loss and verify client credentials against restored application state. See [backup status](../../../docs/backup-manual.md); the old backup script still targets an obsolete Pocket ID claim.
