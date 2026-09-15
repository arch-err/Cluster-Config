# Repository state and branch migration

Reviewed 2026-09-14. Scope: align repository organization and documentation with the `v2` production baseline, with explicitly approved runtime exceptions recorded in [the refactoring protocol](refactoring.md). Software upgrades remain separately scoped.

## History and archive

The original `main` (`a502d0eb5072013555848b1b649ebc89618e1e18`) and `v2` (`1688b23bbaf56f06d90422a597f8f0a2bb15c42c`) have unrelated histories. The cleanup starts from the `v2` tree and joins the old `main` as a parent using an `ours` merge. This preserves history and permits a fast-forward promotion of `main` without a force-push.

The annotated tag `archive/main-2026-09-06` preserves the exact old `main`. Browse it with `git show archive/main-2026-09-06:README.md` or use a detached worktree for historical inspection. Do not use that archive as the source for the current cluster.

## Branch dispositions

| Branch | Disposition |
| --- | --- |
| `main` | Maintained configuration and documentation after promotion |
| `v2` | Retired after migrating Grafana/Homepage consumers to `main`; exact baseline preserved by `archive/v2-2026-09-14` |
| `storage-local-bulk` | Pruned locally: identical to the production baseline. Its existing worktree remains detached at `1688b23`; no worktree files were removed. |
| `feat/public-isolation-poc` | Keep: worktree has modified `.gitignore`/`justfile` and untracked PoC files, despite no unique committed history |
| `feat/n8n-infra-oauth` | Pruned remotely: feature merged through PR #5; the unapplied follow-up fix was subsequently discarded with PR #6. |
| `fix/n8n-syncwave-namespace` | Deleted by user decision; PR #6 closed without merging the namespace-ordering change. |
| `fix/homepage-admin-discovery` | Deleted by user decision; PR #4 closed without merging the instance-discovery changes. |

The user chose to discard both fixes and retain the public-isolation PoC. PRs #4 and #6 are closed; neither fix was merged. The PoC's uncommitted work and the original main worktree's local storage-migration notes/scripts are preserved separately; they are not silently included in production configuration.

## GitOps cutover

The source migration and runtime cleanup are complete. On September 14, J approved enabling auto-sync after safety checks. The [refactoring protocol](refactoring.md) records the current policy and historical freeze; automatic pruning remains disabled.

The archive tag and promoted `main` have been published. All 47 remaining Applications use `main` for their Git sources and have auto-sync and self-healing enabled, with automatic pruning disabled, with no pending Application deletions or operations. After the approved cleanup, all 47 return zero hard-refresh diff under the existing comparison rules. Grafana dashboard Git-sync and all three Homepage background URLs also use `main` and the reorganized paths. The former `v2` baseline is preserved by `archive/v2-2026-09-14`.

The maintained ArgoCD source manifests point to `main`: the source chart defaults and all four bootstrap root Applications. Grafana dashboard Git-sync and Homepage asset URLs now use `main`, following an explicitly approved source migration. Existing root Applications are not automatically changed by editing the bootstrap file. Live inspection confirmed the sources followed `v2` before the freeze. The subsequent cutover status is recorded in the refactoring protocol.

The freeze, Git-source cutover, and source layout migration are complete. The last dashboard and asset consumers were migrated and verified on 2026-09-14, allowing `v2` to be retired. The public-isolation PoC worktree remains untouched, with its obsolete `origin/v2` upstream association removed.

Rollback requires checking both root and child source paths and revisions against the captured baseline. Never use the unrelated legacy-main archive as the production rollback target, or sync roots just to propagate a pointer change.

## Known gaps retained explicitly

| Area | Finding / follow-up |
| --- | --- |
| Clean bootstrap | Gateway API CRDs are pinned to Cilium 1.19's supported `v1.4.1`; bootstrap Helm commands are still not pinned to GitOps revisions. Rebuild is unverified. |
| Backup | Inventory is stale; `--quiesce` never calls the scale helpers. See [backup status](backup-manual.md). |
| Storage | Kadalu deployment retired; the database template now defaults to local-bulk. Obsolete released PV records were removed by explicit approval; current application storage and Disk C backups remain preserved. |
| Claim recovery | Excalidash and n8n database claims were recreated and rebound to their original retained PVs after verified backups. All storage deletion timestamps are cleared; data checks and the n8n restore test passed. See [storage review](storage-review.md). |
| n8n ordering | Discarded PR #6 proposed wave `-1` instead of `3`. Current behavior is unchanged; fresh bootstrap ordering remains unverified. |
| Homepage | PR #4 was discarded. Existing discovery behavior is unchanged; no fix is pending. |
| Identity | Grafana checks `Administrators`, while other declarations use lowercase group names. Verify actual claims before editing policy. |
| n8n SSRF | `N8N_SSRF_PROTECTION_ENABLED` is currently `false`; a documented temporary exception remains in values. |
| GitOps drift | Broad Gateway API ignores removed; existing StatefulSet/field-manager exceptions remain. Booklore source now matches the existing direct route; authentication redesign is separate. |
| CA source | `kubernetes/platform/identity/cert-manager/reference/home-root-ca.yaml` is excluded from Helm under the service’s reference directory; retain pending provenance review. |
| Validation | `just check` covers local Helm rendering and shell syntax. It does not validate upstream charts, live health, or a fresh rebuild. No CI workflow is configured. |

## Maintenance routine

Update docs with configuration changes, keep inactive services visibly marked, review per-PVC data disposition before retirement, and keep software upgrades as separately scoped changes. Do not equate a committed file with a running service or an archived branch with a data backup.
