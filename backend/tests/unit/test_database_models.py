from datetime import UTC, datetime
from uuid import uuid4

import pytest

from odyssey.db.models import (
    ImmutableLedgerMutationError,
    LedgerEventRecord,
    reject_ledger_delete,
    reject_ledger_update,
)


def ledger_record() -> LedgerEventRecord:
    now = datetime.now(UTC)
    return LedgerEventRecord(
        event_id=uuid4(),
        event_type="capture.recorded.v1",
        event_schema_version=1,
        aggregate_type="capture",
        aggregate_id=uuid4(),
        occurred_at=now,
        recorded_at=now,
        actor={"actor_type": "user", "actor_id": "owner"},
        correlation_id=uuid4(),
        payload={"capture_id": str(uuid4())},
        provenance_id=uuid4(),
    )


def test_orm_rejects_ledger_update_and_delete() -> None:
    record = ledger_record()

    with pytest.raises(ImmutableLedgerMutationError, match="append-only"):
        reject_ledger_update(None, None, record)
    with pytest.raises(ImmutableLedgerMutationError, match="append-only"):
        reject_ledger_delete(None, None, record)
