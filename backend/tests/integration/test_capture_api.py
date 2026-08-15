import asyncio
import json
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from odyssey.config import Environment, Settings
from odyssey.db.base import Base
from odyssey.db.models import (
    KillSwitchAuditRecord,
    LedgerEventRecord,
    OutboxRecord,
    SourceRecord,
)
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.main import create_app
from odyssey.operations.kill_switches import KillSwitchKey, KillSwitchService


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


def test_capture_is_durable_and_idempotent(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "capture.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    capture_id = new_uuid7()
    event_id = new_uuid7()
    request_body = {
        "capture_id": str(capture_id),
        "event_id": str(event_id),
        "captured_at": datetime.now(UTC).isoformat(),
        "kind": "text",
        "content_or_object_ref": "Synthetic offline-safe capture",
        "device_id": str(new_uuid7()),
        "timezone": "Europe/London",
        "invoking_surface": "integration_test",
    }

    with TestClient(app) as client:
        first = client.post(
            "/v1/captures",
            json=request_body,
            headers={"Idempotency-Key": str(event_id)},
        )
        second = client.post(
            "/v1/captures",
            json=request_body,
            headers={"Idempotency-Key": str(event_id)},
        )

    assert first.status_code == 200
    assert first.json()["created"] is True
    assert second.status_code == 200
    assert second.json()["created"] is False
    assert second.json()["ledger_sequence"] == first.json()["ledger_sequence"]

    async def counts() -> tuple[int, int, int]:
        async with database.sessions() as session:
            ledger_count = await session.scalar(select(func.count()).select_from(LedgerEventRecord))
            source_count = await session.scalar(select(func.count()).select_from(SourceRecord))
            outbox_count = await session.scalar(select(func.count()).select_from(OutboxRecord))
            return int(ledger_count or 0), int(source_count or 0), int(outbox_count or 0)

    assert asyncio.run(counts()) == (1, 1, 1)

    async def source_hash_is_valid() -> bool:
        async with database.sessions() as session:
            source = await session.get(SourceRecord, capture_id)
            assert source is not None
            canonical = json.dumps(source.payload, separators=(",", ":"), sort_keys=True).encode()
            return sha256(canonical).hexdigest() == source.content_hash

    assert asyncio.run(source_hash_is_valid()) is True


def test_capture_kill_switch_blocks_new_writes_but_not_committed_retries(
    tmp_path: Path,
) -> None:
    database = prepare_database(tmp_path / "capture-switch.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    capture_id = new_uuid7()
    event_id = new_uuid7()
    request_body = {
        "capture_id": str(capture_id),
        "event_id": str(event_id),
        "captured_at": datetime.now(UTC).isoformat(),
        "kind": "text",
        "content_or_object_ref": "Synthetic kill-switch capture",
        "device_id": str(new_uuid7()),
        "timezone": "Europe/London",
        "invoking_surface": "integration_test",
    }

    async def set_switch(enabled: bool, reason: str) -> None:
        async with database.sessions() as session, session.begin():
            await KillSwitchService().set(
                session,
                key=KillSwitchKey.CAPTURE_WRITES,
                enabled=enabled,
                reason=reason,
                changed_by="integration-test",
                change_source="test",
            )

    asyncio.run(set_switch(True, "synthetic freeze"))
    with TestClient(app) as client:
        blocked = client.post(
            "/v1/captures",
            json=request_body,
            headers={"Idempotency-Key": str(event_id)},
        )
        asyncio.run(set_switch(False, "synthetic recovery"))
        created = client.post(
            "/v1/captures",
            json=request_body,
            headers={"Idempotency-Key": str(event_id)},
        )
        asyncio.run(set_switch(True, "synthetic second freeze"))
        retry = client.post(
            "/v1/captures",
            json=request_body,
            headers={"Idempotency-Key": str(event_id)},
        )

    assert blocked.status_code == 503
    assert blocked.json()["error"]["code"] == "CAPTURE_WRITES_DISABLED"
    assert created.status_code == 200
    assert created.json()["created"] is True
    assert retry.status_code == 200
    assert retry.json()["created"] is False

    async def audit_count() -> int:
        async with database.sessions() as session:
            value = await session.scalar(select(func.count()).select_from(KillSwitchAuditRecord))
            return int(value or 0)

    assert asyncio.run(audit_count()) == 3
