from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _positive_int(name: str, default: int) -> int:
    value = int(os.getenv(name, str(default)))
    if value <= 0:
        raise ValueError(f"{name} must be greater than zero")
    return value


@dataclass(frozen=True)
class Config:
    database_url: str
    ingest_token: str
    allowed_source: str
    mimir_token: str
    loki_token: str
    mimir_tenant_id: str
    loki_tenant_id: str
    mimir_write_url: str
    loki_write_url: str
    schema_dir: Path
    migration_dir: Path
    max_compressed_bytes: int
    max_expanded_bytes: int
    max_batch_records: int
    snapshot_staging_ttl_seconds: int

    @classmethod
    def from_env(cls) -> "Config":
        required = {
            name: os.getenv(name, "")
            for name in (
                "COCKPIT_DATABASE_URL",
                "COCKPIT_INGEST_TOKEN",
                "MIMIR_BEARER_TOKEN",
                "LOKI_BEARER_TOKEN",
            )
        }
        missing = [name for name, value in required.items() if not value]
        if missing:
            raise ValueError(f"missing required environment variables: {', '.join(missing)}")
        return cls(
            database_url=required["COCKPIT_DATABASE_URL"],
            ingest_token=required["COCKPIT_INGEST_TOKEN"],
            allowed_source=os.getenv("COCKPIT_ALLOWED_SOURCE", "myrctf"),
            mimir_token=required["MIMIR_BEARER_TOKEN"],
            loki_token=required["LOKI_BEARER_TOKEN"],
            mimir_tenant_id=os.getenv("MIMIR_TENANT_ID", "myrctf-analytics"),
            loki_tenant_id=os.getenv("LOKI_TENANT_ID", "myrctf-operations"),
            mimir_write_url=os.getenv(
                "MIMIR_INTERNAL_WRITE_URL", "http://myrctf-mimir:8080/api/v1/push"
            ),
            loki_write_url=os.getenv(
                "LOKI_INTERNAL_WRITE_URL", "http://myrctf-loki:3100/loki/api/v1/push"
            ),
            schema_dir=Path(os.getenv("COCKPIT_SCHEMA_DIR", "schemas")),
            migration_dir=Path(os.getenv("COCKPIT_MIGRATION_DIR", "migrations")),
            max_compressed_bytes=_positive_int("COCKPIT_MAX_COMPRESSED_BYTES", 8 * 1024 * 1024),
            max_expanded_bytes=_positive_int("COCKPIT_MAX_EXPANDED_BYTES", 32 * 1024 * 1024),
            max_batch_records=_positive_int("COCKPIT_MAX_BATCH_RECORDS", 1000),
            snapshot_staging_ttl_seconds=_positive_int(
                "COCKPIT_SNAPSHOT_STAGING_TTL_SECONDS", 86400
            ),
        )
