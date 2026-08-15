from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from odyssey.domain.common import new_uuid7
from odyssey.sync.contracts import (
    AcceptedOperation,
    SyncChange,
    SyncMutationType,
    SyncPullResponse,
    SyncPushResponse,
)
from odyssey.sync.simulated_client import (
    DeliveryState,
    DurableSimulatedClient,
    SimulatedClientError,
)

NOW = datetime(2026, 8, 15, 12, 0, tzinfo=UTC)


def accepted_response(
    operation_id: object,
    *,
    revision: int,
    change_id: int,
) -> SyncPushResponse:
    return SyncPushResponse(
        accepted=(
            AcceptedOperation(
                operation_id=operation_id,
                canonical_revision=revision,
                server_change_id=change_id,
                merge_result="created" if revision == 1 else "updated",
            ),
        ),
        next_cursor=f"c_{change_id}",
        server_time=NOW + timedelta(seconds=change_id),
        server_schema_version=1,
        minimum_client_schema_version=1,
    )


def test_offline_capture_and_inflight_requests_survive_restart(tmp_path: Path) -> None:
    path = tmp_path / "simulated-client.sqlite"
    device_id = new_uuid7()
    capture_id = new_uuid7()
    event_id = new_uuid7()
    operation_id = new_uuid7()
    with DurableSimulatedClient(path, device_id=device_id) as client:
        queued = client.queue_capture(
            capture_id=capture_id,
            event_id=event_id,
            operation_id=operation_id,
            content_or_object_ref="Synthetic offline capture",
            timezone="Europe/London",
            invoking_surface="unit_test",
            captured_at=NOW,
        )
        capture_request = client.next_capture()
        push_request = client.next_push()

    assert queued.device_sequence == 1
    assert capture_request is not None
    assert push_request is not None
    with DurableSimulatedClient(path, device_id=device_id) as restarted:
        replayed_capture = restarted.next_capture()
        replayed_push = restarted.next_push()
        assert replayed_capture == capture_request
        assert replayed_push == push_request
        assert restarted.operation_state(operation_id) is DeliveryState.IN_FLIGHT
        assert restarted.entity("capture", capture_id) is not None


def test_acknowledged_operation_is_retained_and_requeued_after_restore(tmp_path: Path) -> None:
    path = tmp_path / "restore-client.sqlite"
    entity_id = new_uuid7()
    first_operation = new_uuid7()
    second_operation = new_uuid7()
    with DurableSimulatedClient(path) as client:
        client.queue_operation(
            entity_type="season",
            entity_id=entity_id,
            mutation_type=SyncMutationType.CREATE,
            payload={"title": "First"},
            operation_id=first_operation,
            created_at=NOW,
        )
        first_batch = client.next_push()
        assert first_batch is not None
        client.apply_push_response(
            first_batch.idempotency_key,
            accepted_response(first_operation, revision=1, change_id=1),
        )
        client.queue_operation(
            entity_type="season",
            entity_id=entity_id,
            mutation_type=SyncMutationType.UPDATE,
            payload={"title": "Second"},
            base_revision=1,
            operation_id=second_operation,
            created_at=NOW + timedelta(minutes=1),
        )
        second_batch = client.next_push()
        assert second_batch is not None
        client.apply_push_response(
            second_batch.idempotency_key,
            accepted_response(second_operation, revision=2, change_id=2),
        )

        with pytest.raises(SimulatedClientError, match="operator confirmation"):
            client.reconcile_server_restore(
                "c_1",
                backup_history_verified=False,
                backup_reference="snapshot-before-second-operation",
                confirmed_by="chaos-test",
            )
        plan = client.reconcile_server_restore(
            "c_1",
            backup_history_verified=True,
            backup_reference="snapshot-before-second-operation",
            confirmed_by="chaos-test",
        )
        replay = client.next_push()

        assert plan.previous_cursor == "c_2"
        assert plan.restored_cursor == "c_1"
        assert plan.server_epoch == 2
        assert plan.requeued_operation_ids == (second_operation,)
        assert client.acknowledgement_count(second_operation) == 1
        assert replay is not None
        assert replay.request.base_cursor == "c_1"
        assert tuple(item.operation_id for item in replay.request.operations) == (second_operation,)

        client.apply_push_response(
            replay.idempotency_key,
            accepted_response(second_operation, revision=2, change_id=2),
        )
        assert client.operation_state(second_operation) is DeliveryState.ACKNOWLEDGED
        assert client.acknowledgement_count(second_operation) == 2


def test_fresh_client_rebuilds_capture_from_pull_stream(tmp_path: Path) -> None:
    source_device = new_uuid7()
    capture_id = new_uuid7()
    operation_id = new_uuid7()
    payload = {
        "capture_id": str(capture_id),
        "kind": "text",
        "content_or_object_ref": "Recovered after reinstall",
        "interpretation_status": "pending",
    }
    response = SyncPullResponse(
        changes=(
            SyncChange(
                change_id=1,
                canonical_revision=1,
                entity_type="capture",
                entity_id=capture_id,
                mutation_type=SyncMutationType.CREATE,
                payload=payload,
                tombstone=False,
                merge_result="created",
                origin_device_id=source_device,
                origin_operation_id=operation_id,
                server_received_at=NOW,
            ),
        ),
        next_cursor="c_1",
        has_more=False,
        server_time=NOW,
        server_schema_version=1,
        minimum_client_schema_version=1,
    )
    with DurableSimulatedClient(tmp_path / "reinstalled.sqlite") as client:
        client.apply_pull_response(response)
        entity = client.entity("capture", capture_id)

        assert client.cursor == "c_1"
        assert entity is not None
        assert entity.document["content_or_object_ref"] == "Recovered after reinstall"
        assert entity.canonical_revision == 1
        assert entity.last_change_id == 1


def test_client_rejects_ambiguous_responses_and_invalid_time(tmp_path: Path) -> None:
    with DurableSimulatedClient(tmp_path / "invalid.sqlite") as client:
        with pytest.raises(ValueError, match="timezone"):
            client.queue_operation(
                entity_type="season",
                entity_id=new_uuid7(),
                mutation_type=SyncMutationType.CREATE,
                payload={},
                created_at=datetime(2026, 8, 15),
            )
        with pytest.raises(SimulatedClientError, match="unknown batch"):
            client.apply_push_response(
                "missing",
                SyncPushResponse(
                    next_cursor="c_0",
                    server_time=NOW,
                    server_schema_version=1,
                    minimum_client_schema_version=1,
                ),
            )
