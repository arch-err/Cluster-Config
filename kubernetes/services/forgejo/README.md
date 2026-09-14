# Forgejo

Private Git hosting for J at **https://git.apps.home**, with SSH on the same hostname, port 22. ArgoCD owns the Forgejo 17.1.6 chart, explicitly running Forgejo **16.0.4-rootless** rather than the chart's LTS default.

One Forgejo pod and one CNPG PostgreSQL 16 instance run on NODE-2 using retained `local-bulk` storage: 50 GiB for Forgejo and 10 GiB for PostgreSQL. The hostPath provisioner does not enforce these as disk quotas. NODE-2 downtime makes the service unavailable. Backups are managed separately by J and are outside this deployment.

## Access

Use the **pocket-id** login button. Pocket ID client `forgejo` is restricted to group `forgejo_users`, whose only member is J. Forgejo also requires J's exact Pocket ID subject claim, preventing a later broadening of group membership from granting another identity access. Self-registration, automatic OIDC registration and account linking are disabled. J's Forgejo account is explicitly provisioned against the Pocket ID subject; an identity rebuild requires updating both the subject restriction in values and the account's login name.

Forgejo 16's first OIDC request after a cold start initializes the provider without PKCE. A startup probe consumes that redirect locally without following it; subsequent login requests include S256 PKCE. Recheck whether this workaround is needed on upgrades. Pocket ID still requires PKCE.

Local recovery username: `forgejo-recovery`. Retrieve its generated password privately with:

```sh
kubectl -n forgejo get secret forgejo-admin -o jsonpath='{.data.password}' | base64 -d
```

The bootstrap password is encrypted in `secrets/forgejo.yaml`; `initialOnlyNoReset` preserves later password changes. Enable account MFA in the UI as appropriate. Recovery remains independent of Pocket ID availability. HTTPS Git uses personal access tokens; SSH Git uses keys registered in Forgejo. Native OIDC does not authenticate Git CLI requests.

## Networking and startup

The apps gateway serves HTTPS on `10.10.10.200:443`. The Forgejo SSH LoadBalancer shares that address on port 22, forwarding to the rootless listener on 2222. Reciprocal Cilium sharing annotations are declared here and in the apps Gateway. SSH routing is by IP/port: other names resolving to the same IP reach the same SSH server.

The namespace has sync wave -20; CNPG is wave 0, the optional OIDC bootstrap Job wave 11, the application wave 12, and its HTTPRoute wave 13. OIDC provisioning is a one-time operation: remove `oidc.bootstrapJob: true` after success, retaining its configuration and RBAC. The group must exist in Pocket ID before running that job, following the platform's existing manually managed group convention. CNPG and OIDC generate their respective credential Secrets. The home CA bundle is supplied by trust-manager; CNPG supplies its own CA for verified database TLS.

## Features

The explicit switches are in [values.yaml](values.yaml); the [feature guide](../../../docs/forgejo-preparation.md) explains their effects. Actions/runners, packages, LFS, issues, PRs, wiki, projects, forks, stars, migrations, mirrors, webhooks, attachments, uploads, source archives, code indexing, mail, federation, external avatars, feeds and metrics start disabled. Code and Releases cannot be disabled as repository units. Swagger is disabled but the authenticated API remains available. Ordinary Git, authentication security, logs, probes and necessary maintenance remain functional.

Feature changes belong in Git. Render the pinned upstream chart, run `just check`, and check the running `app.ini` after rollout: upstream chart defaults and persisted secrets affect the final configuration.


## Deployment verification — 2026-09-14

- ArgoCD reconciled the pinned OCI chart and the supporting CNPG, OIDC and Gateway resources.
- All four repository roots passed `just check`; the upstream chart passed server-side validation under the cluster's restricted Pod Security policy.
- All 94 explicit application settings matched both the Forgejo 16.0.4 example configuration and the running `app.ini`.
- HTTPS Git clone/push/pull with a temporary access token and SSH clone/push/pull with a temporary key passed. Anonymous access to the private test repository was denied.
- Issue, pull-request and Actions APIs returned 404. Package publishing returned 404; the general package-list API remains reachable and returns an empty list, so disabling the registry does not remove every related API route.
- PostgreSQL connections used TLS 1.3 with `verify-full`. Both PVCs have retained PVs with NODE-2 affinity.
- A Forgejo restart preserved repository commits, both accounts, managed encryption secrets and the SSH host key. Temporary test repositories, tokens and user SSH keys were removed afterward.
- Local recovery web login and access to its authenticated settings page passed. The test session was logged out.
- After the startup-probe fix, the first external OIDC request after a cold rollout included S256 PKCE.
- OIDC discovery, redirect URI, subject restriction, pre-provisioned account mapping and PKCE were checked. J's interactive passkey login requires J's confirmation; no claim of a completed interactive login is made here.

Backup implementation and restoration testing were explicitly excluded by J.
