# argocd — manual config

ArgoCD is mostly GitOps-managed via its own helm values, but **SSO wiring** to pocket-id requires manual coordination once pocket-id is live.

## Steps

### Wiring SSO via pocket-id

Pre-req: pocket-id is live, you've enrolled admin, the platform-chart OIDC bootstrap pattern is wired (so argocd's OIDC client auto-registers).

1. Add `oidc.enabled: true` to argocd's entry in `kubernetes/apps.yaml` with:
   ```yaml
   oidc:
     enabled: true
     callbackUrls: [https://argocd.infra.home/auth/callback]
     scopes: [openid, profile, email, groups]
     secretName: argocd-oidc-client
   ```
2. Push. Platform Job auto-registers an `argocd` OIDC client in pocket-id and creates the `argocd-oidc-client` Secret in argocd ns.
3. Restore the dex connector in `kubernetes/values/infra/argocd.yaml` (currently stubbed out — there's a comment marker). Reference the auto-created secret:
   ```yaml
   dex.config: |
     connectors:
       - type: oidc
         id: pocket-id
         name: Pocket ID
         config:
           issuer: https://auth.apps.home
           clientID: $argocd-oidc-client:client_id
           clientSecret: $argocd-oidc-client:client_secret
           insecureEnableGroups: true
           scopes: [openid, profile, email, groups]
   ```
4. Add the `dex.envFrom` referencing `argocd-oidc-client`.
5. (in pocket-id UI) Application → argocd → map `admins` group → ArgoCD admin role, `users` → readonly.
6. Push, watch argocd sync, log in via "Log in with Pocket ID" button.

### Verification

- Browse to https://argocd.infra.home/, see the "Log in with Pocket ID" button alongside the local admin login
- Click it, complete passkey, end up in argocd UI
- Confirm RBAC: admin → full access; user → read-only

## Local admin fallback

The `admin` user (local) always works as a fallback. Password is in the `argocd-initial-admin-secret` Secret in argocd ns:
```
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Use this if pocket-id is down OR if SSO is mid-rotation.

## Pivot history

- Previously had a dex connector pointing at authentik (`argocd-dex-authentik` secret). Authentik never got past phase 1 → connector stale → argocd-dex pod crashlooping for 3 days. Cleaned up during pocket-id pivot (commit `5b56fcb`).
