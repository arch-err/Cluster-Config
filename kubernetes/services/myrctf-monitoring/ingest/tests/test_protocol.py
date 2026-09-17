from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from ctfd_cockpit_ingest.protocol import ProtocolError, Validators, validate_payload


SCHEMA_DIR = Path(__file__).parents[1] / "schemas"


def event() -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "source": "myrctf",
        "sent_at": "2026-09-17T12:00:00Z",
        "batch_id": "ca93493b-a015-4ea2-9291-d18f65a11756",
        "entity": "submissions",
        "checkpoint": 2,
        "records": [{"id": 1}, {"id": 2, "provided": "sensitive"}],
    }


def validate(payload: dict[str, object]) -> dict[str, object]:
    return validate_payload(
        payload,
        endpoint="events",
        validators=Validators.load(SCHEMA_DIR),
        allowed_source="myrctf",
        max_records=500,
    )


def test_authoritative_schema_files_match_agent() -> None:
    agent_dir = Path("/home/j/MyrCTF/Infra/stacks/ctfd/cockpit-agent/protocol")
    if not agent_dir.exists():
        pytest.skip("agent checkout is not available")
    assert json.loads((SCHEMA_DIR / "event-batch.schema.json").read_text()) == json.loads(
        (agent_dir / "event-batch.schema.json").read_text()
    )
    assert json.loads((SCHEMA_DIR / "snapshot-batch.schema.json").read_text()) == json.loads(
        (agent_dir / "snapshot-batch.schema.json").read_text()
    )


def test_valid_event() -> None:
    assert validate(event())["checkpoint"] == 2


@pytest.mark.parametrize(
    ("mutation", "code"),
    [
        (lambda value: value.update(schema_version="2.0"), "schema_validation_failed"),
        (lambda value: value.update(source="other"), "source_not_allowed"),
        (lambda value: value.update(checkpoint=3), "checkpoint_mismatch"),
        (lambda value: value["records"].append({"id": 2}), "duplicate_source_id"),
        (
            lambda value: value["records"][0].update(password_hash="forbidden"),
            "forbidden_authentication_field",
        ),
    ],
)
def test_rejections(mutation, code: str) -> None:  # type: ignore[no-untyped-def]
    payload = copy.deepcopy(event())
    mutation(payload)
    with pytest.raises(ProtocolError, match=code):
        validate(payload)
