import asyncio
from datetime import UTC, datetime
from hashlib import sha256
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


def test_sync_diagnostics_track_local_queue_and_pull_cursor(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "sync-diagnostics.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    device_id = new_uuid7()
    body = push_body(device_id, new_uuid7(), new_uuid7())
    attachment_content = b"pending attachment"
    attachment_body = {
        "attachment_id": str(new_uuid7()),
        "content_sha256": sha256(attachment_content).hexdigest(),
        "byte_size": len(attachment_content),
        "media_type": "text/plain",
    }
    diagnostics_body = {
        "client_schema_version": 1,
        "device_cursor": "c_0",
        "operations_queued": 2,
        "oldest_unsynced_operation_at": "2026-08-15T10:00:00Z",
        "attachment_backlog": 1,
    }

    with TestClient(app) as client:
        pushed = client.post(
            "/v1/sync/push",
            json=body,
            headers={"Idempotency-Key": "diagnostic-push"},
        )
        reported = client.put(
            f"/v1/sync/devices/{device_id}/diagnostics",
            json=diagnostics_body,
        )
        pending_attachment = client.post("/v1/attachments/uploads", json=attachment_body)
        before_pull = client.get("/v1/sync/diagnostics")
        pulled = client.get(
            "/v1/sync/changes",
            params={"cursor": "c_0"},
            headers={"X-Odyssey-Device-ID": str(device_id)},
        )
        after_pull = client.get("/v1/sync/diagnostics")

    assert pushed.status_code == 200
    assert reported.status_code == 200
    assert reported.json()["device_cursor"] == "c_0"
    assert reported.json()["server_cursor"] == "c_1"
    assert reported.json()["operations_queued"] == 2
    assert pending_attachment.status_code == 200
    assert before_pull.status_code == 200
    assert before_pull.json()["pending_attachment_uploads"] == 1
    assert before_pull.json()["pending_outbox_jobs"] == 1
    assert before_pull.json()["devices"][0]["last_successful_push_at"] is not None
    assert before_pull.json()["devices"][0]["last_successful_pull_at"] is None
    assert before_pull.json()["devices"][0]["device_cursor"] == "c_0"
    assert before_pull.json()["devices"][0]["schema_compatibility"] == "compatible"
    assert before_pull.json()["repair"]["projection_rebuild_command"] == (
        "make rebuild-projections"
    )
    assert pulled.status_code == 200
    assert after_pull.json()["devices"][0]["device_cursor"] == "c_1"
    assert after_pull.json()["devices"][0]["last_successful_pull_at"] is not None


def test_sync_diagnostics_report_schema_incompatibility_and_cursor_error(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "sync-diagnostic-schema.sqlite")
    app = create_app(
        Settings(
            env=Environment.TEST,
            minimum_client_schema_version=2,
            current_sync_schema_version=3,
        ),
        database=database,
    )
    old_device = new_uuid7()
    new_device = new_uuid7()

    with TestClient(app) as client:
        old = client.put(
            f"/v1/sync/devices/{old_device}/diagnostics",
            json={
                "client_schema_version": 1,
                "device_cursor": "c_0",
                "operations_queued": 0,
                "attachment_backlog": 0,
            },
        )
        new = client.put(
            f"/v1/sync/devices/{new_device}/diagnostics",
            json={
                "client_schema_version": 4,
                "device_cursor": "c_0",
                "operations_queued": 0,
                "attachment_backlog": 0,
            },
        )
        ahead = client.put(
            f"/v1/sync/devices/{new_uuid7()}/diagnostics",
            json={
                "client_schema_version": 3,
                "device_cursor": "c_1",
                "operations_queued": 0,
                "attachment_backlog": 0,
            },
        )

    assert old.status_code == 200
    assert old.json()["schema_compatibility"] == "client_upgrade_required"
    assert new.status_code == 200
    assert new.json()["schema_compatibility"] == "server_upgrade_required"
    assert ahead.status_code == 409
    assert ahead.json()["error"]["code"] == "SYNC_CURSOR_AHEAD"
