# Cluster-Config language

Terms used to distinguish repository maintenance from changes to the running system.

## Language

**Repository alignment**: Bringing documentation and repository organization into agreement with the intended configuration. It does not include software upgrades.

**Production baseline**: The configuration on which the currently running system is based. It is distinct from a verified inventory of live resources.

**Legacy archive**: A preserved historical configuration that is kept for reference and recovery, rather than ongoing maintenance.

**Retained service**: A service whose configuration remains available although it is disabled. Retention of configuration does not establish that its data still exists or that it can be safely re-enabled.

**State-preserving refactor**: A change to repository organization that preserves the deployed resource definitions and behavior. Any exception requires J’s explicit approval.

**Zero-diff gate**: A requirement that the proposed configuration has no unapproved differences from the live baseline before any synchronization. Hidden differences and comparison failures do not satisfy the gate.

**Service**: A directory grouping a logical service's declarations, values, resources, and encrypted secrets. It can contain several Helm components and retains its existing Argo root owner regardless of directory placement.

**Component**: One upstream Helm chart represented by an existing Argo Application, such as a service's OAuth2 proxy. Grouping components does not merge their Applications.

**zgit**: J's frontend for interacting with Forgejo through its API. It is the intended everyday interface for J's forge workflow.

## MyrCTF observability

**Event analytics**: Aggregate measurements and event records that describe how a MyrCTF event progresses. Participant-level records are sensitive and are not operational telemetry.

**Operational telemetry**: Measurements, logs, and traces about the availability and performance of the MyrCTF platform and its dependencies.

**Active participant**: A registered user who made at least one submission during a stated rolling time window. A login or an open browser session alone does not make a participant active.

**Eligible team**: A registered team that made at least one submission after the event started. Completion percentages use eligible teams as their denominator unless a dashboard explicitly says otherwise.

**First blood**: The earliest accepted submission for a challenge, ordered by the CTFd submission timestamp and then submission ID for a deterministic tie-break.

**Source**: One stable CTFd installation whose identifiers and replication progress form an independent namespace.
_Avoid_: Source instance

**Source event**: An immutable fact copied from a named CTFd source table while preserving that table's identifier and event time.

**Durable checkpoint**: The highest source record identifier fully committed for one source and entity event stream. It is the only position from which an agent may safely resume.

**Snapshot**: An authoritative point-in-time enumeration of one source entity, delivered as a contiguous sequence of chunks under one snapshot identifier.

**Completed snapshot**: A snapshot whose contiguous final chunk has `complete=true`. Only a completed snapshot may mark source rows absent from its accumulated membership as deleted.

**Abandoned snapshot**: A snapshot that never receives its contiguous final chunk. It has no deletion authority and may be discarded after a bounded staging period.

**Tombstone**: A replicated row's soft-deleted state. It may result from explicit deletion input or authoritative absence from a completed snapshot; incomplete snapshots never create tombstones.
