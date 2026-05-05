# pocket-id — manual config

Pocket-ID is our OIDC IDP. Most config is interactive (passkey enrollment, OIDC client creation pre-automation, group membership). This README is the rebuild guide if state is lost.

**Live at:** https://auth.apps.home

## Pre-reqs

- Cluster up, `pocket-id` namespace deployed (helm: `kubernetes/values/apps/pocket-id.yaml`)
- `auth.apps.home` returns 200 / 302 from a browser on the LAN
- A WebAuthn-capable device handy (Yubikey, phone, laptop platform passkey)

## Steps

### 1. First-admin bootstrap

When the SQLite DB is empty, the first visitor at `/setup` becomes the admin.

1. Browse to [https://auth.apps.home/setup](https://auth.apps.home/setup)
2. Enroll a passkey for the admin account (use a Yubikey if you want hardware-backed)
3. Note: there is NO password — passkey-only

### 2. Issue admin API token

Used by the platform chart's OIDC bootstrap Jobs (auto-creates OIDC clients per app).

1. Log in to the pocket-id UI as admin
2. Settings → API Tokens → New
3. **Scope:** narrowest available that allows OIDC client management (check current pocket-id docs — may be "OIDC Clients: write" or admin if no granular scope yet)
4. **Name:** `cluster-bootstrap`
5. **Expiry:** none (long-lived) OR rotation period (1y is fine)
6. Copy the token — it's shown ONCE
7. **Store it in your personal password manager** (Bitwarden, etc.) under `Cluster — pocket-id admin API token`. This is the *only* out-of-cluster copy. The token is **NOT** stored in git — too sensitive.
8. Apply it to the cluster as a regular Secret. Use `read -rs` to keep the token off your shell history:
   ```bash
   read -rs POCKET_ID_API_TOKEN
   # paste the token, hit enter — it won't echo
   kubectl -n pocket-id create secret generic pocket-id-api-token \
     --from-literal=POCKET_ID_API_TOKEN="$POCKET_ID_API_TOKEN" \
     --dry-run=client -o yaml | kubectl apply -f -
   unset POCKET_ID_API_TOKEN
   ```
   This is idempotent — safe to re-run for rotation. The Secret persists in cluster state, NOT in the GitOps repo.

### Token rotation

When you rotate (annually, or after a suspected leak):
1. Generate a new token in pocket-id UI, store in password manager
2. Re-run the `kubectl apply` block above with the new token
3. Trigger a re-sync of any apps using OIDC (so their bootstrap Jobs re-fetch with new token)
4. Revoke the old token in pocket-id UI

### Backup of token state

The token Secret is **not** backed up by GitOps (intentional). Recovery path if the cluster's state is wiped:
1. Issue a fresh token in pocket-id (after rebuilding pocket-id per steps 1–3)
2. Re-apply via the `kubectl` block above
3. The OIDC bootstrap Jobs auto-fire on next argocd sync, all per-app client secrets regenerate

### 3. Create user groups

Pocket-ID uses a single concept — **user groups** — for both authorization (which users can access which OIDC clients) and per-app role mapping. There's no separate "role" or "policy" object; group membership is the only knob.

1. UI → **User Groups** → New
   - `admins` — Admin account goes here. Maps to admin/owner roles in each app.
   - `users` — regular accounts (J, E). Maps to user/viewer roles in each app.
2. Add memberships once user accounts exist (step 4).

### 4. Onboard non-admin users via Signup Tokens

Pocket-ID's onboarding model is **token-based, not per-user**. As admin, you generate a Signup Token (URL with a random token), the user opens it in their browser, fills email/name, enrolls their passkey, and an account is created. There is no "send link to existing user" — the user is *created* by the act of redeeming the token.

1. UI → **Signup Tokens** → New
2. Configure:
   - **Max uses** — `1` for a one-shot personal link; higher for shared bulk onboarding (e.g. one token for several family members)
   - **Expiry** — short (1–24h) is healthy hygiene
   - **Pre-assigned user groups** — e.g. `apps-users` for gf/family. The new account inherits these on creation. Skip if you want to assign manually after.
3. Save → pocket-id shows a URL like `https://auth.apps.home/signup?token=<random>`
4. **Send via secure channel** — Signal, in-person QR, Bitwarden Send (encrypted+expiring). Never plaintext email/SMS.
5. User opens link → fills email + display name → enrolls passkey → account is live with the pre-assigned groups
6. (Optional) After-the-fact: as admin, edit the user to fine-tune group memberships if pre-assignment didn't cover their tier

To enroll multi-device (user wants both phone + laptop passkeys): they log in once with the first passkey, then their own Settings → Add Passkey → enroll second.

### 5. Per-app: declare `oidc.enabled: true` in `apps.yaml`

Once the API token from step 2 is populated, the platform chart's
`oidc-bootstrap` Job (see `kubernetes/platform/templates/oidc-bootstrap.yaml`,
docs in `kubernetes/platform/README.md`) auto-registers an OIDC client and
writes `client_id` + `client_secret` into the app's namespace as a Secret.

For each app you want to integrate:
1. Add an `oidc:` block to its component entry in `apps.yaml`:
   ```yaml
   oidc:
     enabled: true
     callbackUrls:
       - https://<app>.apps.home/<the chart's expected callback path>
     # optional: scopes, secretName, public, logoutCallbackUrls
   ```
2. Reference the rendered Secret (default name `<app>-oidc-client`) from the
   app's helm values — keys are `client_id`, `client_secret`, `issuer_url`.
3. Commit + push. ArgoCD reconciles → bootstrap Job runs → Secret appears in
   the app's ns → restart the app pod if it doesn't auto-reload.

**No more manual UI clicks per app** beyond steps 6 and 7 below.

### Allowed user groups (per OIDC client)

After the bootstrap Job auto-registers an OIDC client, by default **any
authenticated pocket-id user** can initiate an OAuth flow against that client
(the downstream app then decides what role they get). To restrict who can even
attempt login at the IDP, set the client's **allowed user groups** in the
pocket-id UI:

1. Pocket-id UI → **OIDC Clients** → `<app-name>` → toggle **"Restrict to
   user groups"** on
2. Add the groups that should be allowed to authenticate to this client
3. Save

**Per-app guidance for current apps:**

- **grafana** — allowed groups: `Administrators` only (until the apps-users /
  infra-users tier mapping is decided). Non-admin users won't see the login
  dialog at all; admins map to `GrafanaAdmin` via the `role_attribute_path` in
  `kubernetes/values/infra/grafana.yaml`.

### 6. Per-app: bind user groups → app roles (still manual)

Pocket-ID emits the user's group memberships in the OIDC `groups` claim. Each downstream app reads that claim and maps groups → its own role schema. **The mapping itself lives in the app's config, not in pocket-id.**

So the per-app work is:
1. In **pocket-id UI** → OIDC Clients → `<app-name>` → ensure `groups` is in the requested scopes (it should be by default if the platform chart's `oidc.scopes` includes `groups`).
2. In **the app's helm values** (e.g. `kubernetes/values/apps/<app>.yaml`): configure the app's OIDC role-mapping. Examples:
   - **Grafana**: `auth.generic_oauth.role_attribute_path: contains(groups[*], 'admins') && 'GrafanaAdmin' || contains(groups[*], 'users') && 'Viewer'`
   - **Argo CD**: RBAC policy CSV referencing `g, admins, role:admin`
   - **Immich**: configure OAuth-managed admin via `oauth.adminGroup: admins`
   - Each chart has its own knob — read its OIDC docs.

Why this is manual: pocket-id doesn't store app-side role schemas (they belong to each app). The OIDC client auto-registers via the bootstrap Job; the per-app role-mapping in helm values is yours to set per chart.

## State this creates

Lives in `/app/data/pocket-id.db` inside the pocket-id pod, on the **`pocket-id` PVC** (5Gi, kadalu.replica2). All passkey credentials, users, groups, API tokens, OIDC clients, mappings — everything.

Lose this PVC → re-run all steps in this README.

## Backup hint

The pocket-id PVC is the entire state. Two options for protection:

1. **Litestream → S3 sidecar** — continuous SQLite replication. Recommended.
2. **Periodic restic snapshot** of the PVC — fine for daily backup.

Set up via a separate task; not yet done.
