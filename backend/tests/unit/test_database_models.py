from datetime import UTC, datetime
from uuid import uuid4

import pytest

from odyssey.auth.persistence import (
    AuthDeviceAuditRecord,
    ImmutableAuthAuditError,
    reject_auth_device_audit_mutation,
)
from odyssey.db.models import (
    ImmutableLedgerMutationError,
    LedgerEventRecord,
    reject_ledger_delete,
    reject_ledger_update,
)
from odyssey.life.persistence import (
    LifeModelVersionRecord,
    reject_life_model_version_delete,
    reject_life_model_version_update,
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


def test_orm_rejects_auth_device_audit_mutation() -> None:
    record = AuthDeviceAuditRecord(
        id=uuid4(),
        device_id=uuid4(),
        event_type="revoked",
        occurred_at=datetime.now(UTC),
        actor_device_id=uuid4(),
        reason_code="lost",
        details={},
    )

    with pytest.raises(ImmutableAuthAuditError, match="append-only"):
        reject_auth_device_audit_mutation(None, None, record)


def test_orm_rejects_accepted_life_model_update_and_delete() -> None:
    now = datetime.now(UTC)
    record = LifeModelVersionRecord(
        id=uuid4(),
        owner_id="owner",
        kind="charter",
        logical_id=uuid4(),
        version_number=1,
        acceptance_sequence=1,
        supersedes_version_id=None,
        status=None,
        acceptance_method="owner_authored",
        accepted_at=now,
        content_hash="a" * 64,
        document={},
        event_id=uuid4(),
        event_type="charter.revised.v1",
        ledger_sequence=1,
        created_at=now,
    )

    with pytest.raises(ImmutableLedgerMutationError, match="immutable"):
        reject_life_model_version_update(None, None, record)
    with pytest.raises(ImmutableLedgerMutationError, match="immutable"):
        reject_life_model_version_delete(None, None, record)
