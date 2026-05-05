# pocket-id — manual config

Pocket-ID is our OIDC IDP. Most config is interactive (passkey enrollment, OIDC client creation pre-automation, group membership). This README is the rebuild guide if state is lost.

**Live at:** https://auth.apps.home

## Pre-reqs

- Cluster up, `pocket-id` namespace deployed (helm: `kubernetes/values/apps/pocket-id.yaml`)
- `auth.apps.home` returns 200 / 302 from a browser on the LAN
- A WebAuthn-capable device handy (Yubikey, phone, laptop platform passkey)

## Steps

### 1. First-admin bootstrap

When the SQLite DB is empty, the first visitor at `/login/setup` becomes the admin.

1. Browse to **https://auth.apps.home/login/setup** (or just `https://auth.apps.home/` — it'll redirect)
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
7. Drop it into the SOPS secret:
   ```
   cd ~/Git/arch-err/IaC/Cluster-Config/kubernetes
   SOPS_AGE_KEY_FILE=~/.config/sops/age/cluster-config.txt \
     sops secrets/apps/pocket-id-api-token.yaml
   ```
   Replace `REPLACE_ME` with the token, save, exit.
8. Commit + push:
   ```
   git add secrets/apps/pocket-id-api-token.yaml
   git commit -m "secrets(pocket-id): populate API token"
   git push
   ```

**Also store the token in your personal password manager** (e.g. Bitwarden) under "Cluster — pocket-id admin API token". This is the only out-of-cluster copy.

### 3. Create groups

OIDC client policies bind to group membership.

1. UI → Groups → New
   - `admins` — Admin user goes here. Future MFA-required policies + per-app admin role mappings.
   - `users` — regular accounts (J, E). Per-app user/viewer role.
2. Add memberships once user accounts exist (step 4).

### 4. Create the user accounts

For each non-admin user (J, E):
1. UI → Users → New
2. Email + display name
3. **Do NOT** set a password — pocket-id is passkey-only
4. Add to `users` group
5. Generate a one-time enrollment link from the user's detail page → **send via secure channel** (Signal, in-person QR, Bitwarden Send, etc.). Link expires after first use or after a TTL.
6. User clicks link, enrolls their passkey, account is live

### 5. (when ready) Bootstrap pattern is wired

Once API token is in the cluster (step 2) AND the platform-chart OIDC pattern is built (separate task), every app deployed with `oidc.enabled: true` in `apps.yaml` auto-registers its OIDC client here. **No more manual UI clicks per app** beyond step 6 below.

### 6. Per-app: bind groups → roles (still manual)

For each new app integrated via OIDC:
1. UI → Applications → `<app-name>`
2. Configure group→role/scope mapping per app's OIDC requirements (e.g. `admins → role:admin`, `users → role:viewer`)
3. Save

Why manual: app-specific role schemas vary too much to encode in `apps.yaml`. The OIDC client itself auto-registers; the *what does each group get inside this app* mapping is per-app config.

## State this creates

Lives in `/app/data/pocket-id.db` inside the pocket-id pod, on the **`pocket-id` PVC** (5Gi, kadalu.replica2). All passkey credentials, users, groups, API tokens, OIDC clients, mappings — everything.

Lose this PVC → re-run all steps in this README.

## Backup hint

The pocket-id PVC is the entire state. Two options for protection:

1. **Litestream → S3 sidecar** — continuous SQLite replication. Recommended.
2. **Periodic restic snapshot** of the PVC — fine for daily backup.

Set up via a separate task; not yet done.

## Pivot history

We previously ran **Authentik 2025.12.4** here. Multiple chart bugs (pg init bypass, KeyError migrations) made fresh installs unrecoverable. Switched to pocket-id 2026-05-05 (commits `5b56fcb`, `c4f5598`).
