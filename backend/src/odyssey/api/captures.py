"""Durable capture API that never depends on a model provider."""

import json
from datetime import UTC, datetime
from hashlib import sha256
from typing import Annotated
from uuid import NAMESPACE_URL, UUID, uuid5

from fastapi import APIRouter, Header, Request
from pydantic import AwareDatetime, Field
from sqlalchemy import select

from odyssey.api.dependencies import SessionDependency
from odyssey.api.errors import OdysseyError
from odyssey.db.models import LedgerEventRecord
from odyssey.db.repositories import LedgerRepository, SourceRecordWrite
from odyssey.domain.capture import CapturePayloadKind
from odyssey.domain.common import (
    UUID7,
    ActorRef,
    ActorType,
    DataClass,
    Provenance,
    StrictModel,
    new_uuid7,
)
from odyssey.domain.events import DomainEvent
from odyssey.operations.kill_switches import KillSwitchKey, KillSwitchService

router = APIRouter(prefix="/v1/captures", tags=["captures"])
repository = LedgerRepository()
kill_switches = KillSwitchService()


class CaptureCreateRequest(StrictModel):
    capture_id: UUID7
    event_id: UUID7
    captured_at: AwareDatetime
    kind: CapturePayloadKind
    content_or_object_ref: str = Field(min_length=1, max_length=100_000)
    device_id: UUID7
    timezone: str
    broad_location: str | None = None
    invoking_surface: str
    sensitivity: DataClass = DataClass.PRIVATE


class CaptureCreateResponse(StrictModel):
    capture_id: UUID7
    event_id: UUID7
    ledger_sequence: int
    created: bool
    interpretation_status: str = "pending"


def correlation_uuid(value: str) -> UUID:
    try:
        return UUID(value)
    except ValueError:
        return uuid5(NAMESPACE_URL, value)


@router.post("", response_model=CaptureCreateResponse)
async def create_capture(
    body: CaptureCreateRequest,
    request: Request,
    session: SessionDependency,
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1)],
) -> CaptureCreateResponse:
    recorded_at = datetime.now(UTC)
    source_payload = {
        "kind": body.kind.value,
        "content_or_object_ref": body.content_or_object_ref,
        "initial_context": {
            "device_id": str(body.device_id),
            "timezone": body.timezone,
            "broad_location": body.broad_location,
            "invoking_surface": body.invoking_surface,
        },
        "interpretation_status": "pending",
    }
    canonical_source = json.dumps(source_payload, separators=(",", ":"), sort_keys=True).encode()
    content_hash = sha256(canonical_source).hexdigest()
    provenance = Provenance(
        id=new_uuid7(),
        source_kind="user_capture",
        source_id=str(body.capture_id),
        captured_at=body.captured_at,
        actor=ActorRef(actor_type=ActorType.USER, actor_id="owner"),
        transformation_chain=("capture-api.v1",),
        content_hash=content_hash,
        details={
            "device_id": str(body.device_id),
            "idempotency_key_hash": sha256(idempotency_key.encode()).hexdigest(),
        },
    )
    event = DomainEvent(
        event_id=body.event_id,
        event_type="capture.recorded.v1",
        event_schema_version=1,
        aggregate_type="capture",
        aggregate_id=body.capture_id,
        occurred_at=body.captured_at,
        recorded_at=recorded_at,
        actor=provenance.actor,
        correlation_id=correlation_uuid(request.state.correlation_id),
        payload={"capture_id": str(body.capture_id)},
        provenance=provenance,
    )
    source = SourceRecordWrite(
        id=body.capture_id,
        source_kind="capture",
        occurred_at=body.captured_at,
        recorded_at=recorded_at,
        temporal_precision="exact",
        content_hash=content_hash,
        sensitivity=body.sensitivity.value,
        payload=source_payload,
        provenance_id=provenance.id,
        timezone_id=body.timezone,
    )
    async with session.begin():
        existing_event = await session.scalar(
            select(LedgerEventRecord.sequence).where(LedgerEventRecord.event_id == body.event_id)
        )
        if existing_event is None and await kill_switches.is_enabled(
            session, KillSwitchKey.CAPTURE_WRITES
        ):
            raise OdysseyError(
                code="CAPTURE_WRITES_DISABLED",
                message="New capture writes are temporarily disabled by an operational control.",
                status_code=503,
                retryable=True,
                details={"capability": KillSwitchKey.CAPTURE_WRITES.value},
            )
        result = await repository.append_source_event(session, source=source, event=event)
    return CaptureCreateResponse(
        capture_id=body.capture_id,
        event_id=body.event_id,
        ledger_sequence=result.sequence,
        created=result.created,
    )
