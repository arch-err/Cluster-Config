# Forgejo preparation

## TL;DR

Research checked 2026-09-14. J wants Forgejo in its own `forgejo` namespace, with as many optional features disabled as practical, then a joint review of what to enable. J authorized implementing and deploying the agreed setup. The managed configuration is in `kubernetes/services/forgejo/`; this document preserves the feature explanations and decision context. See the service README for operational access and deployment details.

Start with authenticated Git hosting and the web interface. Preserve account security, TLS, authorization, logging, health checks, and necessary maintenance. Disable optional product capabilities explicitly rather than relying on defaults or hiding tabs.

## Revised feature direction — after initial deployment

J uses Forgejo with his agents as an alternative to GitHub, with **zgit**, his own API-based frontend, as the everyday interface. Separate agent user accounts are not currently required. Later, public repositories should be available read-only to Internet visitors, with a separate public-facing Pocket ID managed by J. The scope here remains strictly Forgejo configuration; external exposure, identity-provider deployment, security infrastructure and backups are handled separately. This section supersedes the earlier private-only target; the initial deployment descriptions below remain the historical baseline. J subsequently approved implementation of these choices; the managed values now implement the agreed feature set. Historical deployment checks below describe the original minimal setup.

| Capability | Requested direction |
| --- | --- |
| Issues | Enable. |
| Code search | Confirmed: enable repository code indexing for cross-repository file-content search. Embedded Bleve indexes sources, forks, mirrors and templates. Implementation review found no code-content search endpoint in Forgejo 16's documented REST API; zgit search integration remains separate. |
| Webhooks | Confirmed: enable the capability. Configure no webhook destinations until a concrete integration needs them. Custom server-side Git hooks remain disabled. |
| Forks | Confirmed: enable Forgejo repository forks, including writable forks for work on mirrored upstream repositories. |
| Source archive downloads | Confirmed: enable ZIP/tar source downloads, subject to repository access permissions. |
| Stars | Confirmed: keep Forgejo stars disabled. The proposed GitHub-star mirror collector does not depend on Forgejo stars. |
| Time tracking | Keep disabled; J declined it and requested grouped recommendations for the remaining review. |
| Pull requests | Confirmed: enable; agents should work through PRs on writable Forgejo repositories. Separate agent users are not required. Leave branch protection and required reviews unset initially; this is a workflow expectation, not enforced prevention of direct pushes. |
| Projects and wikis | Keep disabled for now. |
| GitHub mirroring | Full native pull/push mirror capability desired. Resolve the authoritative writable location per repository before configuring mirrors. |
| Public and private repositories | Confirmed: private by default for newly created repositories, including push-to-create in personal and organization namespaces. J explicitly selects when to publish a repository. Allow public repositories rather than forcing all repositories private. |
| Anonymous browsing | Enable for public content. This does not publish the instance to the Internet by itself. |
| Pocket ID registration | Confirmed: Pocket ID controls eligibility through access to the Forgejo OIDC client. Automatically provision eligible OIDC users without an additional J-only subject restriction in Forgejo. Keep local password self-registration disabled and retain local administrator recovery. This selects the intended Forgejo behavior; it does not authorize broadening the Pocket ID client audience or making newly provisioned users administrators. |
| Packages, Actions, LFS and attachments | Enable Forgejo capabilities. Runner execution is a separate dependency from enabling Actions. |
| Push-to-create | Desired; personal and organization repositories are relevant, including locally originated CTF repositories. |
| Organizations | Desired for grouping repositories, e.g. one CTF organization. This does not require additional users or enabling project boards. Current restrictions limit regular-user organization creation; they do not disable organizations themselves. |
| Pages equivalent | Desired, but not a native Forgejo configuration toggle. Track the integration requirement without deploying a separate service under the current scope. |
| Sitemap | Deferred with public-facing setup; revisit when public frontend URLs are settled. |

API behavior, authentication, pagination and feature permissions matter for zgit; hiding native UI tabs is not a sufficient acceptance test. Confirmed: zgit calls Forgejo's API from both its backend and the browser. J tentatively names `git.3rr.dev` as zgit's production hostname; assume HTTPS, giving the proposed origin `https://git.3rr.dev`. Development origins and the browser-facing Forgejo API origin remain unspecified. CORS is needed for browser calls only when they cross origins; do not enable it solely because browser calls exist. Do not enable broad CORS or Forgejo's OAuth2-provider feature simply because zgit exists. If zgit needs Forgejo-issued delegated tokens, that is a separate concrete requirement from consuming Pocket ID login. This tentative zgit hostname is not a decision to change Forgejo's current `ROOT_URL`, SSH hostname, DNS or routing.

[Native mirroring](https://forgejo.org/docs/v16.0/user/repo-mirror/) synchronizes Git branches, tags and commits; it does not imply continuous bidirectional synchronization of issues, PRs, Actions state, packages or release attachments. Git LFS object transfer also needs explicit verification when testing an actual mirror. A pull mirror rejects writes ([16.0.5 source](https://codeberg.org/forgejo/forgejo/src/tag/v16.0.5/routers/private/serv.go)); a push mirror can overwrite divergent destination changes. Proposed workflow: import active GitHub repositories as ordinary writable Forgejo repositories, work through Forgejo PRs, and optionally push-mirror back to GitHub. Keep GitHub-primary pull mirrors for repositories that remain active there. The per-repository decision below supersedes this original general proposal.

[Actions documentation](https://forgejo.org/docs/v16.0/admin/actions/) distinguishes the Forgejo server from the separately installed runner. [Codeberg Pages](https://docs.codeberg.org/codeberg-pages/) currently uses the separate `git-pages` service, which supports self-hosted Forgejo; deployment can be driven by webhooks or Actions. Pages may therefore introduce a concrete webhook requirement, but enabling Actions does not automatically enable Pages hosting. The Forgejo contributor documentation called “Static pages” describes the project's infrastructure, not a built-in per-repository Pages feature.

Forgejo's `ENABLE_SITEMAP` controls its own sitemap. If zgit is the public canonical frontend, its own route structure determines the useful public sitemap. This remains a later frontend integration decision; no zgit changes are in scope here.

J explicitly deferred public-facing design until public exposure is undertaken. Do not block the current Forgejo feature review on public hostnames, proxy routing, browser API origins, CORS or sitemap decisions. Keep the current hostname/routing and CORS setting unchanged for now; `git.3rr.dev` remains tentative context only.

Review preference: present remaining features in groups with recommendations, allowing J to object rather than requesting yes/no for each toggle. Do not describe recommendations as already deployed.

### Repository ownership and preservation — 2026-09-15

Confirmed rule: every repository J owns, and GitHub repositories J finds interesting, should have a locally held repository in Forgejo, either writable or a read-only mirror. The authoritative writable host is selected per repository. Organizations should help group repositories and inform future automation defaults, with per-repository exceptions; no organization policy automation has been implemented.

CTF repositories originate locally, belong in a dedicated Forgejo organization, and are also pushed to GitHub. J explicitly selects when a repository becomes public. Proposed flow is local → writable Forgejo → GitHub push mirror. Forgejo visibility changes do not themselves change GitHub repository visibility; coordinated publication would require API automation. Internal tools may remain entirely in Forgejo.

For upstream contributions, propose retaining an upstream pull mirror separately from a writable working fork/copy in Forgejo. Contribution branches can be pushed to J's fork on GitHub and used for upstream GitHub PRs. This keeps work in Forgejo while respecting the upstream forge's PR workflow. Do not configure opposing whole-repository mirrors as bidirectional collaboration.

J is considering a separate local scheduled process that discovers GitHub stars and creates Forgejo pull mirrors through the API. This is future external automation, not a requested implementation in the current Forgejo-configuration scope. Suggested design: GitHub repository ID for identity across renames; paginated discovery; idempotent creation; Forgejo handles subsequent scheduled Git synchronization. Recommend retaining local repositories when unstarred or when upstream becomes inaccessible, never interpreting a discovery omission as a deletion request. A successful fetch is required before any content is preserved.

Confirmed by J: keep it simple with normal pull mirrors initially. Preserve the latest successfully fetched copy when upstream disappears or becomes inaccessible; historical retention of revisions subsequently removed or rewritten upstream is deferred. Proposed collector behavior remains to retain local copies on unstar rather than delete them. No additional archival mechanism is required for the initial setup. Git history does not imply preservation of GitHub issues, PR discussions, release assets, LFS objects or submodule repositories. Sources: [Forgejo mirrors](https://forgejo.org/docs/v16.0/user/repo-mirror/), [GitHub stars API](https://docs.github.com/en/rest/activity/starring?apiVersion=2022-11-28), [Git fetch pruning](https://git-scm.com/docs/git-fetch#_pruning).

Earlier advice to select one primary host for all active repositories is superseded by this per-repository direction. The feature rollout enables capabilities; concrete mirrors and scheduled jobs remain separate work.

## Versions and sources

- [Current releases](https://forgejo.org/releases/): stable **16.0.5**, supported until 2026-10-29; LTS **15.0.9**, supported until 2027-07-15. Both released 2026-09-17. **Confirmed by J: latest stable track.** Recheck the stable release at installation and pin its exact version; do not use a floating image tag. Plan for major upgrades within the stable support windows.
- [Chart release 17.1.6](https://code.forgejo.org/forgejo-helm/forgejo-helm/releases/tag/v17.1.6): released 2026-09-10, targeting 15.0.8. Chart version and application version are independent.
- The selected stable track differs from this chart's LTS application default. Explicitly select the stable image version and validate chart/image compatibility and rendered configuration before installation; do not inherit the chart's application version silently.
- [Pinned chart README](https://code.forgejo.org/forgejo-helm/forgejo-helm/src/tag/v17.1.6/README.md) and [values](https://code.forgejo.org/forgejo-helm/forgejo-helm/src/tag/v17.1.6/values.yaml): OCI chart `oci://code.forgejo.org/forgejo-helm/forgejo`; application settings live under `gitea.config`, despite the Forgejo name.
- [v16 configuration documentation](https://forgejo.org/docs/v16.0/admin/config-cheat-sheet/) was checked against the release-specific [16.0.5 example configuration](https://codeberg.org/forgejo/forgejo/src/tag/v16.0.5/custom/conf/app.example.ini) and [15.0.9 example configuration](https://codeberg.org/forgejo/forgejo/src/tag/v15.0.9/custom/conf/app.example.ini). Use the selected release's source when implementing; the documentation warns that its defaults are best-effort. Configuration changes require a restart.
- Installation references: [installation](https://forgejo.org/docs/v16.0/admin/installation/), [database preparation](https://forgejo.org/docs/v16.0/admin/installation/database-preparation/), [recommended settings](https://forgejo.org/docs/v16.0/admin/setup/recommendations/), [upgrade guide](https://forgejo.org/docs/v16.0/admin/upgrade/).

## Public hostname update — 2026-09-15

J subsequently requested `https://forgejo.3rr.dev/` for Forgejo and `git.3rr.dev:22` for SSH. These application hostnames are deployed. The Forgejo HTTPRoute now uses the public Gateway, which marks the namespace public and activates public-edge isolation; Cloudflare and DNS remain explicitly J's scope. CORS and sitemap remain unchanged. No repository visibility change was requested with an identified target. The former private Pocket ID source is intentionally unreachable under the public policy and will be replaced by J with the independent public issuer.

## Implemented feature rollout — 2026-09-15

J approved the grouped feature recommendations and authorized deployment. The agreed settings are now deployed; see the [service verification record](../kubernetes/services/forgejo/README.md#feature-rollout-verification--2026-09-15) for runtime checks and deferred dependencies. Existing `J/test` remains private with its agreed feature units enabled.

Private-by-default applies to native creation defaults and personal/organization push-to-create. Forgejo's REST repository-creation API instead defaults an omitted `private` field to false, verified against the running release. zgit must explicitly send `"private": true`; no zgit changes were made in this Forgejo-only scope. Code indexing is initialized, but the documented REST API has no code-content search endpoint.

## Historical minimal feature baseline

Notation: `[section] KEY=value` maps to `gitea.config.section.KEY` in chart values. Dotted sections remain one YAML key. These are proposed values, not upstream defaults. Controls below were checked in the release example configurations linked above.

| Capability | Proposed control | What enabling it would provide / consequence of disabling |
| --- | --- | --- |
| Issues | Include `repo.issues,repo.ext_issues` in `[repository] DISABLED_REPO_UNITS` | Bug/task tracking, labels and milestones; external tracker integration is also unavailable. |
| Pull requests | Disable unit `repo.pulls` | Branch review, approval and merge workflow. Direct Git pushes still work. Likely an early feature to reconsider. |
| Wiki | Disable `repo.wiki,repo.ext_wiki` | Repository documentation wiki or links to an external wiki. README files remain. |
| Projects | Disable `repo.projects` | Repository project boards for organizing work. This is a repository-unit control, not a claim that every organization-level project interface is disabled. |
| Actions | `[actions] ENABLED=false`, disable `repo.actions`; deploy no runners | CI workflows, job logs, artifacts and automation. Enabling requires a separate runner and isolation design. |
| Packages | `[packages] ENABLED=false`, disable `repo.packages` | Container images, Helm charts, npm/PyPI and other package registries. Adds storage and retention needs. |
| Git LFS | `[server] LFS_START_SERVER=false` | Separate storage for large binary objects. Existing LFS pointer files alone do not contain their objects. |
| Mirrors | `[mirror] ENABLED=false` | Scheduled pull/push synchronization with another Git host. Not a backup substitute. |
| Migration/import | `[repository] DISABLE_MIGRATIONS=true`; `[f3] ENABLED=false` | Import repositories and forge metadata / Friendly Forge Format facilities. Ordinary local clone-and-push remains possible. |
| Forks | `[repository] DISABLE_FORKS=true` | Server-side repository forks; does not stop users cloning Git locally. |
| Stars | `[repository] DISABLE_STARS=true` | Repository bookmarking/popularity feature. |
| Webhooks | `[security] DISABLE_WEBHOOKS=true` | Deliver events to CI, ntfy or other receivers. ArgoCD polling can operate without hooks. |
| Custom Git hooks | `[security] DISABLE_GIT_HOOKS=true`; `IMPORT_LOCAL_PATHS=false` | User-defined server scripts and local filesystem imports stay unavailable. Forgejo's own required Git hooks must remain functional. |
| Browser file uploads | `[repository.upload] ENABLED=false` | Upload files through the repository UI. Does not disable Git push or necessarily the web editor. |
| Attachments | `[attachment] ENABLED=false` | Attach files to issues/PRs/releases. Release metadata and Git tags remain. |
| Source archive downloads | `[repository] DISABLE_DOWNLOAD_SOURCE_ARCHIVES=true` | UI ZIP/tar source downloads; authenticated Git clone remains. |
| Code search index | `[indexer] REPO_INDEXER_ENABLED=false` | Cross-repository code-content search, with CPU/disk indexing cost. Browsing files still works. |
| Time tracking | `[service] ENABLE_TIMETRACKING=false`, `DEFAULT_ENABLE_TIMETRACKING=false` | Timers and recorded effort on issues. |
| User activity heatmap | `[service] ENABLE_USER_HEATMAP=false` | Profile contribution calendar. |
| Explore directories | `[service.explore] DISABLE_USERS_PAGE=true`, `DISABLE_ORGANIZATIONS_PAGE=true`, `DISABLE_CODE_PAGE=true` | Discovery pages. Hiding these is not an access-control boundary. |
| Organization creation | `[admin] DISABLE_REGULAR_ORG_CREATION=true`; `[service] DEFAULT_ALLOW_CREATE_ORGANIZATION=false` | Admin-controlled organization creation; this does not disable organizations themselves. |
| Push-to-create | `[repository] ENABLE_PUSH_CREATE_USER=false`, `ENABLE_PUSH_CREATE_ORG=false` | Automatic creation of a repository on first push. Create repositories explicitly instead. |
| Mail | `[mailer] ENABLED=false`; `[email.incoming] ENABLED=false`; `[service] ENABLE_NOTIFY_MAIL=false` | Outbound notifications/recovery mail and incoming email replies. Plan recovery without SMTP. |
| Federation | `[federation] ENABLED=false`, `SHARE_USER_STATISTICS=false` | Cross-instance federation and associated statistics sharing. |
| External avatars | `[server] OFFLINE_MODE=true`; `[picture] DISABLE_GRAVATAR=true`, `ENABLE_FEDERATED_AVATAR=false` | External avatar fetching. Offline mode is not a network-egress firewall. |
| Generated badges | `[badges] ENABLED=false` | Forgejo-generated badge links using a service such as shields.io. Does not strip arbitrary remote images from READMEs. |
| Feeds / sitemap | `[other] ENABLE_FEED=false`, `ENABLE_SITEMAP=false` | RSS/Atom subscriptions and search-engine sitemap. |
| OAuth2 provider | `[oauth2] ENABLED=false` | Other applications using Forgejo as their identity provider. This is separate from logging into Forgejo through Pocket ID. |
| Legacy OpenID | `[openid] ENABLE_OPENID_SIGNIN=false`, `ENABLE_OPENID_SIGNUP=false` | OpenID 2.0 login. Not OpenID Connect/OIDC. |
| External JWT integrations | `[authorized_integration] BLOCKED_DOMAINS=*`, `ALLOW_LOCALNETWORKS=false` | External issuers obtaining API access for a user. Proposed issuer restriction, not a global UI-disable switch; verify rejection at runtime. |
| Metrics | `[metrics] ENABLED=false`; chart `gitea.metrics.enabled=false` | Prometheus scraping; a reasonable early opt-in given this repo's monitoring stack. Keep logs/probes. |
| Swagger | `[api] ENABLE_SWAGGER=false` | Interactive API documentation only. The API remains available. |
| Profiling / CORS | `[server] ENABLE_PPROF=false`; `[cors] ENABLED=false` | Debug profiling and cross-origin browser access. Normal same-origin UI use remains. |
| Instance commit signing | `[repository.signing] SIGNING_KEY=none`; chart `signing.enabled=false` | Server signing commits it creates. This does not disable verification of users' signed commits. |
| Optional rendering / PWA | `[ui.svg] ENABLE_RENDER=false`; `[markdown] ENABLE_MATH=false`; `[pwa] STANDALONE=false`; configure no external markup commands | SVG image rendering, math, standalone app presentation and external renderers. SVG displays as text and cannot be embedded as an image in Markdown. PWA standalone is a presentation setting, not a complete PWA kill switch. |

Set `DISABLED_REPO_UNITS` to the combined disabled-unit list above. Set `DEFAULT_REPO_UNITS`, `DEFAULT_FORK_REPO_UNITS`, and `DEFAULT_MIRROR_REPO_UNITS` to `repo.code,repo.releases`. Defaults affect newly created repositories; global restrictions have different semantics.

Code and Releases cannot currently be disabled as repository units. Do not invent switches for disabling the entire API, all browser editing, all notifications, or every organization feature. Test the actual resulting UI and API. Keep session handling, authentication protections, Git integrity checks and required cleanup rather than indiscriminately disabling every boolean.

## Identity and Git transport decisions

Confirmed by J: initially private to J only, with no invited users or anonymous repository browsing. Provision access only for J, including local admin recovery; keep self-registration and automatic external account creation closed. The corresponding configuration is `[service] REQUIRE_SIGNIN_VIEW=true`, `DISABLE_REGISTRATION=true`, `SHOW_REGISTRATION_BUTTON=false`, and `[repository] FORCE_PRIVATE=true`, `DEFAULT_PRIVATE=private`. Force-private governs new repositories; review existing visibility if importing later. Native Pocket ID login with local recovery and both HTTPS and SSH Git transport are confirmed.

Confirmed by J: use native Pocket ID OIDC for web login, with local administrator recovery access. Restrict the OIDC client to J rather than broad shared user groups. Keep local login available with a generated recovery credential in a Secret, and retain MFA/account-security facilities. Verify recovery works when Pocket ID is unavailable. Do not enable email confirmation with no working mailer. Keep `[oauth2_client] ENABLE_AUTO_REGISTRATION=false`; determine and test explicit account provisioning/linking before installation, including rejection of other Pocket ID users. The local recovery account is `forgejo-recovery`; J has a separate pre-provisioned OIDC administrator account. Forgejo's OAuth2 provider remains disabled; consuming Pocket ID OIDC is a separate capability.

Confirmed by J: enable both HTTPS and SSH for Git. Set `[repository] DISABLE_HTTP_GIT=false`, `[server] DISABLE_SSH=false` and `START_SSH_SERVER=true` for the proposed rootless image. Use scoped access tokens for HTTPS Git and registered SSH keys for SSH Git. Keep the web interface on HTTPS. Confirmed by J: SSH must also use `git.apps.home`. Plan external port 22 with `[server] SSH_DOMAIN=git.apps.home`, `SSH_PORT=22` and rootless `SSH_LISTEN_PORT=2222`. Persist host keys. An HTTPRoute alone does not carry SSH. Do not put a browser-only authentication proxy in front of Git/API traffic without testing non-browser clients.

## Fit with this repository

Follow [adding applications](adding-apps.md): eventually use `kubernetes/services/forgejo/`, `owner: apps`, and component namespace `forgejo`. Use the existing Helm/ArgoCD renderer, HTTPRoute/gateway conventions, SOPS secrets and optional CNPG/OIDC helpers. Confirm ArgoCD can pull the OCI chart before enabling the service. Publishing an enabled declaration to `main` can auto-deploy.

Confirmed by J: start with one Forgejo pod and one CNPG PostgreSQL instance, both using retained `local-bulk` storage on NODE-2. NODE-2 downtime takes Forgejo offline; node-failure availability is outside the initial design. Use `replicaCount: 1` and `db.instances: 1`. The deployment uses the rootless image. Chart 17.1.6 defaults to SQLite and has no bundled PostgreSQL/Valkey workload dependencies; old examples with those subchart enablement flags are obsolete. Confirmed by J: use PostgreSQL via CNPG, not the chart's default SQLite. Reuse the existing component `db` block to create `forgejo-db` in namespace `forgejo`, with database/owner `forgejo`, write service `forgejo-db-rw` and application credentials from `forgejo-db-app`. Configure Forgejo with `DB_TYPE=postgres` and wire credentials through Secret references. Confirmed by J: request 50 GiB for Forgejo repositories/application data and 10 GiB for PostgreSQL. PostgreSQL 16 was selected to match the existing CNPG deployments; the instance count, storage class and PVC sizes are confirmed. J manages backups separately and explicitly deferred backup work from this setup. The current hostPath-based provisioner does not configure per-volume disk quotas; these PVC requests are not enforced capacity limits. Choosing CNPG alone does not establish backups. Internal cache/session and disk queue avoid another service; the chart warns of memory pressure under load, despite also providing a single-pod recipe. Monitor and size the actual workload.

Confirmed by J: use `git.apps.home` for the web interface and HTTPS clone URLs, with `[server] DOMAIN=git.apps.home` and `ROOT_URL=https://git.apps.home/`. Use the existing apps gateway for HTTPS; verify DNS, certificate coverage and trusted proxy addresses during implementation. SSH is also confirmed on `git.apps.home`; the shared-IP implementation below has been deployed and verified. Use gateway TLS termination; leave Forgejo ACME off. Use the confirmed `local-bulk` storage class for both Forgejo data and PostgreSQL. Set Forgejo persistence size to `50Gi` and `db.storage.size` to `10Gi`. Choose an update strategy appropriate to one writable replica. Verify actual PV retention and node affinity before use; `local-bulk` is node-local retained storage, not HA. Persist repositories, database, application data and stable encryption secrets. Confirmed by J: backups are managed separately; skip backup configuration and restore rehearsals in this task. Do not make selecting a backup destination or verifying external backup coverage a prerequisite for this preparation or installation. External backup coverage has not been inspected. Follow the upgrade guide for future schema migrations; an image downgrade alone is not a rollback plan.

Deployment checks cover shared-IP SSH exposure, PostgreSQL connectivity, and explicit OIDC account provisioning. Audience is confirmed as J only; Git transport is confirmed as both HTTPS and SSH; web login is confirmed as Pocket ID with local admin recovery; release track is confirmed as latest stable with an exact version pin; database is confirmed as PostgreSQL via CNPG; web/HTTPS and SSH hostname is confirmed as `git.apps.home`. Render the pinned upstream chart and repository roots, inspect generated app.ini including chart overrides, run `just check`, and review resources. After installation: verify login and recovery; clone/push/pull; anonymous denial; disabled features through UI and relevant API paths; persistence across restart. Backup configuration and restoration testing are outside this task by J's instruction. See the service README for the completed runtime checks, including J’s confirmation of successful interactive Pocket ID login.


## Same hostname for HTTPS and SSH

J selected the same hostname for both protocols. Proposed implementation uses the existing apps gateway IP `10.10.10.200`: the gateway continues serving HTTPS on 443, while a Forgejo SSH LoadBalancer Service serves port 22 and targets the rootless SSH listener on 2222.

The pinned [Cilium 1.19.7 LB IPAM documentation](https://github.com/cilium/cilium/blob/v1.19.7/Documentation/network/lb-ipam.rst) supports sharing an IP across Services with non-conflicting ports. Set a common `lbipam.cilium.io/sharing-key`, explicitly request the existing address for the SSH Service, and set reciprocal `lbipam.cilium.io/sharing-cross-namespace` allowances scoped to `gateway-system` and `forgejo`. Apply gateway Service annotations through its declarative controller input, not manual edits to generated resources. Verify annotation propagation, traffic-policy compatibility, allocation and L2 advertisement before rollout; preserve the gateway address and existing HTTPS routes.

The [1.19.7 Gateway API support list](https://github.com/cilium/cilium/blob/v1.19.7/Documentation/network/servicemesh/gateway-api/gateway-api.rst) does not include TCPRoute. Do not use newer Cilium documentation to assume support or upgrade the network stack as part of this proposal.

SSH selects the destination by IP and port, not an HTTP Host header or TLS SNI. Consequently, any other DNS name resolving to this shared IP can also reach Forgejo on port 22. SSH authentication and Forgejo authorization still apply. Do not add a second DNS address expecting clients to pick one by protocol. The sharing annotations have been applied declaratively and both HTTPS and SSH access verified against the shared address.
