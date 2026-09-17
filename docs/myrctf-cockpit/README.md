# CTFd Cockpit backend

## TL;DR

The CTF VM makes outbound-only HTTPS requests to
`https://myrctf-telemetry.3rr.dev`. `ctfd-cockpit-ingest` authenticates each
write, validates the agent's exact v1 JSON Schema, and commits to CNPG before
acknowledging an event checkpoint. Grafana reads with a separate SELECT-only
role. Participant data never enters metric labels or application logs.

Everything runs in `myrctf-monitoring`: one CNPG instance, one ingest replica,
single-process Mimir/Loki/Tempo, Alloy, and Grafana. This is intentionally not a
HA design; local retained volumes suit one annual CTF. Move blocks and backups
to S3-compatible storage before treating the stack as disaster-resilient.

## Public contract

The machine-readable contract is [openapi.yaml](openapi.yaml); its two schemas
are byte-for-byte copies of the agent schemas in
`/home/j/MyrCTF/Infra/stacks/ctfd/cockpit-agent/protocol/`.

| Variable | Value/source |
| --- | --- |
| `COCKPIT_INGEST_URL` | `https://myrctf-telemetry.3rr.dev` |
| `COCKPIT_INGEST_TOKEN` | `ctfd-cockpit-ingest-auth/ingest-token` |
| `MIMIR_REMOTE_WRITE_URL` | `https://myrctf-telemetry.3rr.dev/mimir/api/v1/push` |
| `MIMIR_BEARER_TOKEN` | `ctfd-cockpit-ingest-auth/mimir-token` |
| `LOKI_WRITE_URL` | `https://myrctf-telemetry.3rr.dev/loki/loki/api/v1/push` |
| `LOKI_BEARER_TOKEN` | `ctfd-cockpit-ingest-auth/loki-token` |
| `MIMIR_TENANT_ID` | `myrctf-analytics` |
| `LOKI_TENANT_ID` | `myrctf-operations` |

Only the four write paths are externally routed. PostgreSQL, queries, health,
metrics, and readiness are cluster-local. TLS terminates at the public Cilium
Gateway. Each external write additionally requires its own scoped bearer token;
the receiver overwrites caller-supplied tenant headers.

## Data and delivery rules

- `(source, source_id)` preserves every CTFd primary key and permits multiple
  CTFd sources. Payload JSON retains the complete allowlisted source record;
  generated typed columns support common dashboard filters.
- PostgreSQL assigns `ingested_at`; all source times are UTC `timestamptz`.
- Event `batch_id` plus its body digest makes retries idempotent. A reused batch
  ID with different content is rejected.
- Events are committed transactionally and return exactly
  `{"checkpoint": <received checkpoint>}` only after commit.
- Snapshot chunks stage membership. Absence reconciliation runs only when all
  chunks from zero through the `complete` chunk are present. Abandoned runs
  expire without touching current data.
- Password hashes, tokens, session/reset/verification secrets, and application
  keys are rejected even if a future agent accidentally emits them.
- Attempted flags, email, IP, username and team name are PostgreSQL fields—not
  Prometheus/Loki labels. Ingest access logs contain method/path/status only.

## Roles and retention

`ctfd_cockpit_migrator` owns schema objects, `ctfd_cockpit_ingest` can mutate
replication tables but cannot run DDL, and `ctfd_cockpit_grafana` has SELECT
only. Grafana receives only the final role. Database storage is 30 GiB retained
local-bulk. A daily `pg_dump` is kept 14 days on a 20 GiB retained PVC pinned to
node-3, separate from the database on node-2. Mimir keeps 90 days, Loki 30 days,
and Tempo 7 days on retained local PVCs.

Every workload has CPU, memory, and ephemeral-storage requests and limits. A
namespace `ResourceQuota` provides a final 6 CPU, 8 GiB memory, 120 GiB requested
persistent-storage, 8 PVC, and 20-pod ceiling; a `LimitRange` supplies bounded
defaults to any future sidecar that omits them. Current persistent allocation is
105 GiB. Increasing these ceilings is an explicit Git change.

## Operations runbook

### Rotate ingestion/telemetry credentials

1. Generate a new random value in the SOPS source
   `kubernetes/services/myrctf-monitoring/secrets/cockpit-ingest.yaml`.
2. Sync the secret application and restart `ctfd-cockpit-ingest`.
3. Update the encrypted CTF VM secret and run `just deploy-secrets`.
4. Run `just stack-cockpit-up`, verify a successful batch, then discard the old
   value. Rotation is a brief cutover because v1 deliberately has one token per
   scope.

Database credentials are rotated independently in the existing SOPS bundle.
Restart only the consumer of that role and verify Grafana remains read-only.

### Replay and backfill

Stop the VM agent, copy its durable state file, lower only the affected entity's
checkpoint, and restart. Replays are safe: immutable records conflict on
`(source, source_id)` and mutable records upsert. Never delete server sync state
to force a replay. For a full backfill, run the agent snapshot and let the
normal event cursor catch up.

### Failed or abandoned snapshots

Do not manually reconcile an incomplete snapshot. Existing rows remain live.
Retry the same chunk/body or begin a new snapshot ID; stale staging is garbage
collected after the configured TTL. Investigate gaps, schema rejection, and DB
errors in the Pipeline health dashboard before retrying.

### Backup recovery

Trigger `ctfd-cockpit-backup` manually before the event and after material
changes. Restore a dump into a disposable PostgreSQL 16 database and run row
counts plus representative dashboard queries. A retained local PVC is not an
off-site backup: copy verified dumps to the cluster's future S3-compatible
object store when credentials are available.
