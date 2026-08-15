from datetime import UTC, datetime

import pytest
from pydantic import ValidationError

from odyssey.domain.common import new_uuid7
from odyssey.sync.contracts import (
    SyncMutationType,
    SyncOperationInput,
    SyncPushRequest,
    format_cursor,
    parse_cursor,
)


def operation(sequence: int) -> SyncOperationInput:
    return SyncOperationInput(
        operation_id=new_uuid7(),
        device_sequence=sequence,
        entity_type="season",
        entity_id=new_uuid7(),
        mutation_type=SyncMutationType.CREATE,
        payload={"title": "Synthetic season"},
        created_at=datetime.now(UTC),
        idempotency_key=f"synthetic-{sequence}",
    )


def test_cursor_round_trip_and_rejects_noncanonical_values() -> None:
    assert parse_cursor("c_0") == 0
    assert parse_cursor(format_cursor(10_533)) == 10_533
    with pytest.raises(ValueError, match="cursor"):
        parse_cursor("c_01")
    with pytest.raises(ValueError, match="negative"):
        format_cursor(-1)


def test_push_requires_unique_ascending_device_sequences() -> None:
    with pytest.raises(ValidationError, match="ascending"):
        SyncPushRequest(
            device_id=new_uuid7(),
            client_schema_version=1,
            base_cursor="c_0",
            operations=(operation(2), operation(1)),
        )


def test_delete_is_payload_free_and_create_has_no_base_revision() -> None:
    with pytest.raises(ValidationError, match="empty payload"):
        SyncOperationInput(
            operation_id=new_uuid7(),
            device_sequence=1,
            entity_type="season",
            entity_id=new_uuid7(),
            mutation_type=SyncMutationType.DELETE,
            payload={"title": "must not survive tombstone"},
            created_at=datetime.now(UTC),
            idempotency_key="synthetic-delete",
        )
    with pytest.raises(ValidationError, match="base revision"):
        SyncOperationInput(
            operation_id=new_uuid7(),
            device_sequence=1,
            entity_type="season",
            entity_id=new_uuid7(),
            mutation_type=SyncMutationType.CREATE,
            base_revision=1,
            payload={"title": "Synthetic season"},
            created_at=datetime.now(UTC),
            idempotency_key="synthetic-create",
        )
