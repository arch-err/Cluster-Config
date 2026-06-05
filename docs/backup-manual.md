# Manual interim backup

Status: **interim**. This is the stopgap until a proper backup story (velero / kopia / restic) is in place — see [§Next phase](#next-phase) for the opinion on what that should look like.

## What this is

A single shell script (`scripts/backup.sh`) that pulls cluster-side data down to an external drive plugged into the user's laptop. On-demand only — no schedules, no in-cluster CronJob. Designed for:

- The user plugs in a USB drive (e.g. mounted at `/run/media/archerr/<label>`)
- They run `./scripts/backup.sh /run/media/archerr/<label>`
- All CRITICAL + VALUABLE data lands in `<drive>/cluster-backup-YYYY-MM-DD-HHMM/`, dated, hashed, logged
- They unplug the drive

**Not** a disaster-recovery plan. **Not** point-in-time consistent across apps. **Not** automated. Just a "before I do something stupid" / "monthly cold copy" insurance policy.

## Tier inventory

Approximate sizes per tier. Actual on-disk bytes after gzip are smaller — sqlite databases compress to single-digit-MB even at full PVC size; configs are tiny; the immich library is mostly already-compressed JPEGs/HEICs and gzips poorly.

### CRITICAL — irreplaceable, always back up

| App | Source | PVC capacity | What's in it |
|---|---|---|---|
| vaultwarden | `vaultwarden/vaultwarden` | 5Gi | sqlite vault, attachments, JWT signing key — **losing this = losing every password** |
| pocket-id | `pocket-id/pocket-id-data-pocket-id-0` | 5Gi | sqlite — every user account, every OIDC client registration, signing keys |
| home-assistant | `home-assistant/home-assistant` | 5Gi | config + automations + history db |
| syncthing config | `syncthing/syncthing-config` | 1Gi | sqlite index, device IDs, folder pairings |
| syncthing sync | `syncthing/syncthing-sync` | 50Gi | the actual synced user data |
| paperless data | `paperless-ngx/paperless-ngx-data` | 5Gi | sqlite-side metadata, search index |
| paperless media | `paperless-ngx/paperless-ngx-media` | 10Gi | original scanned documents |
| paperless consume | `paperless-ngx/paperless-ngx-consume` | 2Gi | in-flight ingest |
| paperless export | `paperless-ngx/paperless-ngx-export` | 2Gi | user-triggered exports |
| paperless postgres | `paperless-ngx` pg pod | (logical) | `pg_dump -Fc` — paperless metadata DB |
| calibre-web config | `calibre-web/calibre-web-config` | 5Gi | settings + user accounts |
| calibre-web library | `calibre-web/calibre-web-calibre-library` | 50Gi | actual book files + calibre metadata.db |
| calibre-web ingest | `calibre-web/calibre-web-cwa-book-ingest` | 5Gi | in-flight uploads |
| immich postgres | `immich` pg pod | (logical) | `pg_dump -Fc` — face/asset/album metadata |
| immich library | `immich/immich-library` | 1Ti | original photos + thumbnails. **OPT-IN** (`--with-immich-library`) — needs ~1TB free on the drive |
| audiobookshelf config | `audiobookshelf-v2/audiobookshelf-v2-config` | 5Gi | sqlite — user accounts, listening progress, OIDC settings |

**Subtotal (default — no immich-library):** PVC ceiling ~155Gi; realistic compressed payload probably **20–40 GB** depending on actual data in paperless-media + calibre + syncthing-sync.

**With `--with-immich-library`:** add ~1TB of mostly-already-compressed media.

### VALUABLE — annoying to lose, but reconstructible

| App | Source | PVC capacity | Note |
|---|---|---|---|
| qbittorrent config | `qbittorrent/qbittorrent` | 2Gi | torrent state |
| navidrome | `navidrome/navidrome` | 5Gi | sqlite — scrobbles, playlists |
| jellyfin config | `jellyfin/jellyfin-config` | 5Gi | watch history, user accounts |
| audiobookshelf metadata | `audiobookshelf-v2/audiobookshelf-v2-metadata` | 5Gi | cover/cached metadata |
| audiobookshelf backup | `audiobookshelf-v2/audiobookshelf-v2-backup` | 5Gi | ABS-internal nightly sqlite dumps |
| excalidash | `excalidash/excalidash` | 2Gi | dashboards |
| agent-vault | `agent-vault/agent-vault-data` | 2Gi | agent state |
| metube | `metube/metube` | 1Gi | download queue/history |
| ntfy | `ntfy/ntfy-data` | 5Gi | message DB |
| matrix synapse | `matrix/matrix-synapse` | 5Gi | sqlite — accounts, rooms, history |
| grafana | `monitoring/grafana-db-1` | 10Gi | cnpg postgres — alert rules, users, prefs (dashboards are git-synced) |

**Subtotal:** PVC ceiling ~46Gi; realistic compressed payload **3–8 GB**.

### SKIP — re-downloadable or rebuildable, don't waste drive space

| Source | Capacity | Why skipped |
|---|---|---|
| `arr/media-library` (RWX shared) | 1500Gi | Re-downloadable media. Same volume reused by jellyfin / navidrome / metube / abs-v2 / qbittorrent under different PVC names — all SKIP |
| `arr/media-downloads` + `qbittorrent/media-downloads` | 200Gi | Transient torrent scratch |
| `monitoring/prometheus-server` | 30Gi | Time-series — regenerates from current cluster state |
| `monitoring/storage-loki-0` | 30Gi | Log storage — regenerates from current logs |
| `immich/immich-machine-learning` | 10Gi | CLIP/face model cache |
| `immich/immich-valkey` | 1Gi | redis cache |
| `matrix/redis-data-matrix-redis-replicas-*` | 8Gi × 2 | redis replicas — disabled in synapse values anyway |
| `stirling-pdf/stirling-pdf` | 2Gi | transient PDF processing |

### DB-special — get logical dumps, not raw tars

Postgres pods are NOT tar'd from their PVC — running pg WAL state during a tar is at best a "needs-recovery-on-restore" disk, at worst silently corrupt. Both get `pg_dump -Fc` instead:

| Pod | Method |
|---|---|
| `immich/immich-postgres-*` | `kubectl exec ... pg_dump -Fc -d immich \| gzip > immich-postgres.dump.gz` |
| `paperless-ngx/paperless-ngx-postgresql-0` | same pattern, `-d paperless` |

`argocd-redis` and `paperless-ngx-redis-master-0` — caches, not source-of-truth, no PVC backup either.

## How to run

```bash
# Default — CRITICAL + VALUABLE, skips the 1TB immich-library
./scripts/backup.sh /run/media/archerr/<drive-label>

# CRITICAL only (faster, smaller)
./scripts/backup.sh --critical-only /run/media/archerr/<drive-label>

# Include immich-library (very slow; needs ~1TB free)
./scripts/backup.sh --with-immich-library /run/media/archerr/<drive-label>

# Crash-consistent (scales each app to 0 before tar). Causes brief
# downtime per app. Off by default — sqlite + Recreate strategy gives
# a reasonably consistent snapshot in practice.
./scripts/backup.sh --quiesce /run/media/archerr/<drive-label>
```

Output layout under the dated dir:

```
cluster-backup-YYYY-MM-DD-HHMM/
├── backup.log               # full timestamped log
├── sha256sums.txt           # one line per artifact
├── vaultwarden.tar.gz
├── pocket-id.tar.gz
├── home-assistant.tar.gz
├── ...
├── immich-postgres.dump.gz  # pg_dump custom format
└── paperless-postgres.dump.gz
```

Verify after copying off:

```bash
cd /run/media/archerr/<drive-label>/cluster-backup-YYYY-MM-DD-HHMM
sha256sum -c sha256sums.txt
```

### Design choice + why

**Chose:** per-PVC transient helper Pod (busybox, RO mount) + `kubectl exec tar c | gzip > local`. One short-lived pod per PVC, no temp storage in-cluster, no intermediate Job manifest, no `kubectl cp` overhead.

**Why not the other options:**

- **`kubectl cp` per PVC via a long-lived helper pod** — fine, but `kubectl cp` adds its own tar overhead (tar over tar) and is meaningfully slower than a direct `exec | gzip`. Same number of pod-lifecycle round-trips as the chosen approach.
- **In-cluster `Job` that tars to a temp PVC, then `kubectl cp` the tar out** — adds a kadalu-backed scratch volume we'd have to provision + a second copy step. More moving parts, no benefit for ad-hoc use.
- **kadalu host-path / snapshot via Talos nodes** — Talos has no SSH, no `kubectl exec` for node access. kadalu's snapshot CLI exists upstream but isn't wired into our deployment chart, and there's no clean way to extract a snapshot off-node without going through a pod anyway. Not worth the complexity for an interim solution.
- **Postgres pods get `pg_dump`, never raw tar** — non-negotiable; running pg WAL state is not safe to tar.

**Consistency caveat:** the default mode does NOT quiesce apps before tar. Most cluster apps use sqlite with `strategy: Recreate` (`vaultwarden`, `audiobookshelf-v2`, `calibre-web`, etc.) and only one writer at any moment, so a tar of /data during normal operation is "as crash-consistent as power-loss at that instant" — sqlite recovers from this. The `--quiesce` flag scales each workload to 0 before tar and back after for true consistency at the cost of brief per-app downtime. **For monthly cold backups, run with `--quiesce`. For a quick pre-change snapshot, default is fine.**

## Restore notes

| Artifact type | To restore |
|---|---|
| `*.tar.gz` (any PVC) | Provision a fresh PVC of the same name/size, mount it in a temp pod at `/restore`, `kubectl exec -i ... tar -C /restore -xzf - < <artifact>`, then redeploy the app pointing at the restored PVC (or restart it if the PVC name matches its existing claim) |
| `immich-postgres.dump.gz` | `gunzip -c immich-postgres.dump.gz \| kubectl -n immich exec -i deploy/immich-postgres -- pg_restore -U immich -d immich --clean --if-exists --no-owner --no-acl` — app down during restore |
| `paperless-postgres.dump.gz` | same pattern: `... \| kubectl -n paperless-ngx exec -i paperless-ngx-postgresql-0 -- pg_restore -U postgres -d paperless --clean --if-exists --no-owner --no-acl` |
| `sha256sums.txt` | `cd <backup-dir> && sha256sum -c sha256sums.txt` — verify before trusting any restore |

Restore is **not** automated — that's intentional. Doing a real restore should be deliberate; running a script during an incident invites mistakes. The notes above are enough to do it under pressure.

## Open questions + next phase

This script answers "can I get my data off the cluster onto a USB drive in one command" — that's it. It does **not** answer:

- Off-site backup (the USB lives in the user's house — fire/theft loses both)
- Point-in-time recovery for the cluster as a whole (Helm releases, ArgoCD apps, SOPS secrets — these are already in git, but cluster state mid-reconcile is not snapshottable here)
- Scheduled/automated backup without the user being present
- Bare-metal-restore of a kadalu volume (kadalu replica 2 gives availability across two of three nodes; it does not give backup)

### What the proper solution should look like

**Opinion: kopia-in-cluster + restic-compatible repo on a remote object store (e.g. Backblaze B2 or a self-hosted minio off-site).** Reasoning:

- **kopia** over restic for: native compression, faster snapshot at large file counts (immich-library has hundreds of thousands of files), built-in deduplication across snapshots
- **Repo on object storage** for: off-site by definition, versioned snapshots, encrypted at rest with a key the user holds
- **In-cluster** so the backup is a `CronJob`/`Schedule` CR triggered by ArgoCD, not "did I remember to plug the drive in this month"
- **Per-PVC source via a daemonset-style sidecar OR a job that mounts each PVC** — kopia/restic both have community-maintained k8s operators (e.g. `k8up.io` wraps restic) that handle this cleanly
- **Postgres + sqlite still need pre-dump hooks** — `k8up` supports `PreBackupPod` for exactly this; pre-pods dump to a side PVC that the main backup picks up
- **Velero is the famous answer** and worth a hard look, but its model is more "cluster-level snapshots via CSI" — Kadalu doesn't expose CSI snapshots in our config, so velero's killer feature would be unavailable and it'd fall back to file-level via `node-agent` + restic anyway. At that point k8up/kopia is the simpler stack.

**Pilot plan when ready:** deploy `k8up` operator → point it at a B2 bucket with a generated repo password (SopsSecret) → annotate critical PVCs with `k8up.io/backup: "true"` → add `PreBackupPod`s for the two postgres instances + maybe the largest sqlite ones → schedule daily incremental + weekly full → verify with a test restore into a `restore-test` ns once a month. This script can stay in the repo as the "pull a known-good cold copy before a risky change" tool even after the automated solution lands.
