"""Transactional repositories for immutable source and event writes."""

from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.db.models import (
    LedgerEventRecord,
    OutboxRecord,
    ProvenanceRecord,
    SourceRecord,
)
from odyssey.domain.common import Provenance, new_uuid7
from odyssey.domain.events import DomainEvent


@dataclass(frozen=True, slots=True)
class SourceRecordWrite:
    id: UUID
    source_kind: str
    occurred_at: datetime
    recorded_at: datetime
    temporal_precision: str
    content_hash: str
    sensitivity: str
    payload: dict[str, Any]
    provenance_id: UUID
    external_source_id: str | None = None
    observed_at: datetime | None = None
    timezone_id: str | None = None


@dataclass(frozen=True, slots=True)
class AppendResult:
    event_id: UUID
    sequence: int
    created: bool
    source_created: bool


class SourceRecordConflictError(RuntimeError):
    pass


class ProvenanceConflictError(RuntimeError):
    pass


class LedgerRepository:
    async def append_source_record(
        self,
        session: AsyncSession,
        *,
        source: SourceRecordWrite,
        provenance: Provenance,
    ) -> bool:
        existing_provenance = await session.get(ProvenanceRecord, provenance.id)
        if existing_provenance is None:
            session.add(
                ProvenanceRecord(
                    id=provenance.id,
                    source_kind=provenance.source_kind,
                    source_id=provenance.source_id,
                    actor_type=provenance.actor.actor_type.value,
                    actor_id=provenance.actor.actor_id,
                    recorded_at=provenance.captured_at,
                    transformation_chain=list(provenance.transformation_chain),
                    content_hash=provenance.content_hash,
                    details=dict(provenance.details),
                )
            )
        elif (
            existing_provenance.source_kind != provenance.source_kind
            or existing_provenance.source_id != provenance.source_id
            or existing_provenance.content_hash != provenance.content_hash
        ):
            raise ProvenanceConflictError(
                f"provenance {provenance.id} was reused with different content"
            )

        existing_source = await session.get(SourceRecord, source.id)
        if existing_source is not None:
            if existing_source.content_hash != source.content_hash:
                raise SourceRecordConflictError(
                    f"source record {source.id} was reused with different content"
                )
            return False
        session.add(
            SourceRecord(
                id=source.id,
                source_kind=source.source_kind,
                external_source_id=source.external_source_id,
                occurred_at=source.occurred_at,
                observed_at=source.observed_at,
                recorded_at=source.recorded_at,
                timezone_id=source.timezone_id,
                temporal_precision=source.temporal_precision,
                content_hash=source.content_hash,
                sensitivity=source.sensitivity,
                payload=source.payload,
                provenance_id=source.provenance_id,
            )
        )
        await session.flush()
        return True

    async def append_source_event(
        self,
        session: AsyncSession,
        *,
        source: SourceRecordWrite,
        event: DomainEvent,
        outbox_topic: str = "domain-event",
    ) -> AppendResult:
        existing = await session.scalar(
            select(LedgerEventRecord).where(LedgerEventRecord.event_id == event.event_id)
        )
        if existing is not None:
            return AppendResult(
                event_id=existing.event_id,
                sequence=existing.sequence,
                created=False,
                source_created=False,
            )

        provenance = event.provenance
        source_created = await self.append_source_record(
            session,
            source=source,
            provenance=provenance,
        )
        ledger_record = LedgerEventRecord(
            event_id=event.event_id,
            event_type=event.event_type,
            event_schema_version=event.event_schema_version,
            aggregate_type=event.aggregate_type,
            aggregate_id=event.aggregate_id,
            occurred_at=event.occurred_at,
            recorded_at=event.recorded_at,
            actor=event.actor.model_dump(mode="json"),
            correlation_id=event.correlation_id,
            causation_id=event.causation_id,
            payload=event.payload,
            provenance_id=event.provenance.id,
        )
        session.add(ledger_record)
        await session.flush()
        session.add(
            OutboxRecord(
                id=new_uuid7(),
                topic=outbox_topic,
                aggregate_id=event.aggregate_id,
                payload={
                    "event_id": str(event.event_id),
                    "event_type": event.event_type,
                    "sequence": ledger_record.sequence,
                },
                idempotency_key=f"ledger:{event.event_id}",
                status="pending",
                attempts=0,
                available_at=event.recorded_at,
                created_at=event.recorded_at,
            )
        )
        await session.flush()
        return AppendResult(
            event_id=ledger_record.event_id,
            sequence=ledger_record.sequence,
            created=True,
            source_created=source_created,
        )
