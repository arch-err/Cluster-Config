from __future__ import annotations

import gzip
import json
import logging
from pathlib import Path

from fastapi.testclient import TestClient

from ctfd_cockpit_ingest.api import create_app
from ctfd_cockpit_ingest.config import Config
from ctfd_cockpit_ingest.database import CommitResult


class FakeStore:
    def __init__(self) -> None:
        self.events: list[dict[str, object]] = []

    def open(self) -> None:
        return None

    def close(self) -> None:
        return None

    def ready(self) -> bool:
        return True

    def ingest_events(self, payload, _request_bytes) -> CommitResult:  # type: ignore[no-untyped-def]
        self.events.append(payload)
        return CommitResult(checkpoint=payload["checkpoint"], replay=False)

    def ingest_snapshot(self, _payload, _request_bytes) -> CommitResult:  # type: ignore[no-untyped-def]
        return CommitResult(checkpoint=None, replay=False)


def config() -> Config:
    return Config(
        database_url="postgresql://unused",
        ingest_token="ingest-token",
        allowed_source="myrctf",
        mimir_token="mimir-token",
        loki_token="loki-token",
        mimir_tenant_id="myrctf-analytics",
        loki_tenant_id="myrctf-operations",
        mimir_write_url="http://mimir.invalid/api/v1/push",
        loki_write_url="http://loki.invalid/loki/api/v1/push",
        schema_dir=Path(__file__).parents[1] / "schemas",
        migration_dir=Path(__file__).parents[1] / "migrations",
        max_compressed_bytes=1024 * 1024,
        max_expanded_bytes=2 * 1024 * 1024,
        max_batch_records=500,
        snapshot_staging_ttl_seconds=3600,
    )


def event() -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "source": "myrctf",
        "sent_at": "2026-09-17T12:00:00Z",
        "batch_id": "ca93493b-a015-4ea2-9291-d18f65a11756",
        "entity": "submissions",
        "checkpoint": 1,
        "records": [{"id": 1, "provided": "FLAG{must-not-be-logged}"}],
    }


def request(client: TestClient, payload: dict[str, object], token: str = "ingest-token"):
    return client.post(
        "/api/v1/events",
        content=gzip.compress(json.dumps(payload).encode()),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Content-Encoding": "gzip",
        },
    )


def test_exact_checkpoint_acknowledgement() -> None:
    store = FakeStore()
    with TestClient(create_app(config(), store)) as client:
        response = request(client, event())
    assert response.status_code == 200
    assert response.json() == {"checkpoint": 1}
    assert len(store.events) == 1


def test_unauthorized_request_is_not_processed() -> None:
    store = FakeStore()
    with TestClient(create_app(config(), store)) as client:
        response = request(client, event(), "wrong")
    assert response.status_code == 401
    assert not store.events


def test_sensitive_body_is_not_logged(caplog) -> None:  # type: ignore[no-untyped-def]
    caplog.set_level(logging.INFO)
    with TestClient(create_app(config(), FakeStore())) as client:
        assert request(client, event()).status_code == 200
    assert "FLAG{must-not-be-logged}" not in caplog.text


def test_invalid_payload_has_no_partial_write() -> None:
    store = FakeStore()
    payload = event()
    payload["checkpoint"] = 2
    with TestClient(create_app(config(), store)) as client:
        response = request(client, payload)
    assert response.status_code == 422
    assert not store.events
