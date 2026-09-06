# State-preserving repository refactoring

## Rule

The user requires preserving deployed resource definitions and behavior while reorganizing their source. Any runtime difference, including a pre-existing difference, blocks synchronization unless J explicitly approves that specific exception. Missing comparison data and comparison errors also block synchronization.

Switching this repository's ArgoCD Git sources to `main` and disabling automatic sync are explicitly authorized administrative changes. That authorization does not permit applying unrelated resources through a parent sync, changing chart/image versions, or applying workload differences incidentally.

## Current status

Live access is available through `admin@cluster`. All 65 repository Applications now have `spec.syncPolicy.automated.enabled: false`. The outstanding infra sync (started 2026-08-31, waiting for deletion of Kadalu) was terminated, and no operation remained after the freeze. No ApplicationSets were present. Matching explicit freeze settings are prepared in the four bootstrap roots and generated child Applications. Source switching and diff collection are tracked below as they complete. Of 41 Applications initially marked `skip-reconcile`, comparison was resumed for the 21 without deletion timestamps; the 20 pending-deletion Applications remain skipped. Their cached Synced status is not evidence of a clean diff.

Live inspection confirmed Grafana Git-sync and the three Homepage asset URLs still reference `v2`. The earlier promotion changed those to `main` in desired state; this refactoring preparation restores their `v2` references to match deployed behavior. Keep referenced files available at any branch/path fetched directly by running workloads; ArgoCD auto-sync settings do not suspend in-pod Git-sync processes.

## Freeze and baseline procedure

1. Inspect live Applications, any ApplicationSets or other owners, the installed ArgoCD version, and active/pending operations. Identify every Application belonging to this repository, including secret roots and ArgoCD's own child Application.
2. Capture source specifications, resolved Git/chart revisions, diff settings, resource identities/ownership, health, and baseline differences. Store sensitive manifests/diffs securely outside Git; do not expose Secret payloads in reports.
3. Disable automated sync at the top of the ownership hierarchy first, then on all relevant children. Do not switch sources while an owner could overwrite a child's freeze. Verify the freeze by re-reading live specs. Disabling automation does not cancel an already-running sync; establish that no operation remains before continuing.
4. Publish matching declarative freeze settings only after live automation is verified off. Preserve unrelated Application configuration and manual prune/delete guards.
5. Update only the authorized Git source fields on existing Application objects to `main`, with automated sync still off. Multi-source Applications need their repository source updated separately from their upstream chart source. Do not bulk-sync roots to propagate these changes.
6. Hard-refresh roots and children and record the exact resolved commit for each comparison. Establish the actual baseline before reorganizing source. Existing drift is not permission to reconcile it.

The freeze and termination steps are complete. No workload sync, deletion approval, or finalizer removal was performed. Twenty Application objects already had deletion timestamps before the freeze; those timestamps were not created or cleared by this work. Retain their skip-reconcile annotations: removing them could resume finalization even with automated sync disabled.

## Gate for each source change

- Preserve Application names, Helm release names, destination namespaces, resource names, tracking/ownership, and desired resource sets while moving files.
- Compare complete renders keyed by resource identity, not YAML file order. Include upstream chart renders; local platform-chart output alone does not include child workloads.
- Hard-refresh and inspect ArgoCD diffs for every affected parent and child against the exact candidate commit. A green root does not establish that its children are unchanged.
- Audit existing ignore rules and excluded resources. The current whole-spec Gateway API ignores require supplementary comparison; never add ignores to make the gate pass. Separate API-generated bookkeeping from desired configuration explicitly.
- ArgoCD CLI diff omits Kubernetes Secrets. Compare their desired data through a separate protected process before claiming the gate passes; never print secret payloads in a report.
- Check all hooks and jobs that could run or be recreated. A zero ordinary-resource diff is necessary but is not sufficient to authorize a sync with side effects.
- Preserve files fetched directly by workloads and external consumers. A Git push can affect those consumers without an ArgoCD sync.
- Do not accept unexpected resource creation, deletion, ownership transfer, PVC changes, rollouts, image/chart resolution changes, or secret regeneration. Stop and present the exact difference if it cannot be removed by correcting the source.
- Bind any exception to a specific resource/field/change and record J's explicit approval before applying it. No blanket exceptions for cleanup or pre-existing drift.

Use refresh/diff as the normal verification operation. Do not run a no-op sync merely to test the rewrite. If synchronization is needed, repeat the gate against the exact commit immediately beforehand and inspect the complete operation, including hooks. Do not sync a moving branch against a stale diff result.

Auto-sync remains off throughout the refactor. Re-enabling it is a separate explicit decision, not an automatic final step.

## Structural direction to discuss

Keep Helm and ArgoCD. First separate the monolithic extras template into resources with clear owners while preserving the existing Application/resource boundaries. Then group component declarations, values, and supporting resources by service, with shared infrastructure in clearly named locations. Decide the exact directory layout before moving files; changing Application ownership is not required just to improve source organization.

## References

- [ArgoCD automated sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
- [ArgoCD diff customization](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)
- [ArgoCD sync phases and hooks](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
