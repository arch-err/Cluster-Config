# Storage migration review — 2026-09-12

The initial review was read-only. J subsequently authorized the metadata cleanup recorded below. No storage directory, database contents, physical disk, or backup was modified. Kubernetes references identify current use; they do not establish backup completeness or whether old filesystem contents are recoverable.

## Current deployment

After cleanup and the approved claim repair, all 31 PVCs and 31 PVs are Bound, with no pending storage deletions, and none uses Kadalu: 22 claims use `local-bulk`, 3 use `local-path`, and 6 use explicitly bound static local PVs with an empty StorageClass. All PV identities and backing directories are preserved. Only the Excalidash and n8n database claim identities and their PV binding references changed during repair. No released PV remains.

The running cluster no longer depends on a Kadalu CSI volume. This establishes the current storage backend, not completion of every historical data transfer or recovery check.

## Keep

- All currently mounted claims and their PVs, including `immich-postgres-recovered`. Despite its name, that claim is mounted by the running Immich PostgreSQL pod.
- Static media PVs for Audiobookshelf, Booklore, Jellyfin, MeTube, and Navidrome. These all point to `/var/mnt/bulk/media-library` on `node-2`; their separate PV records do not represent separate copies of the data.
- Calibre-Web's static PV at `/var/mnt/bulk/calibre-library` on `node-2`.
- The local-path claims for Immich PostgreSQL, Papra, and Pocket ID. They are in active use; moving off Kadalu does not require moving them to local-bulk.

## Approved metadata cleanup

| Resource | Current evidence | Disposition |
| --- | --- | --- |
| `pvc-d078eb6f-6076-4347-bc13-7c2b39647810` | Released, Retain, old 5 GiB Kadalu claim `n8n/n8n`; current n8n uses local-bulk | PV record removed; current local-bulk replacement and Disk C backups preserved |
| `pvc-d61a38d3-b4a9-447b-b04c-55c2248d9dd9` | Released, Retain, old 5 GiB Kadalu claim `home-assistant/home-assistant`; current Home Assistant uses local-bulk | PV record removed; current local-bulk replacement and Disk C backups preserved |
| `pvc-655bba25-823f-455c-a741-e56498ffd32d` | Released, Retain, old 10 GiB local-bulk `monitoring/grafana-db-1`; current database uses a different PV | Old released PV record removed; active Grafana database PV preserved |
| `pvc-b1391a83-774a-439a-b599-5b873d9dd79a` | Released, Retain, 64 MiB local-bulk `storage-smoke-test/smoke` | Released PV record removed; no directory erasure |
| `booklore/booklore-calibre-library` and PV `booklore-calibre-library` | Bound, not referenced by a current pod; same node/path as Calibre-Web's live library | Unused claim and PV records removed; Calibre-Web claim/PV and shared directory preserved |

J confirmed Disk C contains August 30 pre-migration backups: the Home Assistant archive, n8n application archive, and n8n PostgreSQL dump. The current applications use replacement local-bulk PVs. Surviving old Kadalu backing data has not been located; this cleanup does not claim it was recovered or erased. Original PV/claim snapshots are retained privately under `~/.local/state/cluster-config/storage-prune/`. All five removed PVs had `Retain`; the BookLore claim had no pod or controller consumers.

## Guarded Argo adoption — 2026-09-13

J approved adopting the six source-declared PVs and ten PVCs into the `apps` Application with per-resource `Prune=confirm,Delete=confirm` annotations. Those guards are committed in each resource's owning service template. They were installed and verified on all 16 live objects before a resource-scoped Argo sync at commit `3cee0dd`. The sync added Argo tracking and missing sync-wave metadata; no pruning was requested. Confirmation guards cover Argo operations, not direct Kubernetes deletion by an authorized operator.

Local render comparison proved annotation-only changes; server-side dry-run preserved every live spec. After adoption, all 31 PVs and 31 PVCs retain identical specs, bindings, identities, and finalizers, and all remain Bound. Workload and Application specs/identities are unchanged. The refreshed `apps` diff contains no storage differences. Auto-sync remains off.

The remaining root differences were cleared on 2026-09-13: five stale Syncthing integration objects were removed, Home Assistant mDNS received its missing Argo tracking annotation, and Grafana's database CPU limit is now expressed as `"1"` in Git to match live state. All 47 Applications return zero hard-refresh diff under the configured comparison rules. No workload or storage spec changed.

The final audit found two pre-existing PVC deletion timestamps, both dated 2026-08-31: `excalidash/excalidash` and `n8n/n8n-db-1`. J subsequently approved backups, downtime, and repair while preserving the correct data. Both claims were recreated with identical specs and rebound explicitly to their original retained PVs. Neither claim has a pending deletion now. Bound phase alone does not mean a claim has no pending deletion request.

## Approved claim repair — 2026-09-13

Excalidash was stopped before a full-volume archive and SQLite backup. The old claim completed deletion naturally once its consumer stopped; no protection finalizer was forced. The replacement claim names the same PV, and the PV was reserved directly for the new claim UID. After restart, SQLite integrity passed and all 16 tables matched the backup by count and full row-content hashes.

n8n received an initial live logical backup and app-file archive, followed by a final PostgreSQL dump after stopping application writers. Only `n8n-db` reconciliation was temporarily paused with `cnpg.io/reconciliationLoop=disabled` while gracefully shutting down PostgreSQL and repairing its claim. A cold physical archive confirmed clean shutdown and system ID `7679883272937959444`. The replacement retained CNPG ownership/labels and bound to the same original PV and directory. Reconciliation resumed after binding; the annotation was removed. Before restarting n8n, all 108 database table counts/content fingerprints matched, and an isolated PostgreSQL restore of the logical backup matched the same fingerprints.

Both services returned healthy with unchanged configuration and Secret values, including n8n's encryption key. The two Deployment replica counts and all final workload/Cluster specs match their pre-maintenance state. All 31 PVs and 31 PVCs are Bound without deletion timestamps. Backup locations and contents are recorded in [backup status](backup-manual.md). Temporary backup/restore pods were removed; the backup directories remain.

Before discarding any old application storage, verify expected records/files in the current application and an independently usable backup. The approved cleanup removed Kubernetes records only; physical storage disposal and backup deletion were not performed.
