# Storage migration review — 2026-09-12

This review is read-only. No PV, PVC, storage directory, or database was deleted or changed. Kubernetes references identify current use; they do not establish backup completeness or whether old filesystem contents are recoverable.

## Current deployment

All 32 PVCs are Bound, and none uses Kadalu: 22 use `local-bulk`, 3 use `local-path`, and 7 use explicitly bound static local PVs with an empty StorageClass. There are 36 PVs total: 32 bound and 4 released. Thirty-one claims are referenced by current pods; Booklore's old Calibre-library claim is the exception below.

The running cluster no longer depends on a Kadalu CSI volume. This establishes the current storage backend, not completion of every historical data transfer or recovery check.

## Keep

- All currently mounted claims and their PVs, including `immich-postgres-recovered`. Despite its name, that claim is mounted by the running Immich PostgreSQL pod.
- Static media PVs for Audiobookshelf, Booklore, Jellyfin, MeTube, and Navidrome. These all point to `/var/mnt/bulk/media-library` on `node-2`; their separate PV records do not represent separate copies of the data.
- Calibre-Web's static PV at `/var/mnt/bulk/calibre-library` on `node-2`.
- The local-path claims for Immich PostgreSQL, Papra, and Pocket ID. They are in active use; moving off Kadalu does not require moving them to local-bulk.

## Hold for a separate decision

| Resource | Current evidence | Disposition |
| --- | --- | --- |
| `pvc-d078eb6f-6076-4347-bc13-7c2b39647810` | Released, Retain, old 5 GiB Kadalu claim `n8n/n8n`; current n8n uses local-bulk | Keep recovery metadata and old storage until n8n data/backup verification |
| `pvc-d61a38d3-b4a9-447b-b04c-55c2248d9dd9` | Released, Retain, old 5 GiB Kadalu claim `home-assistant/home-assistant`; current Home Assistant uses local-bulk | Keep recovery metadata and old storage until Home Assistant data/backup verification |
| `pvc-655bba25-823f-455c-a741-e56498ffd32d` | Released, Retain, old 10 GiB local-bulk `monitoring/grafana-db-1`; current database uses a different PV | Keep until the prior database/recovery history is checked |
| `pvc-b1391a83-774a-439a-b599-5b873d9dd79a` | Released, Retain, 64 MiB local-bulk `storage-smoke-test/smoke` | Likely test cleanup candidate; contents not inspected |
| `booklore/booklore-calibre-library` and PV `booklore-calibre-library` | Bound, not referenced by a current pod; same node/path as Calibre-Web's live library | Claim/PV metadata may be redundant; do not delete the shared library directory |

Retained PV metadata does not itself prove that old disk data survives. Old Kadalu PV records retain volume handles/subvolume paths, while the Kadalu deployment has been retired. Recovery would require locating the old storage and an appropriate recovery procedure.

## Why the roots still differ

The reviewed storage diffs under `apps` are missing Argo tracking annotations and, on a few objects, missing sync-wave annotations. The PV/PVC specifications already describe the live local storage. These are ownership/metadata decisions, not requests to migrate bytes or recreate volumes. Adopting tracking would make future Argo prune/deletion policy relevant, so it should be reviewed explicitly rather than treated as cosmetic cleanup.

The `infra` Grafana database diff is the CPU request expressed as `1` versus `1000m`; those quantities are equivalent. It is unrelated to the old released Grafana PV.

Before discarding any old application storage, verify expected records/files in the current application and an independently usable backup. No storage disposal has been authorized by this review.
