# Repository state and branch migration

Reviewed 2026-09-06. Scope: align repository organization and documentation with the `v2` production baseline. Software versions, application enablement, storage resources, and access policy are not upgraded or redesigned here.

## History and archive

The original `main` (`a502d0eb5072013555848b1b649ebc89618e1e18`) and `v2` (`1688b23bbaf56f06d90422a597f8f0a2bb15c42c`) have unrelated histories. The cleanup starts from the `v2` tree and joins the old `main` as a parent using an `ours` merge. This preserves history and permits a fast-forward promotion of `main` without a force-push.

The annotated tag `archive/main-2026-09-06` preserves the exact old `main`. Browse it with `git show archive/main-2026-09-06:README.md` or use a detached worktree for historical inspection. Do not use that archive as the source for the current cluster.

## Branch dispositions

| Branch | Disposition |
| --- | --- |
| `main` | Maintained configuration and documentation after promotion |
| `v2` | Retain: deployed Grafana/Homepage still fetch files from this branch |
| `storage-local-bulk` | Pruned locally: identical to the production baseline. Its existing worktree remains detached at `1688b23`; no worktree files were removed. |
| `feat/public-isolation-poc` | Keep: worktree has modified `.gitignore`/`justfile` and untracked PoC files, despite no unique committed history |
| `feat/n8n-infra-oauth` | Pruned remotely: feature merged through PR #5; the unapplied follow-up fix was subsequently discarded with PR #6. |
| `fix/n8n-syncwave-namespace` | Deleted by user decision; PR #6 closed without merging the namespace-ordering change. |
| `fix/homepage-admin-discovery` | Deleted by user decision; PR #4 closed without merging the instance-discovery changes. |

The user chose to discard both fixes and retain the public-isolation PoC. PRs #4 and #6 are closed; neither fix was merged. The PoC's uncommitted work and the original main worktree's local storage-migration notes/scripts are preserved separately; they are not silently included in production configuration.

## GitOps cutover

**Updated constraint:** the user now requires disabling auto-sync before switching live sources and preserving zero unapproved runtime diffs. Follow [the refactoring protocol](refactoring.md); it supersedes the earlier cutover sequence below. The live freeze and Git-source cutover to `main` are verified; the baseline diff report is tracked in that protocol.

The archive tag and promoted `main` have been published. The live Git sources now point to `main`, with all 65 Applications held in manual-sync mode. No workload sync was performed. The `v2` branch remains unchanged and is still referenced by deployed Grafana/Homepage consumers.

The maintained ArgoCD source manifests point to `main`: the source chart defaults and all four bootstrap root Applications. Grafana dashboard Git-sync and Homepage asset URLs retain `v2` to match the live runtime configuration. Existing root Applications are not automatically changed by editing the bootstrap file. Live inspection confirmed the sources followed `v2` before the freeze. The subsequent cutover status is recorded in the refactoring protocol.

The freeze and Git-source cutover are complete. Source layout migration follows the refactoring protocol using direct Application source-pointer edits, with automatic sync disabled. Keep `v2` until its running dashboard and asset consumers are explicitly migrated and verified; that runtime change is outside this cleanup.

Rollback requires checking both root and child source paths and revisions against the captured baseline. Never use the unrelated legacy-main archive as the production rollback target, or sync roots just to propagate a pointer change.

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
| CA source | `kubernetes/platform/identity/cert-manager/reference/home-root-ca.yaml` is excluded from Helm under the service’s reference directory; retain pending provenance review. |
| Validation | `just check` covers local Helm rendering and shell syntax. It does not validate upstream charts, live health, or a fresh rebuild. No CI workflow is configured. |

## Maintenance routine

Update docs with configuration changes, keep inactive services visibly marked, review per-PVC data disposition before retirement, and keep software upgrades as separately scoped changes. Do not equate a committed file with a running service or an archived branch with a data backup.
