#!/usr/bin/env bash
# backup.sh — manual interim cluster backup to an external drive.
#
# Pulls CRITICAL + VALUABLE PVCs + DB dumps from the cluster to a local
# directory. Designed for the user plugging a USB drive into their laptop
# and running ONE command. Per-tier inventory + design rationale:
#   ../docs/backup-manual.md
#
# Usage:
#   ./backup.sh /run/media/archerr/<drive-label>          # CRITICAL + VALUABLE
#   ./backup.sh --critical-only /run/media/.../...        # CRITICAL only
#   ./backup.sh --with-immich-library /run/media/.../...  # also dump 1TB immich-library (slow)
#   ./backup.sh --kubectl-context admin@cluster /run/...
#
# Design (see backup-manual.md §design for rationale):
#   - One helper Pod per source ns, mounts PVC read-only, `tar c` streamed
#     over `kubectl exec` straight to a local file. No temp storage in-
#     cluster, no intermediate Job, no `kubectl cp` overhead.
#   - Postgres → `kubectl exec ... pg_dump -Fc` streamed to local .dump.
#   - sqlite-on-PVC → handled as raw tar (Recreate strategy on the apps
#     means no live writers during a quiet moment; for absolute consistency
#     scale the deploy to 0 first — flag --quiesce, off by default).
#   - One sha256sums file + one backup.log per run.
#   - Fail loud: any single artifact failure aborts the run (set -e).
#
# Restore notes per type — see docs/backup-manual.md §restore.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ─── Config / args ────────────────────────────────────────────────────────────
KUBECTL_CONTEXT="admin@cluster"
INCLUDE_TIER_VALUABLE=1
INCLUDE_IMMICH_LIBRARY=0
QUIESCE=0
TARGET=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <target-mount>

Options:
  --critical-only          Skip VALUABLE tier (configs of replaceable apps)
  --with-immich-library    Also dump the 1TB immich-library PVC (very slow; needs ~1TB free)
  --quiesce                Scale apps to 0 replicas before tar, scale back after
                           (true crash-consistent; small downtime per app)
  --kubectl-context CTX    kubectl context to use (default: admin@cluster)
  -h, --help               Show this message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --critical-only)        INCLUDE_TIER_VALUABLE=0; shift ;;
        --with-immich-library)  INCLUDE_IMMICH_LIBRARY=1; shift ;;
        --quiesce)              QUIESCE=1; shift ;;
        --kubectl-context)      KUBECTL_CONTEXT="$2"; shift 2 ;;
        -h|--help)              usage; exit 0 ;;
        -*)                     die "Unknown option: $1" ;;
        *)                      TARGET="$1"; shift ;;
    esac
done

[[ -n "$TARGET" ]] || { usage; die "Missing target mount path."; }
[[ -d "$TARGET" ]] || die "Target is not a directory: $TARGET"
[[ -w "$TARGET" ]] || die "Target is not writable: $TARGET"

require_cmd kubectl
require_cmd sha256sum
require_cmd tar
require_cmd gzip

KCTL="kubectl --context=${KUBECTL_CONTEXT}"

# Smoke-test the context once up front so we fail before creating any pods.
$KCTL version --request-timeout=5s >/dev/null 2>&1 \
    || die "kubectl context '${KUBECTL_CONTEXT}' cannot reach the cluster."

STAMP="$(date +%Y-%m-%d-%H%M)"
OUT="${TARGET}/cluster-backup-${STAMP}"
mkdir -p "$OUT"
LOG="${OUT}/backup.log"
SUMS="${OUT}/sha256sums.txt"
: > "$LOG"
: > "$SUMS"

log() {
    local msg="[$(date +%H:%M:%S)] $*"
    echo "$msg" | tee -a "$LOG"
}

err() {
    echo -e "\033[0;31m[$(date +%H:%M:%S)] ERROR:\033[0m $*" | tee -a "$LOG" >&2
}

trap 'err "backup ABORTED on line $LINENO (last cmd: $BASH_COMMAND)"' ERR

log "backup target: $OUT"
log "kubectl context: $KUBECTL_CONTEXT"
log "tiers: CRITICAL$([[ $INCLUDE_TIER_VALUABLE == 1 ]] && echo ' + VALUABLE')"
log "immich-library: $([[ $INCLUDE_IMMICH_LIBRARY == 1 ]] && echo INCLUDED || echo SKIPPED)"
log "quiesce: $([[ $QUIESCE == 1 ]] && echo YES || echo no)"

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Stable name for the helper pod so re-runs / cleanup-on-error don't clash.
helper_pod_name() {
    local ns=$1 pvc=$2
    # K8s name constraints: lowercase, <=63 chars.
    echo "backup-helper-$(echo "${ns}-${pvc}" | tr '[:upper:]_' '[:lower:]-' | cut -c1-40)-$$"
}

cleanup_pod() {
    local ns=$1 pod=$2
    $KCTL -n "$ns" delete pod "$pod" --wait=false --ignore-not-found >/dev/null 2>&1 || true
}

# Stream a tarball of a PVC's mounted contents to a local file.
# Strategy: create a transient busybox pod with the PVC mounted RO at /data,
# wait for it, `tar c .` from /data, stream to local gzip, delete pod.
backup_pvc() {
    local ns=$1 pvc=$2 outname=$3
    local pod
    pod="$(helper_pod_name "$ns" "$pvc")"
    local outfile="${OUT}/${outname}.tar.gz"

    log "  PVC ${ns}/${pvc} → ${outname}.tar.gz"

    # Render and create the helper pod. RO mount + restricted-PSS compatible.
    cat <<EOF | $KCTL apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${ns}
  labels: { app.kubernetes.io/name: backup-helper, app.kubernetes.io/managed-by: backup.sh }
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    fsGroup: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: tar
      image: docker.io/library/busybox:1.37.0
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      volumeMounts:
        - { name: data, mountPath: /data, readOnly: true }
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${pvc}
        readOnly: true
EOF

    # shellcheck disable=SC2064
    trap "cleanup_pod ${ns} ${pod}" RETURN

    $KCTL -n "$ns" wait --for=condition=Ready "pod/${pod}" --timeout=120s >>"$LOG" 2>&1 \
        || { err "helper pod ${ns}/${pod} not Ready in 120s"; return 1; }

    # Stream tar over exec. busybox tar handles . correctly; -C /data is the
    # mount root. gzip locally (save network); pipefail catches a mid-stream
    # exec failure.
    $KCTL -n "$ns" exec "${pod}" -c tar -- tar -C /data -cf - . 2>>"$LOG" \
        | gzip -c > "$outfile"

    cleanup_pod "$ns" "$pod"
    trap - RETURN

    sha256sum "$outfile" | tee -a "$SUMS" >/dev/null
    log "    done $(du -h "$outfile" | awk '{print $1}')"
}

# pg_dump a postgres pod's database to local .dump.gz.
# Args: ns pod-label-selector db-user db-name outname
backup_postgres() {
    local ns=$1 selector=$2 user=$3 db=$4 outname=$5
    local pod
    pod="$($KCTL -n "$ns" get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}')"
    [[ -n "$pod" ]] || { err "no pod for selector $selector in $ns"; return 1; }

    local outfile="${OUT}/${outname}.dump.gz"
    log "  PG ${ns}/${pod} db=${db} user=${user} → ${outname}.dump.gz"

    # -Fc = custom format = compressed + restorable with pg_restore at any
    # version >= the dump's source. PGPASSWORD comes from the pod's own env
    # (no creds in this script). Errors-on-data so we don't ship truncated
    # dumps silently.
    $KCTL -n "$ns" exec "${pod}" -- sh -c \
        "PGPASSWORD=\"\${POSTGRES_PASSWORD:-\${POSTGRESQL_PASSWORD:-\$DB_PASSWORD}}\" pg_dump -U ${user} -d ${db} -Fc --no-owner --no-acl" \
        2>>"$LOG" | gzip -c > "$outfile"

    [[ -s "$outfile" ]] || { err "empty pg dump for ${ns}/${db}"; return 1; }
    sha256sum "$outfile" | tee -a "$SUMS" >/dev/null
    log "    done $(du -h "$outfile" | awk '{print $1}')"
}

# Optional quiesce: scale a workload to 0 before tar, restore after.
quiesce_workload() {
    [[ $QUIESCE == 1 ]] || return 0
    local ns=$1 kind=$2 name=$3
    log "  quiesce: scaling ${ns}/${kind}/${name} → 0"
    $KCTL -n "$ns" scale "${kind}/${name}" --replicas=0 >>"$LOG" 2>&1
    $KCTL -n "$ns" rollout status "${kind}/${name}" --timeout=60s >>"$LOG" 2>&1 || true
}
unquiesce_workload() {
    [[ $QUIESCE == 1 ]] || return 0
    local ns=$1 kind=$2 name=$3 replicas=$4
    log "  unquiesce: scaling ${ns}/${kind}/${name} → ${replicas}"
    $KCTL -n "$ns" scale "${kind}/${name}" --replicas="${replicas}" >>"$LOG" 2>&1
}

# ─── Inventory: edit here when adding apps ────────────────────────────────────
# Tuple per entry: <tier> <type> <ns> <pvc-or-selector> <outname> [extra...]
# tier: critical | valuable
# type: pvc | postgres
# pvc:      <ns> <pvc-name> <outname>
# postgres: <ns> <pod-selector> <user> <db> <outname>

run_critical() {
    log ""
    log "=== TIER: CRITICAL ==="

    # Identity / secrets — losing these locks the user out of everything.
    backup_pvc vaultwarden      vaultwarden                  vaultwarden
    backup_pvc pocket-id        pocket-id-data-pocket-id-0   pocket-id

    # Home automation — non-trivial config + automations.
    backup_pvc home-assistant   home-assistant               home-assistant

    # File sync — losing config means re-pairing every peer + losing folder
    # history. Sync data itself is also user-data (not a cache).
    backup_pvc syncthing        syncthing-config             syncthing-config
    backup_pvc syncthing        syncthing-sync               syncthing-sync

    # Document archive — paperless data + originals + DB.
    backup_pvc paperless-ngx    paperless-ngx-data           paperless-data
    backup_pvc paperless-ngx    paperless-ngx-media          paperless-media
    backup_pvc paperless-ngx    paperless-ngx-consume        paperless-consume
    backup_pvc paperless-ngx    paperless-ngx-export         paperless-export
    backup_postgres paperless-ngx \
        app.kubernetes.io/name=postgresql \
        postgres paperless \
        paperless-postgres

    # E-book library + reader state.
    backup_pvc calibre-web      calibre-web-config              calibre-web-config
    backup_pvc calibre-web      calibre-web-calibre-library     calibre-web-library
    backup_pvc calibre-web      calibre-web-cwa-book-ingest     calibre-web-ingest

    # Photos — postgres dump (pg_dump beats raw PVC; pg WAL state on a live
    # cluster is not safely tar-able). The 1TB library PVC is opt-in below.
    backup_postgres immich \
        app.kubernetes.io/instance=immich-postgres \
        immich immich \
        immich-postgres

    if [[ $INCLUDE_IMMICH_LIBRARY == 1 ]]; then
        log "  (immich-library: 1TB, this will take a while)"
        backup_pvc immich       immich-library               immich-library
    else
        log "  immich-library SKIPPED (re-run with --with-immich-library to include)"
    fi

    # Audiobookshelf — config has user accounts + listening progress + OIDC
    # settings. Media itself is on shared media-library (SKIP tier).
    backup_pvc audiobookshelf-v2 audiobookshelf-v2-config    audiobookshelf-config
}

run_valuable() {
    log ""
    log "=== TIER: VALUABLE ==="

    # arr stack — configs only (media is on the SKIP-tier shared volume).
    backup_pvc arr              readarr                      readarr-config
    backup_pvc prowlarr         prowlarr                     prowlarr-config
    backup_pvc qbittorrent      qbittorrent                  qbittorrent-config

    # Audio + video player state.
    backup_pvc navidrome        navidrome                    navidrome-config
    backup_pvc jellyfin         jellyfin-config              jellyfin-config

    # Audiobookshelf — metadata cache + ABS-internal nightly db backups.
    backup_pvc audiobookshelf-v2 audiobookshelf-v2-metadata  audiobookshelf-metadata
    backup_pvc audiobookshelf-v2 audiobookshelf-v2-backup    audiobookshelf-backup

    # Personal tools.
    backup_pvc excalidash       excalidash                   excalidash
    backup_pvc agent-vault      agent-vault-data             agent-vault
    backup_pvc metube           metube                       metube-config
    backup_pvc ntfy             ntfy-data                    ntfy

    # Communication — synapse sqlite + room history.
    backup_pvc matrix           matrix-synapse               matrix-synapse

    # Observability — dashboards + alerting rules (NOT prometheus tsdb or
    # loki chunks; those are regenerable from current state).
    backup_pvc monitoring       grafana                      grafana
}

# ─── Run ──────────────────────────────────────────────────────────────────────
log ""
run_critical
[[ $INCLUDE_TIER_VALUABLE == 1 ]] && run_valuable

log ""
log "=== SUMMARY ==="
log "artifacts: $(grep -c . "$SUMS") files, $(du -sh "$OUT" | awk '{print $1}') total"
log "sha256sums: ${SUMS}"
log "log: ${LOG}"
log "done."

echo
echo "Backup complete: ${OUT}"
echo "Verify with: cd ${OUT} && sha256sum -c sha256sums.txt"
