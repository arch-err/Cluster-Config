from __future__ import annotations

import datetime as dt
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


ENTITIES = (
    "users",
    "teams",
    "challenges",
    "hints",
    "awards",
    "tags",
    "topics",
    "challenge_topics",
    "solutions",
    "files",
    "flags",
    "unlocks",
    "tracking",
    "notifications",
    "pages",
    "comments",
    "fields",
    "field_entries",
    "brackets",
    "ratings",
    "submissions",
    "dynamic_challenge",
    "dynamic_docker_challenge",
    "whale_container",
    "services",
)

EVENT_ENTITIES = frozenset(
    {
        "submissions",
        "tracking",
        "unlocks",
        "awards",
        "notifications",
        "comments",
        "ratings",
        "whale_container",
        "services",
    }
)

MUTABLE_ENTITIES = frozenset(
    {
        "users",
        "teams",
        "challenges",
        "hints",
        "tags",
        "topics",
        "challenge_topics",
        "solutions",
        "files",
        "flags",
        "pages",
        "fields",
        "field_entries",
        "brackets",
        "dynamic_challenge",
        "dynamic_docker_challenge",
        "whale_container",
        "services",
    }
)

FORBIDDEN_FIELDS = frozenset(
    {
        "password",
        "password_hash",
        "secret",
        "access_token",
        "session_secret",
        "password_reset_token",
        "verification_token",
        "application_secret_key",
    }
)

SOURCE_TIME_FIELDS = ("date", "created", "start_time")
MAX_SOURCE_ID = 9_223_372_036_854_775_807


class ProtocolError(ValueError):
    def __init__(self, code: str, status: int = 422):
        super().__init__(code)
        self.code = code
        self.status = status


@dataclass(frozen=True)
class Validators:
    events: Draft202012Validator
    snapshot: Draft202012Validator

    @classmethod
    def load(cls, schema_dir: Path) -> "Validators":
        checker = FormatChecker()

        def validator(name: str) -> Draft202012Validator:
            with (schema_dir / name).open(encoding="utf-8") as stream:
                schema = json.load(stream)
            Draft202012Validator.check_schema(schema)
            return Draft202012Validator(schema, format_checker=checker)

        return cls(
            events=validator("event-batch.schema.json"),
            snapshot=validator("snapshot-batch.schema.json"),
        )


def validate_payload(
    payload: Any,
    *,
    endpoint: str,
    validators: Validators,
    allowed_source: str,
    max_records: int,
) -> dict[str, Any]:
    validator = validators.events if endpoint == "events" else validators.snapshot
    if not isinstance(payload, dict) or next(validator.iter_errors(payload), None) is not None:
        raise ProtocolError("schema_validation_failed")
    if payload["schema_version"] != "1.0":
        raise ProtocolError("unsupported_schema_version")
    if payload["source"] != allowed_source:
        raise ProtocolError("source_not_allowed", 403)
    entity = payload["entity"]
    if entity not in ENTITIES or (endpoint == "events" and entity not in EVENT_ENTITIES):
        raise ProtocolError("entity_not_allowed")
    records = payload["records"]
    if len(records) > max_records:
        raise ProtocolError("batch_too_large", 413)

    ids: list[int] = []
    for record in records:
        source_id = record["id"]
        if source_id > MAX_SOURCE_ID:
            raise ProtocolError("source_id_out_of_range")
        ids.append(source_id)
        if _contains_forbidden_field(record):
            raise ProtocolError("forbidden_authentication_field")
    if len(ids) != len(set(ids)):
        raise ProtocolError("duplicate_source_id")
    if endpoint == "events":
        if ids != sorted(ids):
            raise ProtocolError("event_records_not_ordered")
        if ids[-1] != payload["checkpoint"]:
            raise ProtocolError("checkpoint_mismatch")
    return payload


def source_timestamp(record: dict[str, Any], sent_at: str) -> dt.datetime:
    for field in SOURCE_TIME_FIELDS:
        value = record.get(field)
        if value:
            try:
                parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            except ValueError:
                continue
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.UTC)
            return parsed.astimezone(dt.UTC)
    return dt.datetime.fromisoformat(sent_at.replace("Z", "+00:00")).astimezone(dt.UTC)


def _contains_forbidden_field(value: Any) -> bool:
    if isinstance(value, dict):
        return any(key.lower() in FORBIDDEN_FIELDS or _contains_forbidden_field(item) for key, item in value.items())
    if isinstance(value, list):
        return any(_contains_forbidden_field(item) for item in value)
    return False
