# Repository state and branch migration

Reviewed 2026-09-06. Scope: align repository organization and documentation with the `v2` production baseline. Software versions, application enablement, storage resources, and access policy are not upgraded or redesigned here.

## History and archive

The original `main` (`a502d0eb5072013555848b1b649ebc89618e1e18`) and `v2` (`1688b23bbaf56f06d90422a597f8f0a2bb15c42c`) have unrelated histories. The cleanup starts from the `v2` tree and joins the old `main` as a parent using an `ours` merge. This preserves history and permits a fast-forward promotion of `main` without a force-push.

The annotated tag `archive/main-2026-09-06` preserves the exact old `main`. Browse it with `git show archive/main-2026-09-06:README.md` or use a detached worktree for historical inspection. Do not use that archive as the source for the current cluster.

## Branch dispositions

| Branch | Disposition |
| --- | --- |
| `main` | Maintained configuration and documentation after promotion |
| `v2` | Retain until the live cutover below has been completed and verified |
| `storage-local-bulk` | Pruned locally: identical to the production baseline. Its existing worktree remains detached at `1688b23`; no worktree files were removed. |
| `feat/public-isolation-poc` | Keep: worktree has modified `.gitignore`/`justfile` and untracked PoC files, despite no unique committed history |
| `feat/n8n-infra-oauth` | Pruned remotely: feature merged through PR #5; the unapplied follow-up fix was subsequently discarded with PR #6. |
| `fix/n8n-syncwave-namespace` | Deleted by user decision; PR #6 closed without merging the namespace-ordering change. |
| `fix/homepage-admin-discovery` | Deleted by user decision; PR #4 closed without merging the instance-discovery changes. |

The user chose to discard both fixes and retain the public-isolation PoC. PRs #4 and #6 are closed; neither fix was merged. The PoC's uncommitted work and the original main worktree's local storage-migration notes/scripts are preserved separately; they are not silently included in production configuration.

## GitOps cutover

**Updated constraint:** the user now requires disabling auto-sync before switching live sources and preserving zero unapproved runtime diffs. Follow [the refactoring protocol](refactoring.md); it supersedes the earlier cutover sequence below. The live freeze is verified; source cutover and the baseline diff report are tracked in that protocol.

The archive tag and promoted `main` have been published. The live cutover remains pending; publishing the repository did not change the existing `v2` branch.

The maintained ArgoCD source manifests point to `main`: both platform value sets and all four bootstrap root Applications. Grafana dashboard Git-sync and Homepage asset URLs retain `v2` to match the live runtime configuration. Existing root Applications are not automatically changed by editing the bootstrap file. Live inspection confirmed the sources followed `v2` before the freeze. The subsequent cutover status is recorded in the refactoring protocol.

Before changing live roots:

1. Publish the archive tag and prepared `main`, and confirm both remote tips. Keep `v2` intact.
2. Inspect all four live root Application specs, current source revisions, sync policies, and health. Save their non-secret specifications and resolved commit IDs outside the repository for rollback.
3. Render the old and new local platform charts. The intended semantic difference is the repository revision; there must be no component or storage-resource removals. Inspect upstream desired-versus-live resources too: existing chart version ranges can resolve differently even though no version constraint was edited.
4. Verify current backups for affected stateful services. The retained backup helper is not adequate evidence by itself.
5. Change the existing root Applications' Git source revisions to the promoted main commit first if an immutable cutover is wanted, then to `main` for normal tracking. Inspect child revisions as they reconcile. Do not reinstall ArgoCD or re-run cluster bootstrap to accomplish this.
6. Verify all four roots and child Applications, workload health, routes, OIDC login, Grafana dashboard files, and Homepage asset loading. Grafana Git-sync and Homepage URL changes may cause their workloads to roll even though images are unchanged.
7. Only after successful verification, retire `v2` and retarget remaining development PRs to `main`.

Rollback requires checking both root and child source revisions: merely switching a root back to `v2` may not immediately replace every child revision or workload. Use the captured baseline, review the resulting diff, and verify reconciliation; never use the unrelated legacy-main archive as the production rollback target.

## Known gaps retained explicitly

| Area | Finding / follow-up |
| --- | --- |
| Clean bootstrap | Gateway API CRDs are pinned to `v1.1.0` in the justfile while GitOps Cilium is `1.19.x`; bootstrap Helm commands are not pinned to GitOps revisions. Rebuild is unverified. |
| Backup | Inventory is stale; `--quiesce` never calls the scale helpers. See [backup status](backup-manual.md). |
| Storage | Disabled services and the database template retain Kadalu references. Review before reuse; preserve data independently of code cleanup. |
| n8n ordering | Discarded PR #6 proposed wave `-1` instead of `3`. Current behavior is unchanged; fresh bootstrap ordering remains unverified. |
| Homepage | PR #4 was discarded. Existing discovery behavior is unchanged; no fix is pending. |
| Identity | Grafana checks `Administrators`, while other declarations use lowercase group names. Verify actual claims before editing policy. |
| n8n SSRF | `N8N_SSRF_PROTECTION_ENABLED` is currently `false`; a documented temporary exception remains in values. |
| GitOps drift | Whole-spec route ignores can mask differences; green status alone is insufficient. |
| CA source | `kubernetes/secrets/home-root-ca.yaml` is outside both managed secret directories; retain pending provenance review. |
| Validation | `just check` covers local Helm rendering and shell syntax. It does not validate upstream charts, live health, or a fresh rebuild. No CI workflow is configured. |

## Maintenance routine

Update docs with configuration changes, keep inactive services visibly marked, review per-PVC data disposition before retirement, and keep software upgrades as separately scoped changes. Do not equate a committed file with a running service or an archived branch with a data backup.
