from __future__ import annotations

import hashlib
import os
from pathlib import Path

import psycopg


def apply_migrations(database_url: str, migration_dir: Path) -> None:
    with psycopg.connect(database_url, autocommit=False) as connection:
        with connection.transaction():
            connection.execute("CREATE SCHEMA IF NOT EXISTS cockpit AUTHORIZATION CURRENT_USER")
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS cockpit.schema_migrations (
                    version integer PRIMARY KEY,
                    checksum text NOT NULL,
                    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
                )
                """
            )
        for path in sorted(migration_dir.glob("[0-9][0-9][0-9]_*.sql")):
            version = int(path.name.split("_", 1)[0])
            contents = path.read_text(encoding="utf-8")
            checksum = hashlib.sha256(contents.encode()).hexdigest()
            row = connection.execute(
                "SELECT checksum FROM cockpit.schema_migrations WHERE version = %s", (version,)
            ).fetchone()
            if row:
                if row[0] != checksum:
                    raise RuntimeError(f"migration {version} checksum changed")
                continue
            with connection.transaction():
                connection.execute(contents)
                connection.execute(
                    "INSERT INTO cockpit.schema_migrations (version, checksum) VALUES (%s, %s)",
                    (version, checksum),
                )


def run() -> None:
    database_url = os.environ["COCKPIT_DATABASE_URL"]
    migration_dir = Path(os.getenv("COCKPIT_MIGRATION_DIR", "/app/migrations"))
    apply_migrations(database_url, migration_dir)
