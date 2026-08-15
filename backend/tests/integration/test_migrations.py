import sqlite3
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config

from odyssey.config import get_settings


def test_initial_migration_creates_immutable_ledger(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database_path = tmp_path / "migration-test.sqlite"
    database_url = f"sqlite+aiosqlite:///{database_path}"
    monkeypatch.setenv("ODYSSEY_DATABASE_URL", database_url)
    get_settings.cache_clear()

    configuration = Config("alembic.ini")
    command.upgrade(configuration, "head")

    connection = sqlite3.connect(database_path)
    revision = connection.execute("SELECT version_num FROM alembic_version").fetchone()
    assert revision == ("20260815_0007",)

    provenance_id = str(uuid4())
    connection.execute(
        """
        INSERT INTO provenance_records (
          id, source_kind, source_id, actor_type, actor_id,
          recorded_at, transformation_chain, details
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            provenance_id,
            "test",
            "migration-test",
            "system",
            "tests",
            "2026-08-15T00:00:00Z",
            "[]",
            "{}",
        ),
    )
    connection.execute(
        """
        INSERT INTO ledger_events (
          event_id, event_type, event_schema_version, aggregate_type, aggregate_id,
          occurred_at, recorded_at, actor, correlation_id, payload, provenance_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid4()),
            "capture.recorded.v1",
            1,
            "capture",
            str(uuid4()),
            "2026-08-15T00:00:00Z",
            "2026-08-15T00:00:00Z",
            "{}",
            str(uuid4()),
            "{}",
            provenance_id,
        ),
    )
    connection.commit()

    with pytest.raises(sqlite3.IntegrityError, match="append-only"):
        connection.execute("UPDATE ledger_events SET event_type = 'changed'")

    connection.close()
    get_settings.cache_clear()


def test_kill_switch_audit_migration_preserves_existing_operational_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database_path = tmp_path / "migration-upgrade.sqlite"
    database_url = f"sqlite+aiosqlite:///{database_path}"
    monkeypatch.setenv("ODYSSEY_DATABASE_URL", database_url)
    get_settings.cache_clear()
    configuration = Config("alembic.ini")
    command.upgrade(configuration, "20260815_0001")

    connection = sqlite3.connect(database_path)
    connection.execute(
        """
        INSERT INTO kill_switches (key, enabled, reason, updated_by)
        VALUES ('capture_writes', 1, 'synthetic migration fixture', 'tests')
        """
    )
    connection.commit()
    connection.close()

    command.upgrade(configuration, "head")
    connection = sqlite3.connect(database_path)
    assert connection.execute(
        "SELECT enabled, reason FROM kill_switches WHERE key = 'capture_writes'"
    ).fetchone() == (1, "synthetic migration fixture")
    connection.execute(
        """
        INSERT INTO kill_switch_audit (
          id, key, enabled, reason, changed_at, changed_by, change_source
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            str(uuid4()),
            "capture_writes",
            1,
            "synthetic migration fixture",
            "2026-08-15T00:00:00Z",
            "tests",
            "migration_test",
        ),
    )
    connection.commit()
    with pytest.raises(sqlite3.IntegrityError, match="append-only"):
        connection.execute("DELETE FROM kill_switch_audit")
    connection.close()
    get_settings.cache_clear()
