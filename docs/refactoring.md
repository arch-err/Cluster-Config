# State-preserving repository refactoring

## Rule

The user requires preserving deployed resource definitions and behavior while reorganizing their source. Any runtime difference, including a pre-existing difference, blocks synchronization unless J explicitly approves that specific exception. Missing comparison data and comparison errors also block synchronization.

Switching this repository's ArgoCD Git sources to `main` and disabling automatic sync are explicitly authorized administrative changes. That authorization does not permit applying unrelated resources through a parent sync, changing chart/image versions, or applying workload differences incidentally.

## Current status

Live access is available through `admin@cluster`. All 65 repository Applications now have `spec.syncPolicy.automated.enabled: false`. The outstanding infra sync (started 2026-08-31, waiting for deletion of Kadalu) was terminated, and no operation remained after the freeze. No ApplicationSets were present. Matching explicit freeze settings were published in commit `d0d7f2e`. All 65 live Applications now use `main` for this repository’s Git source, with auto-sync disabled. Verification showed the source patches changed only those Git revision fields, with no active sync operations afterward. Of 41 Applications initially marked `skip-reconcile`, comparison was resumed for the 21 without deletion timestamps; the 20 pending-deletion Applications remain skipped. Their cached Synced status is not evidence of a clean diff.

Live inspection confirmed Grafana Git-sync and the three Homepage asset URLs still reference `v2`. The earlier promotion changed those to `main` in desired state; this refactoring preparation restores their `v2` references to match deployed behavior. Keep referenced files available at any branch/path fetched directly by running workloads; ArgoCD auto-sync settings do not suspend in-pod Git-sync processes.

## Freeze and baseline procedure

1. Inspect live Applications, any ApplicationSets or other owners, the installed ArgoCD version, and active/pending operations. Identify every Application belonging to this repository, including secret roots and ArgoCD's own child Application.
2. Capture source specifications, resolved Git/chart revisions, diff settings, resource identities/ownership, health, and baseline differences. Store sensitive manifests/diffs securely outside Git; do not expose Secret payloads in reports.
3. Disable automated sync at the top of the ownership hierarchy first, then on all relevant children. Do not switch sources while an owner could overwrite a child's freeze. Verify the freeze by re-reading live specs. Disabling automation does not cancel an already-running sync; establish that no operation remains before continuing.
4. Publish matching declarative freeze settings only after live automation is verified off. Preserve unrelated Application configuration and manual prune/delete guards.
5. Update only the authorized Git source fields on existing Application objects to `main`, with automated sync still off. Multi-source Applications need their repository source updated separately from their upstream chart source. Do not bulk-sync roots to propagate these changes.
6. Hard-refresh roots and children and record the exact resolved commit for each comparison. Establish the actual baseline before reorganizing source. Existing drift is not permission to reconcile it.

The freeze, termination, and Git source-switching steps are complete. No workload sync, deletion approval, or finalizer removal was performed. Twenty Application objects already had deletion timestamps before the freeze; those timestamps were not created or cleared by this work. Retain their skip-reconcile annotations: removing them could resume finalization even with automated sync disabled.

## Gate for each source change

- Preserve Application names, Helm release names, destination namespaces, resource names, tracking/ownership, and desired resource sets while moving files.
- Compare complete renders keyed by resource identity, not YAML file order. Include upstream chart renders; local platform-chart output alone does not include child workloads.
- Hard-refresh and inspect ArgoCD diffs for every affected parent and child against the exact candidate commit. A green root does not establish that its children are unchanged.
- Audit existing ignore rules and excluded resources. The current whole-spec Gateway API ignores require supplementary comparison; never add ignores to make the gate pass. Separate API-generated bookkeeping from desired configuration explicitly.
- Do not assume complete Secret coverage from the CLI: its help says Kubernetes Secrets are ignored, but this installed comparison path emitted Cilium/Grafana Secret-data differences. Inspect protected manifests/data separately where needed and never print secret payloads in a report.
- Check all hooks and jobs that could run or be recreated. A zero ordinary-resource diff is necessary but is not sufficient to authorize a sync with side effects.
- Preserve files fetched directly by workloads and external consumers. A Git push can affect those consumers without an ArgoCD sync.
- Do not accept unexpected resource creation, deletion, ownership transfer, PVC changes, rollouts, image/chart resolution changes, or secret regeneration. Stop and present the exact difference if it cannot be removed by correcting the source.
- Bind any exception to a specific resource/field/change and record J's explicit approval before applying it. No blanket exceptions for cleanup or pre-existing drift.

Use refresh/diff as the normal verification operation. Do not run a no-op sync merely to test the rewrite. If synchronization is needed, repeat the gate against the exact commit immediately beforehand and inspect the complete operation, including hooks. Do not sync a moving branch against a stale diff result.

Auto-sync remains off throughout the refactor. Re-enabling it is a separate explicit decision, not an automatic final step.

## Baseline findings

Before switching Git sources, 45 non-deleting Applications were hard-refreshed and compared on `v2`: 37 had no CLI diff, 7 had differences, and Loki failed comparison. Twenty pending-deletion Applications remained blocked/skipped. No-diff here describes the CLI result, not a blanket approval to sync or proof of complete coverage.

- `apps` and `infra`: parent-level desired/live differences, including retained resources and administrative Application differences.
- `apps-secrets`: differences involving retained SopsSecret resources.
- `argocd`: wildcard chart selection resolved chart `10.8.1`, while deployed resources carry chart `10.4.2`. No chart upgrade was applied.
- `cilium`: generated CA/TLS Secret-data differences.
- `grafana`: generated admin credential and dependent checksum differences.
- `kube-state-metrics`: replica-count difference.
- `loki`: CLI comparison failed with `Object 'Kind' is missing in '{}'`. This is an error, not a clean diff.

These are pre-existing blockers. Any workload synchronization remains prohibited until the gate passes or J approves a specific exception.

The post-switch hard-refresh comparison against `main` returned the same per-Application classifications: 37 no-diff, 7 diff, 1 comparison error, and 20 blocked pending deletion. All 37 previously clean Applications remained clean. Before/after checks of 60 Deployments, StatefulSets, DaemonSets, and CronJobs found identical specifications and object identities. All 65 Applications were rechecked: repository Git source `main`, auto-sync disabled, no active sync operations. No workload sync was performed.

Private baseline snapshots, raw diffs, and verification records are kept outside Git under `~/.local/state/cluster-config/refactor-P0x6LU2j/` with restricted permissions. They can contain sensitive configuration and must not be copied into public reports. The approved service layout is active. All 65 live Application source pointers use the new paths; obsolete compatibility sources have been removed.

## Approved Loki and kube-state-metrics restart (2026-09-06)

J explicitly authorized restarting/rebuilding **Loki and kube-state-metrics only**, including loss of their old monitoring data. Prometheus, Grafana, and all other blockers remain outside that exception.

Both workloads were scaled to zero while Git requested one replica. Loki's live StatefulSet still used the immutable `kadalu.replica2` claim template; desired state already selected `local-bulk`. No Loki pod or PVC existed in `monitoring`. Server-side dry-run confirmed the immutable-field conflict. The stopped Loki StatefulSet was deleted and recreated through a resource-scoped Argo sync, provisioning a fresh 30 GiB `local-bulk` PVC. KSM's Deployment was synced to one replica. No other resources were selected and pruning was not requested.

Both syncs used Git commit `ad3d106344012377a38a600c5953de96ccfc542d`, Loki chart `6.21.0`, and KSM chart `5.27.1`; no software versions changed. Both operations succeeded and subsequent hard-refresh CLI comparisons returned zero diff. Loki's previous CLI comparison error no longer reproduces. KSM node metrics are arriving in Prometheus for all three nodes. Loki is ready and a log query returned newly ingested log entries. A full workload check confirmed that only Loki and KSM specifications/identities changed; all 65 Application specs and pending-deletion guards remain unchanged. Automatic sync remains disabled.

The earlier baseline above is historical: kube-state-metrics drift and Loki's comparison error have now been resolved under this explicit exception. Other baseline differences and pending-deletion guards remain in place. Protected verification material is under `~/.local/state/cluster-config/blocker-review/`.

## ArgoCD chart pin (2026-09-06)

J approved pinning the ArgoCD chart to `10.4.2`, matching the chart labels on live resources. The previously omitted version rendered as `*` and resolved `10.8.1`, producing metadata and pod-template differences despite unchanged container images. The service declaration now pins `10.4.2`; the live Application's chart source is updated directly, with auto-sync disabled. This is a source-selection change, not authorization for an ArgoCD workload sync or restart. The earlier wildcard baseline above is historical. After the source change, a hard-refresh CLI comparison returned zero diff. All Argo workload specifications and identities remained unchanged; only the approved Application chart revision changed, with no sync operation. `just check` passed.

## Approved Hubble cert-manager migration (2026-09-06)

J approved moving Hubble certificate management to the existing cert-manager, including necessary ownership changes and leaf certificate rotation. The existing Cilium CA and Secret names are preserved. The encrypted CA is managed through `infra-secrets`, a namespaced Issuer through `infra`, and two chart-generated Certificates through `cilium`. Only these selected resources are synchronized; the old direct Argo tracking on the three Secrets is removed as ownership transfers, without deleting or pruning the Secrets. Auto-sync remains disabled.

Local comparison of Cilium chart `1.19.7` before/after the change found no changes to shared resources or pod templates: three generated Secret declarations are replaced by two Certificate declarations. Server-side dry-run accepted the SopsSecret, Issuer, and Certificates. The three resource-scoped sync operations succeeded at commit `b29d4e2`, using Cilium chart `1.19.7`. The SopsSecret operator adopted the existing CA Secret after an explicit owner-reference transfer, and its decrypted certificate/key bytes were verified unchanged. Both Certificates became Ready by adopting the existing leaf certificates; no rotation was needed. Subsequent Cilium and infra-secrets hard-refresh comparisons returned zero diff. Hubble Relay reported healthy with 3/3 nodes connected. All workload specs and identities, Cilium/Hubble pod restart counts, Application specs, and pending-deletion guards remained unchanged. The earlier Cilium certificate-drift baseline is now resolved. See [Hubble TLS ownership and recovery](../kubernetes/platform/networking/cilium/README.md).

## Approved Grafana admin credential migration (2026-09-12)

J approved generating a new Grafana local admin password and storing it encrypted in SOPS. `infra-secrets` now owns the `grafana-admin` SopsSecret, whose operator adopts the existing `monitoring/grafana` Secret. The username and other Secret fields are preserved. Grafana references it using `admin.existingSecret`; the chart no longer generates credentials or a password-dependent checksum.

Local render comparison found exactly one removed chart Secret and the removal of `checksum/secret` from Grafana's Deployment pod template. `just check` and the SopsSecret server-side dry-run passed. Resource-scoped Argo syncs applied the SopsSecret and Grafana Deployment at commit `9ce456a`, with Grafana chart `8.7.1`; no pruning or software upgrades were requested. The local admin password was explicitly reset in the existing PostgreSQL database using the installed Grafana CLI and stdin, then authenticated successfully as admin user ID 1 using the Kubernetes Secret credentials. The Grafana rollout completed successfully. Subsequent hard-refresh comparisons for Grafana and infra-secrets both returned zero diff; the earlier Grafana credential-drift baseline is resolved.

Only the Grafana Deployment checksum changed across the workload-spec audit; other workloads, Application specs/manual-sync policies, and pending-deletion guards were preserved. Pocket ID settings, database configuration, and dashboard sources were unchanged. See [credential recovery and rotation](../kubernetes/platform/observability/grafana/README.md). Private verification records are under `~/.local/state/cluster-config/grafana-admin/`.

## Agent Vault retirement (2026-09-12)

J explicitly approved retiring Agent Vault. Its namespace was already absent and no PV referenced that namespace. The disabled service declaration, values, encrypted master-password manifest, Homepage tile, dedicated gateway passthrough listener, and backup-script entry are removed. No Agent Vault TLSRoute remained. Historical backups and local migration notes are not removed.

The stale Application was already marked for deletion on 2026-08-31. Completing this specific retirement releases its Argo deletion finalizer only after confirming its namespace and volume claims are gone; other pending-deletion Applications remain frozen. No parent bulk-sync is authorized by this retirement. Retirement is complete: the Application is gone, the gateway changed only by removal of its dedicated listener, and Homepage received only its tile/config checksum change via a scoped sync. Homepage rolled out successfully and returned zero hard-refresh diff. All 64 remaining Application specs and deletion guards are unchanged; 19 Applications remain pending deletion. `just check` passed.

## Approved batch retirement and fresh service restore (2026-09-12)

J approved retiring `hermes-oauth2`, `hookshot`, `kadalu`, `kanban`, `kivra-sync`, `kivra-sync-oauth2`, `matrix`, `mattermost`, `mosquitto`, `pingvin-share`, `protonmail-bridge`, `qbittorrent`, `samba`, `t3-oauth2`, `vaultwarden`, `zigbee2mqtt`, and `zigbee2mqtt-oauth2`. J explicitly requested bringing **ntfy and Stirling PDF online with fresh storage**, permitting loss of their old data. All 19 destination namespaces were already absent.

The retired service directories and encrypted secret manifests, dedicated Homepage links, backup entries, and external Matrix route/listener are removed. The disabled shared-media source only declared qBittorrent's legacy storage and is removed with it; active media-service storage is untouched. The database renderer's retired Kadalu default becomes `local-bulk`, with no changes to currently rendered database resources. The external Hermes agent's separate read-only RBAC remains: retiring its OAuth proxy does not retire that independent access path. No external-host software, historical backups, or physical disks are erased.

Kadalu has no active PVCs. Two released Retain PV records belong to n8n and Home Assistant and remain preserved as recovery metadata. Retired Kadalu RBAC and its empty CRD can be removed without deleting those records. The old Application deletion finalizers are released only for the explicitly approved list, after verifying destination namespaces are absent. ntfy and Stirling PDF receive newly created manual-sync Applications and `local-bulk` PVCs (5 GiB and 2 GiB respectively), retaining chart/image versions. Bulk root synchronization remains prohibited.

Completed verification: all 19 stale Application records are gone; ntfy and Stirling PDF have new manual-sync Applications. Twelve retired Kadalu RBAC objects, its empty CRD, and twelve retired OIDC bootstrap ConfigMaps/ServiceAccounts were removed. The external Matrix route/listener and five Homepage tiles were removed. Both restored services have bound fresh PVCs, healthy endpoints, accepted/resolved HTTPRoutes, and zero hard-refresh diff. Stirling PDF required a 180-second liveness startup allowance and an explicit `/configs` PVC mount in the pinned chart; no software versions changed. Homepage and apps-secrets also return zero diff.

There are 47 Applications, no pending deletions or operations, and auto-sync is disabled everywhere. Workload comparison found only the new ntfy/Stirling Deployments and the approved Homepage checksum change; all other workload specs and identities are unchanged. Both n8n/Home Assistant legacy PV records are unchanged. The remaining `apps`/`infra` root differences concern retained storage/resources and OIDC jobs outside this retirement. `just check` passed. Private audit records are under `~/.local/state/cluster-config/retire-batch/`.

## OIDC Job cleanup and storage review (2026-09-12)

J authorized pruning the OIDC Jobs while requesting a cautious review of remaining migration storage. Live inspection found no remaining OIDC bootstrap Jobs: TTL cleanup had already deleted them. The source still declared 13 Jobs, causing missing-resource diffs and potential re-execution on root sync. Job rendering is now explicitly opt-in with `oidc.bootstrapJob: true`. Local canonical comparison confirms only those 13 Job declarations are removed; all client settings, scripts, RBAC, Secrets, and workload resources remain unchanged. Tests cover default-off, explicit-on, and explicit-off behavior. No OIDC API call, credential rotation, or Job execution was performed.

The [storage review](storage-review.md) records the 32 bound claims, four released PVs, and shared-library alias. No active PVC uses Kadalu. Storage differences are tracking/sync-wave metadata; Grafana's database CPU quantity has an equivalent formatting difference. Storage was not mutated or pruned.

## Approved source layout

Services own their declarations, upstream values, resources, and encrypted secrets under `kubernetes/services/`. Shared cluster infrastructure lives under `kubernetes/platform/` by function. The shared chart at `kubernetes/` renders the existing four roots using `kubernetes/releases/`. Directory placement does not change Application ownership; each service declares its existing `owner` explicitly. See [chart conventions](platform-chart.md).

All four local resource sets were compared by identity and full content: apps 117, infra 76, apps-secrets 22, infra-secrets 5. Only child Application values-file source paths differ. Moved values, encrypted secrets, dashboards, and images retain their original bytes. Disabled services retain their independently owned secrets. Local checks exercise that boundary, owner selection, source references, and missing values files.

The migration published compatibility files first, changed only live source pointers with manual sync enforced, and verified Argo comparisons before removing obsolete paths. The new-layout hard refresh returned the same per-Application results: 37 no-diff, 7 existing diffs, one Loki comparison error, and 20 blocked pending deletion. All 60 workload specifications and identities remained unchanged. All 65 Application specs were verified against the expected source-only edits, with deletion guards preserved and no operations running. No workload synchronization was performed.

Protected layout snapshots and canonical render comparisons are under `~/.local/state/cluster-config/service-layout/`; live comparisons are in the `service-layout-before` and `service-layout-after` directories alongside the earlier baseline. The existing drift and unavailable comparisons remain blockers to synchronization.

## References

- [ArgoCD automated sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
- [ArgoCD diff customization](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)
- [ArgoCD sync phases and hooks](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
