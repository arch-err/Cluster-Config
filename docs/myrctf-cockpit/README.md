# CTFd Cockpit backend

## TL;DR

`ctfd-cockpit-agent` reads CTFd's MariaDB locally with a SELECT-only account and
pushes gzip-compressed, versioned batches to `ctfd-cockpit-ingest`. The ingest
service is the only writer to a dedicated CloudNativePG database. Grafana reads
that database through a separate read-only role. The cluster never connects to
the CTF VM, MariaDB, or the CTFd admin API.

This directory is the source of truth for the initial wire and storage
contracts:

- [OpenAPI 3.1 contract](openapi.yaml)
- [JSON Schemas](schemas/v1/)
- [initial PostgreSQL migration](migrations/001_initial.sql)

The contract preserves CTFd source IDs. Decimal IDs and checkpoints are encoded
as strings on the wire so JavaScript clients cannot truncate 64-bit integers;
PostgreSQL stores CTFd IDs as `bigint` and checkpoints as `numeric(20,0)`.

## Trust and data flow

```text
CTFd/MariaDB VM                                      myrctf-monitoring

MariaDB -- SELECT-only --> ctfd-cockpit-agent
                               |
                               | HTTPS + gzip JSON + scoped bearer token
                               | (optionally mTLS at the external edge)
                               v
public Gateway -> ctfd-cockpit-ingest -> ctfd-cockpit-db-rw
                                               |
                    Grafana PostgreSQL DS -> ctfd-cockpit-db-ro
```

There is no reverse route or cluster-held CTFd credential. The agent owns its
outbox/checkpoint state on the VM and retries until the service acknowledges a
durably committed checkpoint.

The payload contains participant PII, source IPs, and attempted flag values.
It is more sensitive than the aggregate analytics tenant. It is not copied to
Mimir or Loki, and ingest access logs never contain bodies, authorization
headers, query strings, or decompressed payload fragments.

## Kubernetes and Argo CD shape

Add these components to the future
`kubernetes/services/myrctf-monitoring/service.yaml`, all targeting
`myrctf-monitoring` and owned by the `apps` Argo root:

| Component | Deployment | Purpose |
| --- | --- | --- |
| `ctfd-cockpit-db` | raw CloudNativePG resources | PostgreSQL, roles, WAL archive, and backups |
| `ctfd-cockpit-migrate` | migration Job in `resources/` | Runs immutable, ordered SQL migrations |
| `ctfd-cockpit-ingest` | `bjw-s/app-template` | One small stateless API replica initially |

The ingest component is routed behind `myrctf-telemetry.3rr.dev` at
`/cockpit/`. It does not get its own query or admin route. The existing edge may
authenticate and proxy the request, but the service also validates its own
scoped bearer credential so an accidentally broad in-cluster route is not
enough to write cockpit data.

Suggested sync order:

1. SOPS secrets, CloudNativePG `ObjectStore`, and role password Secrets.
2. CloudNativePG `Cluster` and daily `ScheduledBackup`.
3. Migration Job using the migration role.
4. Ingest Deployment using the ingestion role.
5. Grafana datasource and dashboards using the read-only role.

Use one PostgreSQL 16 instance with a retained `local-bulk` 30 GiB PVC. A
single annual event does not justify replicas or a distributed CDC system.
CloudNativePG continuously archives WAL and takes a daily base backup to a
dedicated S3-compatible bucket through the Barman Cloud plugin. Start with a
35-day recovery window, retain one pre-event restore point through the event,
and perform a test restore before opening registration. Backup success is
alerted; a declared schedule without a restore test is not considered a backup.

The plugin controller is shared CloudNativePG infrastructure and therefore
lives beside the existing operator in `cnpg-system`; the Cockpit `Cluster`,
`ObjectStore`, `ScheduledBackup`, roles, Secrets, and jobs all remain in
`myrctf-monitoring`. Label inherited database pod metadata with the repository's
`public-edge.3rr.dev/profile: cnpg` profile and apply its least-privilege API and
S3 egress policy.

The migration Job verifies a pinned SHA-256 for every ordered SQL file, refuses
checksum drift for an already applied version, executes each new file in its
declared transaction, and records the version/checksum only after success.

The public namespace policy must be extended narrowly:

- Gateway/edge -> ingest HTTP port;
- ingest -> `ctfd-cockpit-db-rw:5432` only;
- Grafana -> `ctfd-cockpit-db-ro:5432` only;
- migration Job -> database RW service;
- PostgreSQL sidecar -> the dedicated S3 endpoint over 443;
- Alloy -> `/metrics` on ingest and CloudNativePG metrics;
- no other pod or private/LAN egress.

## PostgreSQL roles

CloudNativePG declaratively manages three `LOGIN` roles whose passwords come
from separate SOPS-backed Secrets:

| Role | Connection | Privileges |
| --- | --- | --- |
| `ctfd_cockpit_migrator` | migration Job only | Owns schema and objects; may run DDL |
| `ctfd_cockpit_ingest` | ingest Deployment only | `SELECT`, `INSERT`, `UPDATE` on cockpit tables and sequence usage; no DDL or destructive delete |
| `ctfd_cockpit_grafana` | Grafana only | `CONNECT`, schema `USAGE`, and `SELECT`; default transaction read-only and statement timeout |

The migration role owns the database schema and its objects. No application
receives the PostgreSQL superuser Secret. Default privileges ensure future
migration-created tables do not silently omit grants. Configure the ingest and
Grafana role defaults (`timezone`, `search_path`, statement timeout, and Grafana's
`default_transaction_read_only`) through CloudNativePG managed-role settings;
the migration role should not be allowed to alter peer login roles.

All temporal columns are `timestamptz`; sessions set `timezone=UTC`. Source
times retain the instant supplied by CTFd, while `ingested_at` is assigned by
PostgreSQL. Mutable entities use `(source_instance, <CTFd ID>)` keys. Immutable
events use `(source_instance, source_table, source_id)`. No surrogate ID
replaces a CTFd identifier.

Deletion is soft and auditable. A tombstone sets `deleted_at` on a known row and
is also inserted into `ctfd_tombstones`, allowing out-of-order tombstones to be
remembered even when the original row has not arrived.

## Delivery and checkpoint rules

Each request carries a stable source instance, stream, UUID batch ID, sequence,
and checkpoint. The service processes one batch in one PostgreSQL transaction:

1. Authenticate before decompressing the body.
2. Limit the compressed request to 8 MiB and decompressed JSON to 32 MiB.
3. Require `Content-Type: application/json` and `Content-Encoding: gzip`.
4. Validate against the endpoint's JSON Schema and reject unknown fields.
5. Limit a batch to 5,000 records and bounded string/JSON sizes.
6. Lock the `(source_instance, stream)` sync-state row.
7. If `batch_id` was committed, return its acknowledged checkpoint unchanged.
8. Reject a checkpoint lower than the committed value and reject a sequence
   gap with HTTP 409. An exact replay is not a conflict.
9. Upsert mutable rows only when the incoming source timestamp/checkpoint is not
   older. Insert immutable events with their source table/source ID uniqueness
   key. Apply tombstones without hard deletion.
10. Insert the batch audit row and advance sync state in the same transaction.
11. Commit, then return the highest durable checkpoint. Never acknowledge
    before commit succeeds.

The normalized `ingest_batches` row stores the sequence, request digest, source
event time, schema version, batch ID, checkpoint, and database ingestion time.
Every replicated row stores its batch ID and checkpoint, so its sequence and
full delivery metadata remain traceable without repeating them in every table.

The response checkpoint is scoped to the source and stream. The agent may
resume from `GET /api/v1/checkpoints/{source}?stream=...`; it must not infer
durability from an HTTP timeout. Retrying the same batch ID is always safe.

Snapshots are not destructive by omission. A complete snapshot may reconcile
missing rows only through explicit tombstones generated by the agent. This
avoids deleting data because of a partial query, permission issue, or page
failure.

## Endpoint behavior

| Endpoint | Record classes | Mutation |
| --- | --- | --- |
| `POST /api/v1/snapshot` | users, teams, memberships, challenges, tags, hints, pages, instances | Timestamp/checkpoint-guarded upsert |
| `POST /api/v1/events` | submissions, solves, awards, hint unlocks, tracking events, notifications | Append by source table/source ID |
| `POST /api/v1/tombstones` | any replicated relation | Soft delete plus tombstone audit |
| `POST /api/v1/scoreboard-snapshots` | per-team ranks/scores at one source instant | Append by source snapshot key/team |
| `GET /api/v1/checkpoints/{source}` | one requested stream or all streams | Read committed sync state |
| `GET /metrics` | Prometheus exposition | No detailed IDs or PII labels |
| `GET /healthz` | process liveness | Does not depend on PostgreSQL |
| `GET /readyz` | dependency readiness | Requires a read-only DB round trip and migrations at expected version |

Successful POSTs return HTTP 200 for both a new commit and an idempotent replay.
Use 400 for malformed encoding/JSON, 401 for failed authentication, 409 for a
sequence/checkpoint conflict, 413 for compressed or expanded size limits, and
422 for schema-valid JSON that violates domain constraints.

## Ingest service observability

Expose only bounded labels:

```text
ctfd_cockpit_ingest_requests_total{endpoint,result}
ctfd_cockpit_ingest_request_duration_seconds{endpoint}
ctfd_cockpit_ingest_records_total{record_type,result}
ctfd_cockpit_ingest_batch_records{endpoint}
ctfd_cockpit_ingest_last_committed_checkpoint{source,stream}
ctfd_cockpit_ingest_last_commit_timestamp_seconds{source,stream}
ctfd_cockpit_ingest_replication_lag_seconds{source,stream}
ctfd_cockpit_ingest_db_errors_total{operation_class}
ctfd_cockpit_ingest_schema_rejections_total{endpoint,schema_version}
```

`source` is a small configured allowlist, not caller-controlled arbitrary text.
Never use user, team, challenge, IP, batch, source ID, error text, or attempted
value as a metric label. Logs include request ID, endpoint, authenticated source,
batch ID, record count, result, duration, and committed checkpoint only.

Alert on no successful commit during the live event, replication lag above two
minutes, repeated sequence conflicts, schema rejection spikes, database errors,
PVC capacity, WAL archive failures, missed base backups, and failed restore
checks. Mimir stores these aggregate metrics and alert state; PostgreSQL remains
the detailed system of record.

## Grafana integration

Provision a server-side PostgreSQL datasource with stable UID
`ctfd-cockpit-postgres`, URL `ctfd-cockpit-db-ro:5432`, database
`ctfd_cockpit`, role `ctfd_cockpit_grafana`, `sslmode=verify-full`, PostgreSQL
version 16, and a small connection pool. Mount the CNPG CA and obtain the
password from the role Secret through Grafana environment/file interpolation.

The `CTFd Cockpit` folder is available only inside the existing Pocket ID-gated
MyrCTF Grafana organization. Every member currently has organization `Admin`,
so “organizer-only” means the single `myrctf-monitoring` Pocket ID group. If a
lower-privilege audience is added later, split it into another Grafana
organization; folder names alone are not a security boundary for org Admins.

Detailed participant, flag-attempt, and IP queries use PostgreSQL. Mimir holds
aggregate rates, health, and alerts. Loki holds application/infrastructure logs
and must not receive attempted values or replicated relational rows. Correlate
the systems using CTFd IDs and UTC timestamps, never by copying PII into metric
labels or Loki stream labels.

Initial dashboards:

1. **Event overview and status**: current counts, activity, submissions, solves,
   pipeline freshness, and event clock.
2. **Live submission feed**: source time, result, attempted value, user/team,
   challenge, IP, points, and ingestion lag. Default to a short time range and
   require an explicit dashboard variable before displaying attempted values.
3. **User and team detail**: registration/profile fields, membership, activity,
   submissions, solves, awards, score path, shared IPs, and state flags.
4. **Challenge detail and solve funnel**: views/starts where available, attempts,
   unique participants, correct/incorrect results, hints, first blood, and
   instance health.
5. **Scoreboard history and movement**: snapshots, rank deltas, lead changes,
   awards, and corrections.
6. **Registrations and active participants**: UTC registration cohorts,
   affiliations, verification, bans/hidden state, and rolling activity.
7. **Attempt analysis**: correct, incorrect, other, and rate-limited activity;
   join HTTP-derived 429 aggregates from Mimir because rejected requests might
   not create CTFd submission rows.
8. **First bloods**: earliest solve by challenge with user/team detail.
9. **Hints and unlocks**: unlock timing, cost, subsequent attempts, and solves.
10. **Suspicious behavior**: shared source IPs, unusually repeated attempted
    values, cross-team timing, and rapid account/team changes. These are
    investigation leads, not automatic cheating verdicts.
11. **Challenge instances**: active, failed, expired, owner, challenge, and
    lifecycle timings where the challenge platform supplies them.
12. **Pipeline health**: per-stream checkpoint, source-event lag, batch errors,
    row counts, PostgreSQL health, backups, and agent/service version skew.

Use dashboard queries with explicit time predicates, bounded result limits, and
indexed filters. Grafana's read role has a statement timeout so an accidental
wide investigation cannot monopolize PostgreSQL.

## Data minimization

The agent uses an allowlist matching the JSON Schemas. It must reject rather
than serialize password hashes, access/API tokens, session IDs or secrets,
password-reset tokens, email-verification tokens, OAuth credentials, Flask or
application secret keys, challenge flags/answers as configuration, or MariaDB
connection credentials.

The agent strips query strings from tracking paths and never places raw request
headers, cookies, form bodies, or plugin-defined opaque JSON into tracking
events. New custom/plugin fields require a schema revision and an explicit
sensitivity review rather than falling through an `additionalProperties` map.

Attempted submission values are deliberately accepted because the cockpit
requires them; they are not the stored challenge answer. They remain sensitive,
are encrypted in transit and at rest where supported, and inherit the cockpit
database retention/access boundary. Source IP and email columns receive the
same treatment.

Retain detailed cockpit data for the active event plus 45 days by default, then
export a sanitized aggregate and delete participant-level rows through a
reviewed retention Job. PostgreSQL backup retention must not silently extend
PII retention indefinitely; expire backup recovery windows after the event and
document any legal/incident hold explicitly.

## Upstream references

- [CloudNativePG Barman Cloud plugin usage](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/)
- [CloudNativePG Barman retention policies](https://cloudnative-pg.io/plugin-barman-cloud/docs/retention/)
- [Grafana PostgreSQL datasource provisioning](https://grafana.com/docs/grafana-cloud/observe-and-act/connect-externally-hosted/data-sources/postgres/configure/)
