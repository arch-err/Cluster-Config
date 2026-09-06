# Backup status and recovery

**The existing `scripts/backup.sh` is a legacy helper, not a current verified backup procedure.** The repository cleanup did not run backups or restore tests, and a successful render does not establish data recoverability.

## What the helper implements

The script streams PVC contents through a read-only helper pod to local `.tar.gz` files, and selected PostgreSQL databases through `pg_dump` to `.dump.gz` files. It writes a log and SHA-256 checksums to a timestamped directory. Its default kubectl context is `admin@cluster`.

Inspect supported options without contacting the cluster:

```sh
scripts/backup.sh --help
```

## Known gaps from code inspection

- The hard-coded inventory includes retired or disabled services such as Vaultwarden, Paperless, Syncthing, and the arr stack. It does not represent the current enabled service list.
- Pocket ID's configured claim is now `pocket-id-local`; the script still requests `pocket-id-data-pocket-id-0`.
- Grafana now declares a CNPG database; the script still treats the old Grafana PVC as its backup target. Other current database and application paths also need reconciliation.
- `--quiesce` is parsed, but the scale-down/up helper functions are never called by the backup inventory. It **does not stop application writers**.
- A tar of actively changing SQLite or other database files is not a verified consistent snapshot. A `Recreate` deployment strategy does not stop a running process from writing during backup.
- The helper's non-root UID and node-local volume access need verification for each PVC. The script aborts on failure and does not demonstrate complete coverage.
- The Immich library is excluded unless explicitly requested. Its historical size comment is not an observation of current data size.

Do not treat this script's completion message as proof that all current data is backed up. Repairing and exercising the backup implementation is separate operational work; it was not silently changed during documentation cleanup.

## Requirements for a current backup runbook

1. Inventory current PVCs/PVs and application databases, including node affinity and named shared host directories. Distinguish application state, original user files, and reproducible caches.
2. Include Pocket ID, Home Assistant, Papra, Booklore/Calibre, Immich, Audiobookshelf, current CNPG databases, and other retained service data as appropriate to the actual deployment.
3. Use database-native backups or a verified procedure that stops writers; account for ArgoCD self-heal when scaling workloads.
4. Store backups outside the source node/disks. Preserve the age key and manual identity bootstrap recovery material separately.
5. Verify checksums and restore into an isolated target before declaring coverage complete. Record restore commands, database versions, ownership, and time of the test.

No generic overwrite/restore command is provided here: the correct destination, database state, and consumers depend on the affected service. Preserve the original data while proving the restore. See [storage and retention](pvc-reclaim-policy.md).
