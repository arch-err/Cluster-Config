# PVC reclaim policy

**Rule:** every PV whose PVC holds CRITICAL or VALUABLE user data (per `docs/backup-manual.md` tiers) **must** use `persistentVolumeReclaimPolicy: Retain`. The default `kadalu.replica2` StorageClass issues PVs with `Delete` — that means a PVC delete (manual, or ArgoCD prune on app retire) wipes the underlying gluster brick with no recovery. SKIP-tier (caches, prometheus tsdb, redis replicas, model caches, transient scratch) may stay at `Delete`.

## Why

On 2026-05-10 the ABS v1 app was retired by removing its entry from `apps.yaml`. ArgoCD pruned the v1 `Application`, which deleted its four chart-managed PVCs including `audiobookshelf-library` (100Gi). Reclaim was `Delete` (kadalu default) → gluster brick wiped instantly → audiobooks permanently lost. The user happened to have the source files; next time we won't be lucky. Pair-rule: see `feedback_no_data_destruction_without_explicit_per_pvc_call.md` (the workflow gate); this doc is the storage-layer hardening.

## Tier reference (verbatim from `docs/backup-manual.md`)

- **CRITICAL** — irreplaceable user data (vaultwarden, pocket-id, home-assistant, syncthing, paperless/papra, calibre-web, immich-postgres + library, audiobookshelf-v2 config, etc.) → **Retain, no exceptions**
- **VALUABLE** — annoying to lose but reconstructible (arr configs, navidrome, jellyfin config, abs metadata/backup, excalidash, agent-vault, metube, ntfy, matrix, grafana) → **Retain preferred**
- **SKIP** — re-downloadable / rebuildable (media-library, downloads, prometheus tsdb, loki storage, immich-machine-learning, immich-valkey, matrix redis replicas, stirling-pdf scratch) → `Delete` is fine

## State as of 2026-05-17

A sweep on 2026-05-17 patched every CRITICAL + VALUABLE PV from `Delete` to `Retain` via `kubectl patch pv <name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`. Static PVs in `kubernetes/platform/templates/extras.yaml` (`arr-media-library`, `arr-media-downloads`, `*-media-library` twins, etc.) were already declared `Retain` in their manifests — no action needed.

## For new apps

Pick whichever pattern fits the shape of the app:

### Pattern A — static PV pre-provisioned (preferred for shared/large/named volumes)

Mirror the `media-library` block in `kubernetes/platform/templates/extras.yaml` (~line 505). The PV manifest sets `persistentVolumeReclaimPolicy: Retain` explicitly, `storageClassName: ""`, and a fixed `claimRef`. The PVC in the app's namespace binds by name. This is what the arr stack uses and is the only way to share a single backing volume across namespaces.

### Pattern B — dynamic PVC + post-install patch (for single-app PVCs)

Let the chart provision its PVC normally (default SC `kadalu.replica2`, dynamic PV name `pvc-<uuid>`). Immediately after the first ArgoCD sync, find the new PV and patch it:

```bash
PV=$(kubectl -n <ns> get pvc <name> -o jsonpath='{.spec.volumeName}')
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

Document the patch in the values-file header — add a `# RECLAIM:` comment near the `persistence:` block so the next agent knows it was done and doesn't have to wonder. See e.g. `kubernetes/values/apps/vaultwarden.yaml`.

## One-line audit

Run this any time to confirm only cache PVCs are still at `Delete`:

```bash
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\t"}{.spec.persistentVolumeReclaimPolicy}{"\n"}{end}' | grep Delete
```

Expected output: only `monitoring/prometheus-server`, `monitoring/storage-loki-0`, `immich/immich-machine-learning`, `immich/immich-valkey`, `matrix/redis-data-matrix-redis-replicas-*`, `stirling-pdf/stirling-pdf`. Anything else → patch it.

## Future: `kadalu.replica2-retain` storage class

Adding a sibling StorageClass with `reclaimPolicy: Retain` would let CRITICAL/VALUABLE apps opt into Retain-by-default via `storageClassName: kadalu.replica2-retain` in their PVC spec — no post-install patch needed. Proposal lives in this repo PR thread; not deployed yet (decision pending: change default SC to retain vs add sibling SC vs keep current). The single biggest win is removing the "did we remember to patch the PV after first sync" footgun.

## When retiring an app

With `Retain`, ArgoCD prune of the `Application` will detach the PVC but leave the PV in `Released` state — data preserved. Recovery path: `kubectl patch pv <name> -p '{"spec":{"claimRef":null}}'` to put it back into `Available`, then create a new PVC with `volumeName: <pv>` to re-bind. Still: follow `feedback_no_data_destruction_without_explicit_per_pvc_call.md` and present a per-PVC disposition to the user before any retire commit.
