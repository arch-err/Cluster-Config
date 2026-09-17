# MyrCTF observability design

## TL;DR

Run a dedicated, single-replica LGTM stack in the public `myrctf-monitoring`
namespace. Use monolithic Loki, Tempo, and Mimir with the classic Mimir ingest
path (no Kafka), external S3-compatible object storage, one Grafana, and one
cluster-side Alloy deployment. Expose only Grafana and an authenticated
ingestion proxy through the public Gateway.

Separate `analytics` and `operations` as Mimir/Loki tenants, Grafana folders,
data sources, credentials, retention policies, and alert groups. A single
Pocket ID group controls access to the Grafana organization. Pocket ID at
`auth.3rr.dev` is the only human authentication provider. The CTF VM only makes
outbound HTTPS connections and the cluster never receives a credential for the
CTFd admin API.

Start with aggregate event metrics, Grafana, Mimir, the ingestion proxy, and
the two Alloy agents. Add structured events in Loki next and traces in Tempo
only once there is useful instrumentation.

The organizer-only read model and replication API for detailed CTFd records is
specified separately in the [CTFd Cockpit backend](myrctf-cockpit/README.md).
It adds PostgreSQL and an outbound-only `ctfd-cockpit-agent` path without
turning Loki into a relational store.

## Goals and boundaries

The platform serves one small annual CTF. It favors low operational overhead
over horizontal scalability. A single pod can temporarily interrupt queries or
ingestion during an upgrade; S3-backed data must survive that interruption.
This is an explicit availability trade-off, not a claim of HA.

All MyrCTF observability workloads and their Kubernetes resources live in
`myrctf-monitoring`. Shared cluster services such as the public Gateway,
Cloudflare Tunnel, Argo CD, SOPS operator, and public Pocket ID remain in their
existing namespaces.

The trust boundary is deliberately asymmetric:

- The VM can push telemetry to the cluster over authenticated HTTPS.
- The cluster cannot initiate connections to the VM.
- The CTFd API token exists only on the VM and is read-only.
- Grafana is the only human-facing LGTM service.
- Mimir, Loki, Tempo, Alloy, and object storage have no public query or admin
  endpoints.

## 1. Architecture and data flow

```text
CTFd Docker Compose VM                         public-services Kubernetes

CTFd local API <--- read-only token ---+
                                      CTFd exporter -- /metrics (loopback)
MariaDB -- SELECT-only --> ctfd-cockpit-agent -- gzip JSON/HTTPS --------+
CTFd/Caddy/FRP/container logs ---------+                 |
node, MariaDB, Redis exporters --------------------------+-- VM Alloy
instrumented services -- OTLP ---------------------------+      |
                                                               HTTPS
                                               per-signal basic credentials
                                                                  |
Cloudflare Tunnel -> public Gateway -> ingestion proxy -----------+
                                      |          |          |     |
                                  Mimir       Loki       Tempo  cockpit ingest
                               analytics/  analytics/   operations   |
                               operations  operations      tenant  PostgreSQL
                                      \          |          /       /
                                       +------ Grafana ------------+
                                               |
                                      Pocket ID OIDC only

cluster-side Alloy -> LGTM self-metrics/logs -> operations tenants
S3-compatible object storage <- blocks/chunks/traces and ruler state
```

The VM Alloy does four jobs:

1. Scrape the local CTFd exporter and operational exporters.
2. Convert bounded, machine-readable Caddy events such as HTTP 429 responses
   into aggregate metrics where CTFd itself cannot observe them.
3. Ship structured CTF events and operational logs to separate Loki paths.
4. Batch and forward OTLP traces. Its on-disk write-ahead queues absorb short
   WAN or cluster outages.

The CTFd exporter polls incremental CTFd API pages using a persistent cursor.
It exposes cumulative event-to-date counters and current gauges, and emits one
versioned JSON log record for each newly observed detailed event. Its state is
on a small persistent VM volume so a restart does not replay events or reset
derived counters. Raw CTFd responses are never logged.

The cluster Alloy scrapes only the components in `myrctf-monitoring` and writes
their self-observability data to the `operations` tenants. It is a Deployment,
not a cluster-wide DaemonSet; the existing cluster monitoring remains separate.

### Tenancy

Use these stable tenant IDs:

| Backend | Tenant | Content |
| --- | --- | --- |
| Mimir | `myrctf-analytics` | Aggregate event metrics and recording rules |
| Mimir | `myrctf-operations` | VM, application, dependency, and LGTM metrics |
| Loki | `myrctf-analytics` | Sensitive structured event records |
| Loki | `myrctf-operations` | Application, proxy, container, and platform logs |
| Tempo | `myrctf-operations` | Application and platform traces |

Mimir and Loki multi-tenancy provide the actual storage boundary. Metric name
prefixes and Loki labels make the distinction visible, but are not treated as
an authorization mechanism.

## 2. Helm and Argo CD structure

Add one repo service owned by the `apps` root. Each component remains an Argo
CD Application, but every component targets the same namespace.

```text
kubernetes/services/myrctf-monitoring/
├── service.yaml
├── grafana.values.yaml
├── loki.values.yaml
├── mimir.values.yaml
├── tempo.values.yaml
├── alloy.values.yaml
├── edge.values.yaml
├── cockpit-ingest.values.yaml
├── dashboards/
│   ├── analytics/*.json
│   ├── operations/*.json
│   └── cockpit/*.json
├── rules/
│   ├── analytics-recording.yaml
│   ├── analytics-alerts.yaml
│   └── operations-alerts.yaml
├── resources/
│   ├── network-policies.yaml
│   ├── provisioning-configmaps.yaml
│   ├── cockpit-postgres.yaml
│   ├── cockpit-backup.yaml
│   ├── cockpit-migration-job.yaml
│   └── object-store-canary.yaml
└── secrets/
    ├── object-storage.yaml
    ├── ingestion-credentials.yaml
    ├── cockpit-database-roles.yaml
    ├── cockpit-backup-storage.yaml
    ├── grafana-oidc.yaml
    └── alert-contact-points.yaml
```

Proposed `service.yaml` components:

| Component | Helm chart | Mode |
| --- | --- | --- |
| `myrctf-grafana` | upstream `grafana` | One replica, persistent SQLite initially |
| `myrctf-loki` | upstream `loki` | Monolithic/single binary, one replica |
| `myrctf-mimir` | `bjw-s/app-template` running a pinned Mimir image | `-target=all`, classic ingest, one replica |
| `myrctf-tempo` | upstream `tempo` | Monolithic, one replica |
| `myrctf-alloy` | upstream `alloy` | One Deployment replica |
| `myrctf-edge` | `bjw-s/app-template` running pinned Caddy | Two small replicas if desired |
| `ctfd-cockpit-ingest` | `bjw-s/app-template` running the custom ingest image | One replica, stateless |

The cockpit PostgreSQL `Cluster`, managed roles, Barman Cloud `ObjectStore`,
`ScheduledBackup`, and migration Job are supporting resources in the same
namespace rather than separate public applications. See the cockpit contract
for their ownership, ordering, and privilege model.

The official `mimir-distributed` chart is intentionally not used: it deploys a
microservice topology and now defaults to Kafka-backed ingest storage. Mimir's
single binary supports `-target=all`; a small app-template declaration is less
complex and makes `ingest_storage.enabled: false` explicit.

Use sync waves in dependency order: secrets/configuration, Mimir/Loki/Tempo,
Alloy, Grafana, then public routes. Only these routes are created:

- `myrctf-grafana.3rr.dev` -> Grafana
- `myrctf-telemetry.3rr.dev` -> Caddy ingestion proxy

The route declarations select `gateway: public`, which gives
`myrctf-monitoring` the repository's public namespace labels and baseline
isolation. Add namespace-local Cilium policies that permit only these flows:

- public Gateway -> Grafana and Caddy;
- Caddy -> backend write ports;
- Caddy -> cockpit ingest, and cockpit ingest -> PostgreSQL RW service;
- Grafana -> backend query ports and `auth.3rr.dev:443`;
- Grafana -> PostgreSQL RO service using the dedicated read-only role;
- Alloy -> backend write ports and component metrics ports;
- Loki/Mimir/Tempo -> DNS and their own S3 endpoint;
- all other ingress and private/LAN egress denied.

Dashboard JSON, dashboard providers, data sources, alert rules, notification
policies, and recording rules are mounted from Git-backed ConfigMaps. Do not use
editable dashboards as the source of truth.

### Grafana access model

Use one Grafana organization and one Pocket ID group named
`myrctf-monitoring`. Restrict the Pocket ID client to that group and map its
members to Grafana organization `Admin`. This is close to administrator access
for the MyrCTF Grafana organization without granting the server-wide
`GrafanaAdmin` role.

Use a strict role expression equivalent to:

```ini
role_attribute_path = contains(groups[*], 'myrctf-monitoring') && 'Admin' || 'None'
role_attribute_strict = true
allow_assign_grafana_admin = false
```

Keep role synchronization enabled so Pocket ID membership remains the source
of truth. A user outside the group must fail login rather than fall through to
Grafana's default Viewer role.

Within the organization, provision `Event Analytics`, `Operations`, and
`Platform` folders plus an organizer-only `CTFd Cockpit` folder. Provision
separate analytics and operations data sources
with fixed tenant headers. All group members can access both domains; the
folders express information ownership and prevent accidental mixing, while
backend tenancy still enforces retention, ingestion credentials, and storage
separation. Grafana provisioning can target the default organization directly,
so no API bootstrap job or manually managed Grafana Team is required.

## 3. Authentication and network boundary

### Human access

The public Pocket ID realm is the only interactive authentication mechanism.
For Grafana set:

- Generic OAuth/OIDC enabled with PKCE and the `groups` scope;
- `auth.basic.enabled=false`;
- `auth.anonymous.enabled=false`;
- login form disabled and OAuth auto-login enabled;
- sign-up allowed only as OIDC shadow-user creation;
- the Pocket ID client restricted to the single `myrctf-monitoring` group;
- all other OAuth, LDAP, auth-proxy, and Grafana.com providers disabled.

The existing OIDC bootstrap template is tied to the internal Pocket ID service.
Before implementation, extend it with an explicit realm/provider selector, or
add a namespace-local bootstrap Job for `auth.3rr.dev`. Never silently mint this
client in the internal `pocket-id` realm.

There is no standing password-based break-glass login. Recovery from a Pocket
ID outage is a reviewed Git/SOPS change that temporarily enables a recovery
path and is reverted immediately afterward.

### Workload ingestion

OIDC is not appropriate for a headless Alloy remote-write client. The Caddy
edge uses separate long random basic-auth credentials for these fixed paths:

```text
POST /mimir/analytics/api/v1/push
POST /mimir/operations/api/v1/push
POST /loki/analytics/loki/api/v1/push
POST /loki/operations/loki/api/v1/push
POST /tempo/operations/v1/traces
```

Caddy validates the path-specific credential, strips the routing prefix, sets
the fixed `X-Scope-OrgID`, and proxies to the corresponding internal write
endpoint. The caller cannot choose or override the tenant header. Drop incoming
`X-Scope-OrgID` and forwarding headers before adding trusted values.

All credentials are unique, SOPS-encrypted, mounted from Secrets, and rotated
before each event and after any suspected exposure. Caddy logs neither
`Authorization` nor request bodies. Apply body-size, concurrency, and backend
ingestion limits; Cloudflare supplies coarse abuse/rate controls.

From the VM, Alloy verifies the public CA and hostname and uses its credentials
from root-readable files, not inline configuration. TLS terminates at
Cloudflare; the authenticated Cloudflare Tunnel carries traffic to the
HTTP-only public Gateway. Namespace policies protect the final in-cluster hop.
If end-to-end TLS without Cloudflare termination is later required, add a
dedicated TLS-passthrough design rather than assuming the current Gateway does
it.

Backend read/admin APIs have ClusterIP Services only. Object-storage keys are
one per backend and bucket-scoped. Grafana data sources use server-side proxy
access and fixed tenant headers, so browsers never receive backend credentials.
The cockpit PostgreSQL datasource likewise uses server-side proxy access and a
read-only database role; its password never reaches the browser.

## 4. Storage and retention

Use an external S3-compatible service with three independent buckets and three
least-privilege credentials:

| Data | Backend | Recommended retention | Local persistent working space |
| --- | --- | --- | --- |
| Aggregate analytics metrics | Mimir analytics tenant | 400 days | 20 GiB WAL/cache |
| Operational metrics | Mimir operations tenant | 30 days | shared Mimir WAL/cache |
| Detailed analytics events | Loki analytics tenant | 45 days | 10 GiB active index/cache |
| Operational logs | Loki operations tenant | 14 days | shared Loki index/cache |
| Traces | Tempo operations tenant | 7 days | 10 GiB WAL/cache |
| Grafana state | retained RWO PVC | until intentionally retired | 5 GiB |
| Detailed cockpit records | PostgreSQL | event plus 45 days by default | 30 GiB retained RWO PVC plus S3 backups |

Suggested buckets are `myrctf-mimir`, `myrctf-loki`, and `myrctf-tempo`.
Enable server-side encryption and versioning if the provider supports them.
Backend compaction/retention remains authoritative; bucket lifecycle rules are
a safety net set several days longer, plus cleanup for abandoned multipart
uploads. Never share object prefixes between backends.

Mimir runtime overrides enforce retention per tenant. Loki per-tenant overrides
do the same and the compactor performs deletion. Tempo's compactor enforces
trace retention. Keep one replica and replication factor one throughout; S3
protects persisted blocks, but the local WAL PVC is still needed to survive a
pod restart before upload.

The 400-day aggregate window enables year-over-year comparisons without
retaining participant-level history. At event close, optionally export a small
sanitized summary and delete detailed event logs early. Validate all retention
with synthetic old data; an S3 lifecycle policy is not a substitute for that
test.

## 5. Metric and event schema

### Definitions

- Active participant: distinct registered user with at least one submission in
  the stated rolling window. Publish 5-minute, 15-minute, and 1-hour windows.
- Eligible team: team with at least one submission after event start.
- Completion ratio: teams that solved a challenge divided by eligible teams.
  Also show a separately named registered-team ratio where useful.
- First blood: earliest accepted submission by CTFd timestamp, then submission
  ID. A later administrative correction emits a correction event.
- Submission rate counts all CTFd submission outcomes. HTTP rate-limit rate is
  derived separately from trusted Caddy 429 logs because rejected requests may
  never reach CTFd.

### Aggregate metrics in Mimir

All custom analytics metrics start with `myrctf_event_`; all custom operational
metrics start with `myrctf_ops_`. Standard exporter metrics such as `node_*`,
`container_*`, `mysql_*`, and `redis_*` retain their ecosystem names but exist
only in the operations tenant.

Allowed common labels are `event`, `environment`, and `source`. Analytics
series may additionally use bounded `challenge_id`, `category`, `outcome`,
`state`, `reason_class`, and `window` values. Challenge IDs are bounded by the
published challenge set and disappear after the 400-day retention window.

Initial exporter metrics:

| Metric | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `myrctf_event_registered_users` | gauge | common | Current registered users |
| `myrctf_event_registered_teams` | gauge | common | Current registered teams |
| `myrctf_event_eligible_teams` | gauge | common | Teams active since event start |
| `myrctf_event_active_participants` | gauge | `window` | Distinct submitting users in the window |
| `myrctf_event_active_teams` | gauge | `window` | Distinct submitting teams in the window |
| `myrctf_event_submissions_total` | counter | `outcome`, optionally challenge/category | Event-to-date submissions |
| `myrctf_event_solves_total` | counter | challenge/category | Accepted submissions |
| `myrctf_event_challenge_solved_teams` | gauge | challenge/category | Distinct teams that solved the challenge |
| `myrctf_event_challenge_completion_ratio` | gauge | challenge/category | Solving eligible teams / eligible teams |
| `myrctf_event_challenge_first_solve_timestamp_seconds` | gauge | challenge/category | Unix time of first blood; absent until solved |
| `myrctf_event_challenge_time_to_first_solve_seconds` | gauge | challenge/category | Event start to first blood |
| `myrctf_event_scoreboard_teams_scored` | gauge | common | Teams with non-zero score |
| `myrctf_event_scoreboard_teams_by_score_band` | gauge | `score_band` | Current team count in fixed score bands |
| `myrctf_event_scoreboard_leader_score` | gauge | common | Current leading score |
| `myrctf_event_scoreboard_rank_changes_total` | counter | common | Rank changes observed between snapshots |
| `myrctf_event_challenge_instances` | gauge | challenge/category, `state` | Current instance count by bounded state |
| `myrctf_event_challenge_instance_failures_total` | counter | challenge/category, `reason_class` | Event-to-date failures by controlled reason |
| `myrctf_event_exporter_last_success_timestamp_seconds` | gauge | common | Last successful complete API poll |
| `myrctf_event_exporter_poll_errors_total` | counter | `reason_class` | Poll failures without raw error text |

Do not attach usernames, team names, emails, IP addresses, user/team IDs,
submission or flag text, trace IDs, instance IDs, URLs with query strings, or
container IDs as metric labels. Drop Docker-generated container IDs and other
unbounded labels in Alloy before remote write.

Recording rules make dashboard queries cheap and definitions consistent:

```promql
myrctf_event:submissions_per_minute:5m
  = sum(rate(myrctf_event_submissions_total[5m])) * 60

myrctf_event:solves_per_minute:15m
  = sum(rate(myrctf_event_solves_total[15m])) * 60

myrctf_event:challenge_attempts_per_solve
  = sum by (event, challenge_id, category) (myrctf_event_submissions_total)
    / clamp_min(sum by (event, challenge_id, category) (myrctf_event_solves_total), 1)

myrctf_event:submission_success_ratio:15m
  = sum(rate(myrctf_event_submissions_total{outcome="correct"}[15m]))
    / clamp_min(sum(rate(myrctf_event_submissions_total[15m])), 0.001)
```

Use `outcome` values `correct`, `incorrect`, and `rate_limited`; keep unexpected
states under `other`. The rate-limited series is generated from Caddy and must
not also be counted as a CTFd submission if CTFd never received it.

### Sanitized event logs in Loki

Each event is one JSON object with `schema_version`, `timestamp`, `event_type`,
`event`, `participant_ref`, `team_ref`, `challenge_id`, `category`, `outcome`,
and event-specific numeric fields. `participant_ref` and `team_ref` are stable
per-event HMAC pseudonyms produced on the VM. The HMAC key never leaves the VM
and rotates for each annual event.

Useful event types include:

- `registration_observed`, `team_created`;
- `submission_observed`, `solve_observed`, `first_blood_observed`;
- `scoreboard_rank_changed`, `score_adjusted`;
- `challenge_instance_started`, `challenge_instance_failed`,
  `challenge_instance_expired`;
- `exporter_gap_detected` and `event_corrected`.

Only `telemetry_class`, `service_name`, `environment`, `event`, and
`event_type` become Loki stream labels. IDs, pseudonyms, challenge identifiers,
error messages, and trace IDs remain JSON fields parsed at query time. Do not
send names, emails, IPs, user agents, cookies, authorization headers, flags, or
submission text at all unless a separately approved incident workflow requires
it.

Loki is not the detailed CTFd read model. Raw attempted values, emails, source
IPs, full profiles, and relational history belong only in the organizer-only
Cockpit PostgreSQL database. Loki receives sanitized CTFd/application logs and
bounded event annotations useful for cross-signal correlation.

Tempo spans use normal low-cardinality service/resource attributes. Strip
cookies, authorization data, query strings, database statements containing
values, and participant identifiers. Link logs and traces with trace IDs as
non-indexed fields.

## 6. Initial dashboards and alerts

### Event Analytics folder

1. **Event overview**: registrations, active participants/teams, total and
   per-minute submissions/solves, success ratio, scored teams, leading score,
   and event timeline annotations.
2. **Challenge performance**: attempts, solves, completion ratio,
   attempts-to-solve, time-to-first-solve, and unresolved challenges by
   category/challenge.
3. **Participation and progression**: active participant windows, cumulative
   registrations, cumulative solves, score distribution, lead changes, and
   rank-change volume. Named-team drill-down uses restricted Loki queries, not
   labels or a public dashboard.
4. **First bloods**: challenge/category, first-solve time, and anonymized winner
   reference. Reveal real identity only by consulting CTFd under its own access
   controls.
5. **Challenge instances**: active/failed/expired totals and failure classes;
   omit panels when the challenge platform cannot expose the data reliably.

### Operations and Platform folders

1. **CTFd service health**: external availability, request rate, latency,
   status classes, container restarts, exporter/API poll health.
2. **VM and containers**: CPU, memory, disk/inodes, network, pressure, Docker
   container resource totals without container-ID labels.
3. **Dependencies**: MariaDB connections/query latency/errors, Redis memory,
   evictions and hit rate, Caddy request/TLS health, FRP tunnel health.
4. **LGTM ingestion**: accepted/rejected samples, log bytes, spans, queue/WAL
   health, last successful VM delivery, tenant limits, compaction, S3 errors.
5. **Challenge health**: aggregate instance capacity, failures, expirations, and
   challenge-facing availability where probes are safe.

### Alert groups

Page-worthy operational alerts:

- CTFd unavailable for 2 minutes from the VM-local probe;
- p95 HTTP latency above the agreed SLO for 10 minutes or 5xx ratio above 5%;
- exporter has not completed a poll for 5 minutes;
- VM Alloy remote-write/log/trace queue is near capacity or has dropped data;
- MariaDB down, connection exhaustion, replication issue if applicable, or
  disk predicted full within 24 hours;
- Redis down, sustained evictions, or memory above 90%;
- FRP tunnel down and challenge traffic depends on it;
- challenge instance failure ratio above threshold;
- Mimir/Loki/Tempo cannot write to S3, compaction is failing, WAL/PVC above
  80%, or ingestion rejects valid VM traffic;
- Grafana or the authenticated ingestion endpoint is unavailable.

Non-paging event signals:

- no submissions for 15 minutes while the event is open and participants were
  recently active;
- no solves for 30 minutes, clearly labelled as an event-state signal rather
  than an outage;
- rate-limited requests exceed a baseline;
- a challenge has many attempts and no solves, or a sharp incorrect/correct
  ratio change;
- no first blood after a challenge-specific threshold;
- unexpected scoreboard correction or unusually high rank-change volume.

Keep alert definitions in Git. Put event signals in the `Event Analytics`
Grafana alert folder and operational alerts in `Operations`. Use Grafana
Unified Alerting for notification routing and Mimir ruler for recording rules.
Contact-point secrets come from SOPS-backed environment/file references, never
plain provisioning YAML. Route warnings and pages separately and inhibit
symptom alerts when the VM or ingestion path is known down.

## 7. Staged implementation

### Stage 0: contract and synthetic fixture

- Fix the CTFd version/API contract, event start/end semantics, challenge
  instance source, and controlled outcome/reason vocabularies.
- Build a sanitized API fixture and test exporter pagination, deletion,
  correction, tie, restart, and API-outage cases.
- Create Pocket ID groups and the Grafana client in the public realm.
- Provision S3 buckets, scoped keys, lifecycle safety rules, and SOPS secrets.

Exit criterion: the exporter produces deterministic metrics/events without
participant data in labels or logs.

### Stage 1: smallest useful deployment

- Deploy monolithic Mimir, Grafana, Caddy edge, and cluster Alloy in
  `myrctf-monitoring`.
- Enable Pocket ID-only Grafana login, strict organization-Admin mapping, and
  the separate analytics/operations data sources.
- Run the VM Alloy and exporter; ingest aggregate analytics plus core CTFd/VM
  operational metrics.
- Ship the Event overview, Challenge performance, CTFd health, and ingestion
  health dashboards; alert on CTFd down and exporter/ingestion gaps.

Exit criterion: a WAN interruption buffers and later delivers metrics, users
outside the Pocket ID group cannot log in, group members receive organization
Admin but not server GrafanaAdmin, and the cluster cannot connect to the VM.

### Stage 2: CTFd Cockpit read model

- Deploy the dedicated CloudNativePG cluster, managed roles, WAL archiving,
  daily backups, migrations, and `ctfd-cockpit-ingest`.
- Deploy the VM-side SELECT-only agent against the versioned contract and
  provision the organizer-only PostgreSQL datasource and Cockpit folder.
- Exercise idempotent replay, sequence gaps, tombstones, WAN buffering,
  credential rotation, PII retention, and point-in-time restore.

Exit criterion: all contract tables converge after replay, the acknowledged
checkpoint never exceeds a committed transaction, Grafana cannot write to the
database, and a backup restores into an isolated namespace.

### Stage 3: structured events and logs

- Deploy monolithic Loki with the two tenants and per-tenant retention.
- Add exporter event JSON, CTFd/Caddy/FRP/container logs, redaction, and
  pseudonymization.
- Add first-blood, progression, instance, and dependency dashboards and their
  non-paging event signals.

Exit criterion: label-cardinality checks pass, sensitive fields are absent,
and retention deletion is demonstrated end to end.

### Stage 4: traces where they pay for themselves

- Deploy monolithic Tempo and enable OTLP/HTTP through the edge.
- Instrument CTFd request handling, exporter polling, and challenge lifecycle
  operations before enabling broad sampling.
- Start at low head sampling, keep errors/slow traces, and add trace-to-log and
  metrics exemplars without participant attributes.

Exit criterion: a slow or failed request can be followed across a trace and
correlated to sanitized logs without exposing participant data.

### Stage 5: pre-event hardening

- Load-test expected peak submissions at 2-3x, including 429 behavior.
- Test credential rotation, S3 denial/failure, PVC restart, Pocket ID outage,
  WAN outage, queued replay, and full restore from Git plus retained storage.
- Measure real ingest volume and tune limits/retention instead of scaling out by
  default.
- Freeze chart/image digests before the event and rehearse rollback.

Scale beyond one backend replica or introduce Kafka only after measurements
show that event load or availability requirements exceed this design.

## Upstream design references

- [Mimir deployment modes](https://grafana.com/docs/mimir/latest/references/architecture/deployment-modes/)
- [Loki Helm deployment modes](https://grafana.com/docs/loki/latest/setup/install/helm/)
- [Tempo Helm charts](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/deploy/kubernetes/helm-chart/)
- [Grafana Generic OAuth](https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/generic-oauth/)
- [Grafana dashboard provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
