import asyncio
from datetime import UTC, datetime
from pathlib import Path

from fastapi.testclient import TestClient

from odyssey.config import AuthMode, Environment, Settings
from odyssey.db.base import Base
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


def push_body(device_id: object, operation_id: object, entity_id: object) -> dict[str, object]:
    return {
        "device_id": str(device_id),
        "client_schema_version": 1,
        "base_cursor": "c_0",
        "operations": [
            {
                "operation_id": str(operation_id),
                "device_sequence": 1,
                "entity_type": "observation",
                "entity_id": str(entity_id),
                "mutation_type": "create",
                "base_revision": None,
                "payload": {"value": 7.5},
                "created_at": datetime.now(UTC).isoformat(),
            }
        ],
    }


def test_sync_push_replay_and_pull_contract(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "sync-api.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    device_id = new_uuid7()
    body = push_body(device_id, new_uuid7(), new_uuid7())
    with TestClient(app) as client:
        created = client.post(
            "/v1/sync/push",
            json=body,
            headers={"Idempotency-Key": "synthetic-batch"},
        )
        replay = client.post(
            "/v1/sync/push",
            json=body,
            headers={"Idempotency-Key": "synthetic-batch"},
        )
        pulled = client.get(
            "/v1/sync/changes",
            params={"cursor": "c_0", "limit": 50},
            headers={"X-Odyssey-Device-ID": str(device_id)},
        )

    assert created.status_code == 200
    assert replay.json() == created.json()
    assert created.json()["next_cursor"] == "c_1"
    assert created.json()["server_schema_version"] == 1
    assert pulled.status_code == 200
    assert pulled.json()["next_cursor"] == "c_1"
    assert pulled.json()["server_schema_version"] == 1
    assert (
        pulled.json()["changes"][0]["origin_operation_id"] == body["operations"][0]["operation_id"]
    )


def test_sync_push_freeze_allows_committed_batch_replay(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "sync-freeze.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    body = push_body(new_uuid7(), new_uuid7(), new_uuid7())

    async def freeze() -> None:
        async with database.sessions() as session, session.begin():
            await KillSwitchService().set(
                session,
                key=KillSwitchKey.SYNC_PUSH,
                enabled=True,
                reason="synthetic sync freeze",
                changed_by="integration-test",
                change_source="test",
            )

    with TestClient(app) as client:
        created = client.post(
            "/v1/sync/push",
            json=body,
            headers={"Idempotency-Key": "committed-before-freeze"},
        )
        asyncio.run(freeze())
        replay = client.post(
            "/v1/sync/push",
            json=body,
            headers={"Idempotency-Key": "committed-before-freeze"},
        )
        blocked = client.post(
            "/v1/sync/push",
            json=push_body(new_uuid7(), new_uuid7(), new_uuid7()),
            headers={"Idempotency-Key": "new-during-freeze"},
        )

    assert created.status_code == 200
    assert replay.status_code == 200
    assert replay.json() == created.json()
    assert blocked.status_code == 503
    assert blocked.json()["error"]["code"] == "SYNC_PUSH_DISABLED"


def test_sync_rejects_batch_key_reuse_and_unconfigured_production_auth(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "sync-errors.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    device_id = new_uuid7()
    first_body = push_body(device_id, new_uuid7(), new_uuid7())
    second_body = push_body(device_id, new_uuid7(), new_uuid7())
    second_body["operations"][0]["device_sequence"] = 2
    second_body["base_cursor"] = "c_1"
    with TestClient(app) as client:
        first = client.post(
            "/v1/sync/push",
            json=first_body,
            headers={"Idempotency-Key": "reused-key"},
        )
        conflict = client.post(
            "/v1/sync/push",
            json=second_body,
            headers={"Idempotency-Key": "reused-key"},
        )
    assert first.status_code == 200
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "SYNC_BATCH_IDEMPOTENCY_REUSED"

    production_app = create_app(
        Settings(env=Environment.TEST, auth_mode=AuthMode.SIGN_IN_WITH_APPLE),
        database=database,
    )
    with TestClient(production_app) as client:
        unavailable = client.get("/v1/sync/changes")
    assert unavailable.status_code == 503
    assert unavailable.json()["error"]["code"] == "AUTH_VERIFIER_NOT_CONFIGURED"


def test_sync_uses_application_schema_window(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "sync-schema-window.sqlite")
    settings = Settings(
        env=Environment.TEST,
        minimum_client_schema_version=2,
        current_sync_schema_version=3,
    )
    app = create_app(settings, database=database)
    body = push_body(new_uuid7(), new_uuid7(), new_uuid7())

    with TestClient(app) as client:
        response = client.post(
            "/v1/sync/push",
            json=body,
            headers={"Idempotency-Key": "unsupported-client-schema"},
        )

    assert response.status_code == 426
    assert response.json()["error"]["code"] == "SYNC_CLIENT_SCHEMA_TOO_OLD"
    assert response.json()["error"]["details"] == {"minimum_client_schema_version": 2}
