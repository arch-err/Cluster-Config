from __future__ import annotations

import datetime as dt
import hashlib
import json
from dataclasses import dataclass
from typing import Any

from psycopg import Connection, sql
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from .metrics import CHECKPOINT, LAST_SUCCESS, RECORDS, REPLICATION_LAG
from .protocol import MUTABLE_ENTITIES, ProtocolError, source_timestamp


@dataclass(frozen=True)
class CommitResult:
    checkpoint: int | None
    replay: bool
    reconciled: int = 0


class Store:
    def __init__(self, database_url: str, snapshot_ttl_seconds: int):
        self.pool = ConnectionPool(
            database_url,
            min_size=1,
            max_size=8,
            kwargs={"autocommit": False, "row_factory": dict_row},
            open=False,
        )
        self.snapshot_ttl_seconds = snapshot_ttl_seconds

    def open(self) -> None:
        self.pool.open(wait=True)

    def close(self) -> None:
        self.pool.close()

    def ready(self) -> bool:
        try:
            with self.pool.connection() as connection:
                row = connection.execute(
                    "SELECT EXISTS (SELECT 1 FROM cockpit.schema_migrations WHERE version = 1) AS migrated"
                ).fetchone()
                return bool(row and row["migrated"])
        except Exception:
            return False

    def ingest_events(self, payload: dict[str, Any], request_bytes: bytes) -> CommitResult:
        digest = hashlib.sha256(request_bytes).digest()
        with self.pool.connection() as connection, connection.transaction():
            replay = self._existing_batch(connection, payload, digest, "events")
            if replay is not None:
                return replay
            for record in payload["records"]:
                self._store_record(connection, payload, record, checkpoint=payload["checkpoint"])
            connection.execute(
                """
                INSERT INTO cockpit.ctfd_sync_state
                    (source, entity, checkpoint, schema_version, last_batch_id,
                     last_source_timestamp, last_ingested_at)
                VALUES (%s, %s, %s, %s, %s, %s, clock_timestamp())
                ON CONFLICT (source, entity) DO UPDATE SET
                    checkpoint = GREATEST(cockpit.ctfd_sync_state.checkpoint, EXCLUDED.checkpoint),
                    schema_version = EXCLUDED.schema_version,
                    last_batch_id = EXCLUDED.last_batch_id,
                    last_source_timestamp = GREATEST(
                        cockpit.ctfd_sync_state.last_source_timestamp,
                        EXCLUDED.last_source_timestamp
                    ),
                    last_ingested_at = clock_timestamp()
                """,
                (
                    payload["source"],
                    payload["entity"],
                    payload["checkpoint"],
                    payload["schema_version"],
                    payload["batch_id"],
                    max(
                        source_timestamp(record, payload["sent_at"])
                        for record in payload["records"]
                    ),
                ),
            )
            self._record_batch(connection, payload, digest, "events", payload["checkpoint"])
        self._observe_commit(payload, "events", payload["checkpoint"])
        RECORDS.labels(entity=payload["entity"], operation="events").inc(len(payload["records"]))
        return CommitResult(checkpoint=payload["checkpoint"], replay=False)

    def ingest_snapshot(self, payload: dict[str, Any], request_bytes: bytes) -> CommitResult:
        digest = hashlib.sha256(request_bytes).digest()
        reconciled = 0
        with self.pool.connection() as connection, connection.transaction():
            replay = self._existing_batch(connection, payload, digest, "snapshot")
            if replay is not None:
                return replay
            self._discard_abandoned_snapshots(connection)
            run = connection.execute(
                """
                SELECT next_chunk, completed
                FROM cockpit.snapshot_runs
                WHERE source = %s AND entity = %s AND snapshot_id = %s
                FOR UPDATE
                """,
                (payload["source"], payload["entity"], payload["snapshot_id"]),
            ).fetchone()
            if run is None:
                if payload["chunk"] != 0:
                    raise ProtocolError("snapshot_first_chunk_must_be_zero", 409)
                connection.execute(
                    """
                    INSERT INTO cockpit.snapshot_runs
                        (source, entity, snapshot_id, schema_version, next_chunk,
                         started_at, last_chunk_at, completed)
                    VALUES (%s, %s, %s, %s, 0, clock_timestamp(), clock_timestamp(), false)
                    """,
                    (
                        payload["source"],
                        payload["entity"],
                        payload["snapshot_id"],
                        payload["schema_version"],
                    ),
                )
                expected_chunk = 0
            else:
                if run["completed"]:
                    raise ProtocolError("snapshot_already_completed", 409)
                expected_chunk = run["next_chunk"]
            if payload["chunk"] != expected_chunk:
                raise ProtocolError("snapshot_chunk_out_of_sequence", 409)

            for record in payload["records"]:
                self._store_record(connection, payload, record, checkpoint=None)
                connection.execute(
                    """
                    INSERT INTO cockpit.snapshot_members (source, entity, snapshot_id, source_id)
                    VALUES (%s, %s, %s, %s)
                    ON CONFLICT DO NOTHING
                    """,
                    (
                        payload["source"],
                        payload["entity"],
                        payload["snapshot_id"],
                        record["id"],
                    ),
                )
            connection.execute(
                """
                UPDATE cockpit.snapshot_runs
                SET next_chunk = %s, last_chunk_at = clock_timestamp()
                WHERE source = %s AND entity = %s AND snapshot_id = %s
                """,
                (
                    payload["chunk"] + 1,
                    payload["source"],
                    payload["entity"],
                    payload["snapshot_id"],
                ),
            )
            if payload["complete"]:
                query = sql.SQL(
                    """
                    UPDATE cockpit.{table} AS target
                    SET deleted_at = clock_timestamp()
                    WHERE target.source = %s
                      AND target.deleted_at IS NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM cockpit.snapshot_members AS member
                          WHERE member.source = %s
                            AND member.entity = %s
                            AND member.snapshot_id = %s
                            AND member.source_id = target.source_id
                      )
                    """
                ).format(table=sql.Identifier(f"ctfd_{payload['entity']}"))
                cursor = connection.execute(
                    query,
                    (
                        payload["source"],
                        payload["source"],
                        payload["entity"],
                        payload["snapshot_id"],
                    ),
                )
                reconciled = cursor.rowcount
                connection.execute(
                    """
                    UPDATE cockpit.snapshot_runs
                    SET completed = true, completed_at = clock_timestamp()
                    WHERE source = %s AND entity = %s AND snapshot_id = %s
                    """,
                    (payload["source"], payload["entity"], payload["snapshot_id"]),
                )
            self._record_batch(connection, payload, digest, "snapshot", None)
        self._observe_commit(payload, "snapshot", None)
        RECORDS.labels(entity=payload["entity"], operation="snapshot").inc(len(payload["records"]))
        return CommitResult(checkpoint=None, replay=False, reconciled=reconciled)

    def _store_record(
        self,
        connection: Connection[Any],
        payload: dict[str, Any],
        record: dict[str, Any],
        checkpoint: int | None,
    ) -> None:
        table = sql.Identifier(f"ctfd_{payload['entity']}")
        values = (
            payload["source"],
            record["id"],
            json.dumps(record, separators=(",", ":"), ensure_ascii=False),
            source_timestamp(record, payload["sent_at"]),
            payload["schema_version"],
            payload["batch_id"],
            payload.get("snapshot_id"),
            checkpoint,
        )
        if payload["entity"] in MUTABLE_ENTITIES:
            conflict = sql.SQL(
                """
                DO UPDATE SET
                    payload = EXCLUDED.payload,
                    source_timestamp = EXCLUDED.source_timestamp,
                    ingested_at = clock_timestamp(),
                    schema_version = EXCLUDED.schema_version,
                    batch_id = EXCLUDED.batch_id,
                    snapshot_id = EXCLUDED.snapshot_id,
                    checkpoint = EXCLUDED.checkpoint,
                    deleted_at = NULL
                """
            )
        else:
            conflict = sql.SQL(
                """
                DO UPDATE SET
                    ingested_at = clock_timestamp(),
                    batch_id = EXCLUDED.batch_id,
                    snapshot_id = COALESCE(EXCLUDED.snapshot_id, {table}.snapshot_id),
                    checkpoint = COALESCE({table}.checkpoint, EXCLUDED.checkpoint),
                    deleted_at = NULL
                """
            ).format(table=table)
        query = sql.SQL(
            """
            INSERT INTO cockpit.{table}
                (source, source_id, payload, source_timestamp, schema_version,
                 batch_id, snapshot_id, checkpoint)
            VALUES (%s, %s, %s::jsonb, %s, %s, %s, %s, %s)
            ON CONFLICT (source, source_id) {conflict}
            """
        ).format(table=table, conflict=conflict)
        connection.execute(query, values)

    def _existing_batch(
        self,
        connection: Connection[Any],
        payload: dict[str, Any],
        digest: bytes,
        endpoint: str,
    ) -> CommitResult | None:
        row = connection.execute(
            """
            SELECT endpoint, request_sha256, checkpoint
            FROM cockpit.ingest_batches
            WHERE source = %s AND batch_id = %s
            """,
            (payload["source"], payload["batch_id"]),
        ).fetchone()
        if row is None:
            return None
        if row["endpoint"] != endpoint or bytes(row["request_sha256"]) != digest:
            raise ProtocolError("batch_id_reused_with_different_payload", 409)
        return CommitResult(checkpoint=row["checkpoint"], replay=True)

    @staticmethod
    def _record_batch(
        connection: Connection[Any],
        payload: dict[str, Any],
        digest: bytes,
        endpoint: str,
        checkpoint: int | None,
    ) -> None:
        connection.execute(
            """
            INSERT INTO cockpit.ingest_batches
                (source, batch_id, endpoint, entity, schema_version, sent_at,
                 checkpoint, snapshot_id, snapshot_chunk, snapshot_complete,
                 record_count, request_sha256)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (
                payload["source"],
                payload["batch_id"],
                endpoint,
                payload["entity"],
                payload["schema_version"],
                payload["sent_at"],
                checkpoint,
                payload.get("snapshot_id"),
                payload.get("chunk"),
                payload.get("complete"),
                len(payload["records"]),
                digest,
            ),
        )

    def _discard_abandoned_snapshots(self, connection: Connection[Any]) -> None:
        connection.execute(
            """
            DELETE FROM cockpit.snapshot_runs
            WHERE completed = false
              AND last_chunk_at < clock_timestamp() - (%s * interval '1 second')
            """,
            (self.snapshot_ttl_seconds,),
        )

    @staticmethod
    def _observe_commit(payload: dict[str, Any], endpoint: str, checkpoint: int | None) -> None:
        now = dt.datetime.now(dt.UTC)
        LAST_SUCCESS.labels(source=payload["source"], endpoint=endpoint).set(now.timestamp())
        newest = max(
            (source_timestamp(record, payload["sent_at"]) for record in payload["records"]),
            default=dt.datetime.fromisoformat(payload["sent_at"].replace("Z", "+00:00")),
        )
        REPLICATION_LAG.labels(source=payload["source"], entity=payload["entity"]).set(
            max(0, (now - newest).total_seconds())
        )
        if checkpoint is not None:
            CHECKPOINT.labels(source=payload["source"], entity=payload["entity"]).set(checkpoint)
