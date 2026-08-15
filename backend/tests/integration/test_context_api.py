import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import select

from odyssey.config import Environment, Settings
from odyssey.context.persistence import ContextSnapshotRecord
from odyssey.db.base import Base
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.main import create_app


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


def push_context_facts(client: TestClient, *, denied_sleep: bool = False) -> None:
    now = datetime.now(UTC)
    operations: list[dict[str, object]] = [
        {
            "operation_id": str(new_uuid7()),
            "device_sequence": 1,
            "entity_type": "season",
            "entity_id": str(new_uuid7()),
            "mutation_type": "create",
            "base_revision": None,
            "payload": {"status": "active", "title": "Synthetic season"},
            "created_at": now.isoformat(),
        },
        {
            "operation_id": str(new_uuid7()),
            "device_sequence": 2,
            "entity_type": "calendar_event",
            "entity_id": str(new_uuid7()),
            "mutation_type": "create",
            "base_revision": None,
            "payload": {"title": "Synthetic interview", "starts_at": now.isoformat()},
            "created_at": now.isoformat(),
        },
        {
            "operation_id": str(new_uuid7()),
            "device_sequence": 3,
            "entity_type": "health_observation",
            "entity_id": str(new_uuid7()),
            "mutation_type": "create",
            "base_revision": None,
            "payload": {"kind": "sleep", "duration_minutes": 450},
            "created_at": now.isoformat(),
        },
    ]
    if denied_sleep:
        operations.append(
            {
                "operation_id": str(new_uuid7()),
                "device_sequence": 4,
                "entity_type": "permission",
                "entity_id": str(new_uuid7()),
                "mutation_type": "create",
                "base_revision": None,
                "payload": {"domain": "sleep", "status": "denied"},
                "created_at": now.isoformat(),
            }
        )
    response = client.post(
        "/v1/sync/push",
        json={
            "device_id": str(new_uuid7()),
            "client_schema_version": 1,
            "base_cursor": "c_0",
            "operations": operations,
        },
        headers={"Idempotency-Key": f"context-seed-{denied_sleep}"},
    )
    assert response.status_code == 200


def test_context_assembly_ignores_unaccepted_season_and_persists_snapshot(
    tmp_path: Path,
) -> None:
    database = prepare_database(tmp_path / "context.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        push_context_facts(client)
        response = client.post(
            "/v1/context/assemble",
            json={
                "as_of": (datetime.now(UTC) + timedelta(seconds=1)).isoformat(),
                "horizon": "P3D",
                "purpose": "tomorrow_map",
                "requested_domains": ["season", "calendar", "sleep", "weather"],
                "client_known_freshness": {},
            },
        )

    assert response.status_code == 200
    body = response.json()
    statuses = {item["domain"]: item["status"] for item in body["snapshot"]["domains"]}
    assert statuses == {
        "season": "missing",
        "calendar": "fresh",
        "sleep": "fresh",
        "weather": "missing",
    }
    assert body["missing_domains"] == ["season", "weather"]
    assert body["denied_domains"] == []
    assert body["snapshot"]["builder_version"] == "deterministic-context-builder-1.1"
    assert len(body["snapshot"]["content_hash"]) == 64

    async def verify_persistence() -> None:
        async with database.sessions() as session:
            records = tuple((await session.scalars(select(ContextSnapshotRecord))).all())
            assert len(records) == 1
            assert records[0].document == body

    asyncio.run(verify_persistence())


def test_permission_denial_excludes_domain_facts(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "context-denied.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        push_context_facts(client, denied_sleep=True)
        response = client.post(
            "/v1/context/assemble",
            json={
                "as_of": (datetime.now(UTC) + timedelta(seconds=1)).isoformat(),
                "horizon": "PT12H",
                "purpose": "sleep_consequence",
                "requested_domains": ["sleep"],
            },
        )

    assert response.status_code == 200
    assert response.json()["denied_domains"] == ["sleep"]
    sleep = response.json()["snapshot"]["domains"][0]
    assert sleep["status"] == "denied"
    assert sleep["facts"] == []


def test_context_rejects_future_instant_and_invalid_horizon(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "context-invalid.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    request = {
        "as_of": (datetime.now(UTC) + timedelta(hours=1)).isoformat(),
        "horizon": "P3D",
        "purpose": "tomorrow_map",
        "requested_domains": ["season"],
    }
    with TestClient(app) as client:
        future = client.post("/v1/context/assemble", json=request)
        request["as_of"] = datetime.now(UTC).isoformat()
        request["horizon"] = "next week"
        invalid_horizon = client.post("/v1/context/assemble", json=request)

    assert future.status_code == 400
    assert future.json()["error"]["code"] == "CONTEXT_AS_OF_IN_FUTURE"
    assert invalid_horizon.status_code == 422
    assert invalid_horizon.json()["error"]["code"] == "REQUEST_VALIDATION_FAILED"
