# Forgejo

Git hosting for J and his agents at **https://forgejo.3rr.dev**, with SSH at **git.3rr.dev**, port 22. ArgoCD owns the Forgejo 17.1.6 chart, explicitly running Forgejo **16.0.4-rootless** rather than the chart's LTS default.

One Forgejo pod and one CNPG PostgreSQL 16 instance run on NODE-2 using retained `local-bulk` storage: 50 GiB for Forgejo and 10 GiB for PostgreSQL. The hostPath provisioner does not enforce these as disk quotas. NODE-2 downtime makes the service unavailable. Backups are managed separately by J and are outside this deployment.

## Access

Use the **pocket-id** login button. Pocket ID controls eligibility through access to client `forgejo`, currently restricted to group `forgejo_users`. Eligible identities are automatically provisioned without an additional subject allowlist in Forgejo. Local password self-registration and automatic account linking remain disabled; the existing local recovery account remains usable. J's existing account stays linked to his Pocket ID subject. No Pocket ID group membership is changed by this feature rollout.

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

The explicit switches are in [values.yaml](values.yaml); the [feature guide](../../../docs/forgejo-preparation.md) records the agreed choices. Issues, PRs, forks, imports, pull/push mirrors, personal/organization push-to-create, LFS, attachments, packages, Actions server support, source archives, code indexing and webhooks are enabled. New writable repositories and forks receive issues, PRs, packages and Actions units; read-only mirrors default to Code and Releases. New repositories are private by default, including push-to-create. Public repositories allow anonymous reads. Agents are expected to work through PRs; branch protection is configured separately per repository.

Projects, wikis, stars, time tracking, native file uploads, mail, federation, external avatars, feeds, metrics and other unneeded extras remain disabled. Code indexing uses embedded Bleve on the retained Forgejo volume and includes forks and mirrors. Forgejo 16's documented REST API does not expose code-content search; zgit integration for that capability remains separate. The API remains available with Swagger disabled.

No webhook destinations, mirrors, runners or publishing services are created by enabling these capabilities. Actions execution needs a runner; Pages hosting and the GitHub-star collector remain separate work. Public DNS/routing is managed separately by J; CORS and sitemap remain unchanged. Forgejo advertises `https://forgejo.3rr.dev/` for web/HTTPS Git and `git.3rr.dev:22` for SSH. The existing internal route remains `git.apps.home` as an origin access path.

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
- OIDC discovery, redirect URI, subject restriction, pre-provisioned account mapping and PKCE were checked. J confirmed that interactive Pocket ID passkey login successfully signs into account J.

Backup implementation and restoration testing were explicitly excluded by J.


## Feature rollout verification — 2026-09-15

The approved feature set was deployed through ArgoCD. All four repository roots passed `just check`; the pinned upstream chart rendered and passed server-side dry-run validation. All 98 configured section settings matched the live `app.ini`. Forgejo and all four roots were Synced/Healthy after rollout.

Runtime checks passed for issue creation and attachments, branch creation and PR merge, Actions API availability, LFS upload/download, generic package publish/download/delete, public anonymous reads and ZIP downloads, private access denial, personal and organization HTTPS push-to-create (both private by default), organization creation, writable forks, GitHub pull-mirror import and fetched commits, and webhook API availability with no configured destinations. All temporary repositories, organization and package versions were removed. Existing `J/test` received issues, PRs, Actions and packages while remaining private.

The Pocket ID provider's persisted required-claim fields are empty, the existing J/recovery accounts and login sources are preserved, the signup page offers Pocket ID without local password signup, and the OIDC redirect retains S256 PKCE. A fresh identity's interactive provisioning was not exercised; it requires an eligible Pocket ID login. The SSH service still answers on port 22 with the same RSA host-key fingerprint as the original deployment.

Two API integration limits matter for zgit:

- Forgejo's create-repository API treats an omitted `private` field as false, even with `DEFAULT_PRIVATE=private`. zgit and other API clients must explicitly send `"private": true` for private creation. Native UI defaults and push-to-create are configured private; enforcing all repositories private would prevent the agreed public-repository support.
- Forgejo 16's documented REST API has no code-content search endpoint. The code index is enabled and initialized, but that does not supply a REST search integration for zgit.

Actions execution remains untested without a runner; actual user mirrors, publishing services, public routing and the star collector remain deferred.


## Public hostnames — 2026-09-15

`server.DOMAIN=forgejo.3rr.dev`, `ROOT_URL=https://forgejo.3rr.dev/` and `SSH_DOMAIN=git.3rr.dev` set the application URL and advertised clone URLs. The built-in SSH listener remains on 2222, exposed by the existing Service on 22. SSH does not use an HTTP Host header or TLS hostname certificate; clients verify the persisted server host key using the name they connect to.

Pocket ID's Forgejo client callback is `https://forgejo.3rr.dev/user/oauth2/pocket-id/callback`. The identity issuer remains `https://auth.apps.home`; no identity-provider migration is implied by changing Forgejo's hostname. Routing, DNS, Cloudflare and TLS termination are managed separately by J and are unchanged here.

To publish a repository, change its visibility in repository Settings, or send `PATCH /api/v1/repos/{owner}/{repo}` with `{"private": false}` using an account/token permitted to administer it. Instance settings already allow public repositories and anonymous reads. Publishing a Forgejo repository does not change a GitHub mirror's visibility.
