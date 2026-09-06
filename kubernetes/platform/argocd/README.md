# ArgoCD identity and recovery

ArgoCD uses direct OIDC with Pocket ID. It is an **infra** component declared in `kubernetes/platform/argocd/service.yaml`; runtime settings are in `kubernetes/platform/argocd/values.yaml`.

## Already declarative

- The component's OIDC block registers the client and callback `https://argocd.infra.home/auth/callback`.
- The platform job creates `argocd-oidc-client` in namespace `argocd`.
- A labeler job in the ArgoCD values adds the Secret label needed for ArgoCD's Secret references.
- `configs.cm.oidc.config` configures Pocket ID directly; no manual Dex connector is needed.
- The server mounts the trust-manager CA bundle for the OIDC back channel.
- RBAC grants `administrators` and `infra_users` the admin role. `apps_users` has no grant. These mappings are configured in Git, not through Pocket ID app-role settings.

## Manual prerequisites

Complete [Pocket ID enrollment and token setup](../identity/pocket-id/README.md). Verify membership and exact group names in the IDP, then inspect the OIDC bootstrap and labeler jobs if the client Secret is missing or unusable. The separate `homepage-widget` API token must be supplied through the encrypted Homepage admin credentials manifest when that integration is rebuilt.

## Verification

Open `https://argocd.infra.home`, verify that Pocket ID login and the local admin form are both available, and test authorization with accounts from the intended groups. Inspect the `argocd-oidc-client` Secret's metadata and key names without copying credentials into notes.

## Local admin fallback

Local admin authentication remains enabled. Use the saved admin credential; `just argocd-password` reads `argocd-initial-admin-secret` if that bootstrap Secret still exists. It is not proof of the current password after a rotation. Keep recovery credentials outside the cluster.
