import asyncio
from datetime import UTC, datetime
from pathlib import Path

import pytest
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError

from odyssey.db.base import Base
from odyssey.db.models import (
    IntegrityRunRecord,
    KillSwitch,
    KillSwitchAuditRecord,
    ProvenanceRecord,
    SourceRecord,
)
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.operations.integrity import CheckStatus, run_integrity_checks


def test_integrity_failure_is_persisted_and_freezes_compaction(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'integrity.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
            for table in ("ledger_events", "source_records", "provenance_records"):
                await connection.exec_driver_sql(
                    f"""
                    CREATE TRIGGER {table}_reject_update
                    BEFORE UPDATE ON {table}
                    BEGIN
                      SELECT RAISE(ABORT, '{table} is append-only');
                    END
                    """
                )
                await connection.exec_driver_sql(
                    f"""
                    CREATE TRIGGER {table}_reject_delete
                    BEFORE DELETE ON {table}
                    BEGIN
                      SELECT RAISE(ABORT, '{table} is append-only');
                    END
                    """
                )
            for table in (
                "kill_switch_audit",
                "integrity_runs",
                "server_changes",
                "sync_batch_receipts",
                "sync_operations",
            ):
                await connection.exec_driver_sql(
                    f"""
                    CREATE TRIGGER {table}_reject_update
                    BEFORE UPDATE ON {table}
                    BEGIN
                      SELECT RAISE(ABORT, '{table} is append-only');
                    END
                    """
                )
                await connection.exec_driver_sql(
                    f"""
                    CREATE TRIGGER {table}_reject_delete
                    BEFORE DELETE ON {table}
                    BEGIN
                      SELECT RAISE(ABORT, '{table} is append-only');
                    END
                    """
                )
        provenance_id = new_uuid7()
        source_id = new_uuid7()
        async with database.sessions() as session, session.begin():
            session.add(
                ProvenanceRecord(
                    id=provenance_id,
                    source_kind="test",
                    source_id=str(source_id),
                    actor_type="system",
                    actor_id="integrity-test",
                    recorded_at=datetime(2026, 8, 15, tzinfo=UTC),
                    transformation_chain=[],
                    content_hash="0" * 64,
                    details={},
                )
            )
            session.add(
                SourceRecord(
                    id=source_id,
                    source_kind="test",
                    occurred_at=datetime(2026, 8, 15, tzinfo=UTC),
                    recorded_at=datetime(2026, 8, 15, tzinfo=UTC),
                    temporal_precision="exact",
                    content_hash="f" * 64,
                    sensitivity="private",
                    payload={"synthetic": True},
                    provenance_id=provenance_id,
                )
            )

        report = await run_integrity_checks(database)
        assert report.healthy is False
        assert "source_hashes" in report.failure_codes
        source_check = next(check for check in report.checks if check.code == "source_hashes")
        assert source_check.status is CheckStatus.FAIL
        assert report.destructive_compaction_frozen is True

        async with database.sessions() as session:
            switch = await session.get(KillSwitch, "destructive_compaction")
            assert switch is not None and switch.enabled is True
            run_count = int(
                await session.scalar(select(func.count()).select_from(IntegrityRunRecord)) or 0
            )
            audit_count = int(
                await session.scalar(select(func.count()).select_from(KillSwitchAuditRecord)) or 0
            )
        assert run_count == 1
        assert audit_count == 1
        await database.dispose()

    asyncio.run(scenario())


def test_sqlite_runtime_enforces_foreign_keys(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'foreign-keys.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with database.sessions() as session:
            session.add(
                SourceRecord(
                    id=new_uuid7(),
                    source_kind="test",
                    occurred_at=datetime(2026, 8, 15, tzinfo=UTC),
                    recorded_at=datetime(2026, 8, 15, tzinfo=UTC),
                    temporal_precision="exact",
                    content_hash="0" * 64,
                    sensitivity="private",
                    payload={},
                    provenance_id=new_uuid7(),
                )
            )
            with pytest.raises(IntegrityError):
                await session.commit()
        await database.dispose()

    asyncio.run(scenario())
