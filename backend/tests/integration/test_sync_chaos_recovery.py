import asyncio
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path

from fastapi.testclient import TestClient

from odyssey.config import Environment, Settings
from odyssey.db.base import Base
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.main import create_app
from odyssey.sync.contracts import SyncMutationType, SyncPullResponse, SyncPushResponse
from odyssey.sync.simulated_client import DurableSimulatedClient

NOW = datetime(2026, 8, 15, 14, 0, tzinfo=UTC)


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


@contextmanager
def server_client(path: Path) -> Iterator[TestClient]:
    database = prepare_database(path)
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        yield client


def copy_sqlite_database(source: Path, destination: Path) -> None:
    with (
        sqlite3.connect(source) as source_connection,
        sqlite3.connect(destination) as destination_connection,
    ):
        source_connection.backup(destination_connection)


def post_push(client: TestClient, batch: object) -> object:
    request = batch.request
    return client.post(
        "/v1/sync/push",
        json=request.model_dump(mode="json"),
        headers={"Idempotency-Key": batch.idempotency_key},
    )


def test_response_loss_server_rollback_and_client_reinstall_converge(tmp_path: Path) -> None:
    server_path = tmp_path / "server.sqlite"
    snapshot_path = tmp_path / "server-before-later-operation.sqlite"
    client_path = tmp_path / "surviving-client.sqlite"
    reinstalled_path = tmp_path / "reinstalled-client.sqlite"
    capture_id = new_uuid7()
    event_id = new_uuid7()
    first_operation_id = new_uuid7()
    second_operation_id = new_uuid7()
    recovery_marker_id = new_uuid7()
    source_device_id = new_uuid7()

    with DurableSimulatedClient(client_path, device_id=source_device_id) as offline_client:
        offline_client.queue_capture(
            capture_id=capture_id,
            event_id=event_id,
            operation_id=first_operation_id,
            content_or_object_ref="Recover this synthetic capture",
            timezone="Europe/London",
            invoking_surface="chaos_drill",
            captured_at=NOW,
        )
        capture_during_outage = offline_client.next_capture()
        push_during_outage = offline_client.next_push()
        assert capture_during_outage is not None
        assert push_during_outage is not None

    with DurableSimulatedClient(client_path, device_id=source_device_id) as surviving_client:
        capture_request = surviving_client.next_capture()
        first_batch = surviving_client.next_push()
        assert capture_request == capture_during_outage
        assert first_batch == push_during_outage

        with server_client(server_path) as server:
            committed_capture = server.post(
                "/v1/captures",
                json=capture_request.body,
                headers={
                    "Idempotency-Key": capture_request.idempotency_key,
                    "X-Correlation-ID": "chaos-capture-commit-response-lost",
                },
            )
            assert committed_capture.status_code == 200
            assert committed_capture.json()["created"] is True
            assert committed_capture.headers["X-Trace-ID"]

            confirmed_capture = server.post(
                "/v1/captures",
                json=capture_request.body,
                headers={
                    "Idempotency-Key": capture_request.idempotency_key,
                    "X-Correlation-ID": "chaos-capture-idempotent-retry",
                },
            )
            assert confirmed_capture.status_code == 200
            assert confirmed_capture.json()["created"] is False
            assert confirmed_capture.json()["ledger_sequence"] == 1
            surviving_client.apply_capture_response(capture_id, confirmed_capture.json())

            committed_push = post_push(server, first_batch)
            assert committed_push.status_code == 200
            replayed_push = post_push(server, first_batch)
            assert replayed_push.status_code == 200
            assert replayed_push.json() == committed_push.json()
            surviving_client.apply_push_response(
                first_batch.idempotency_key,
                SyncPushResponse.model_validate(replayed_push.json()),
            )

        assert surviving_client.cursor == "c_1"
        copy_sqlite_database(server_path, snapshot_path)

        surviving_client.queue_operation(
            entity_type="capture_recovery_marker",
            entity_id=recovery_marker_id,
            mutation_type=SyncMutationType.CREATE,
            payload={
                "capture_id": str(capture_id),
                "synthetic_revision_note": "acknowledged after the snapshot",
            },
            operation_id=second_operation_id,
            created_at=NOW + timedelta(minutes=5),
        )
        later_batch = surviving_client.next_push()
        assert later_batch is not None
        with server_client(server_path) as server:
            later_response = post_push(server, later_batch)
            assert later_response.status_code == 200
            assert later_response.json()["next_cursor"] == "c_2"
            assert len(later_response.json()["accepted"]) == 1
            surviving_client.apply_push_response(
                later_batch.idempotency_key,
                SyncPushResponse.model_validate(later_response.json()),
            )
        assert surviving_client.cursor == "c_2"
        assert surviving_client.acknowledgement_count(second_operation_id) == 1

    copy_sqlite_database(snapshot_path, server_path)

    with (
        DurableSimulatedClient(client_path, device_id=source_device_id) as surviving_client,
        server_client(server_path) as restored_server,
    ):
            diagnostics = restored_server.get("/v1/sync/diagnostics")
            assert diagnostics.status_code == 200
            assert diagnostics.json()["server_cursor"] == "c_1"

            stale_pull = restored_server.get(
                "/v1/sync/changes",
                params={"cursor": surviving_client.cursor},
                headers={"X-Odyssey-Device-ID": str(source_device_id)},
            )
            assert stale_pull.status_code == 409
            assert stale_pull.json()["error"]["code"] == "SYNC_CURSOR_AHEAD"

            plan = surviving_client.reconcile_server_restore(
                diagnostics.json()["server_cursor"],
                backup_history_verified=True,
                backup_reference="server-before-later-operation.sqlite",
                confirmed_by="integration-chaos-drill",
            )
            assert plan.requeued_operation_ids == (second_operation_id,)
            recovery_batch = surviving_client.next_push()
            assert recovery_batch is not None
            assert recovery_batch.request.base_cursor == "c_1"
            recovery_response = post_push(restored_server, recovery_batch)
            assert recovery_response.status_code == 200
            surviving_client.apply_push_response(
                recovery_batch.idempotency_key,
                SyncPushResponse.model_validate(recovery_response.json()),
            )
            assert surviving_client.cursor == "c_2"
            assert surviving_client.acknowledgement_count(second_operation_id) == 2

            with DurableSimulatedClient(reinstalled_path) as reinstalled_client:
                pulled = restored_server.get(
                    "/v1/sync/changes",
                    params={"cursor": reinstalled_client.cursor, "limit": 500},
                    headers={"X-Odyssey-Device-ID": str(reinstalled_client.device_id)},
                )
                assert pulled.status_code == 200
                reinstalled_client.apply_pull_response(
                    SyncPullResponse.model_validate(pulled.json())
                )
                recovered = reinstalled_client.entity("capture", capture_id)
                assert recovered is not None
                assert recovered.document["content_or_object_ref"] == (
                    "Recover this synthetic capture"
                )
                assert recovered.document["interpretation_status"] == "pending"
                assert recovered.canonical_revision == 1
                marker = reinstalled_client.entity(
                    "capture_recovery_marker", recovery_marker_id
                )
                assert marker is not None
                assert marker.document["capture_id"] == str(capture_id)
                assert reinstalled_client.cursor == "c_2"

    with sqlite3.connect(server_path) as connection:
        counts = {
            "source_records": int(
                connection.execute("SELECT COUNT(*) FROM source_records").fetchone()[0]
            ),
            "ledger_events": int(
                connection.execute("SELECT COUNT(*) FROM ledger_events").fetchone()[0]
            ),
            "sync_operations": int(
                connection.execute("SELECT COUNT(*) FROM sync_operations").fetchone()[0]
            ),
            "server_changes": int(
                connection.execute("SELECT COUNT(*) FROM server_changes").fetchone()[0]
            ),
            "canonical_entities": int(
                connection.execute("SELECT COUNT(*) FROM canonical_entities").fetchone()[0]
            ),
        }
    assert counts == {
        "source_records": 1,
        "ledger_events": 1,
        "sync_operations": 2,
        "server_changes": 2,
        "canonical_entities": 2,
    }
