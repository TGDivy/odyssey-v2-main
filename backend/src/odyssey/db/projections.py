"""Deterministic projections rebuilt exclusively from immutable ledger events."""

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from hashlib import sha256
from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.db.models import LedgerEventRecord, ProjectionCheckpoint, ProjectionRecord

CURRENT_ENTITY_PROJECTION = "current_entities"
CURRENT_ENTITY_PROJECTION_VERSION = "current-entities.v1"


@dataclass(frozen=True, slots=True)
class ProjectionRebuildReport:
    projection_name: str
    projection_version: str
    event_count: int
    projection_count: int
    last_sequence: int
    checksum: str


@dataclass(frozen=True, slots=True)
class ProjectionIntegrityReport:
    healthy: bool
    ledger_event_count: int
    expected_projection_count: int
    actual_projection_count: int
    checkpoint_sequence: int
    ledger_sequence: int


class CurrentEntityProjectionRebuilder:
    async def rebuild(
        self, session: AsyncSession, *, rebuilt_at: datetime | None = None
    ) -> ProjectionRebuildReport:
        rebuild_time = rebuilt_at or datetime.now(UTC)
        events = list(
            (
                await session.scalars(
                    select(LedgerEventRecord).order_by(LedgerEventRecord.sequence.asc())
                )
            ).all()
        )
        documents: dict[str, dict[str, Any]] = {}
        sequences: dict[str, int] = {}
        for event in events:
            key = self.projection_key(event)
            previous = documents.get(key)
            documents[key] = {
                "aggregate_type": event.aggregate_type,
                "aggregate_id": str(event.aggregate_id),
                "first_event_id": previous["first_event_id"] if previous else str(event.event_id),
                "last_event_id": str(event.event_id),
                "last_event_type": event.event_type,
                "last_event_payload": event.payload,
                "first_occurred_at": (
                    previous["first_occurred_at"] if previous else event.occurred_at.isoformat()
                ),
                "last_occurred_at": event.occurred_at.isoformat(),
                "event_count": int(previous["event_count"]) + 1 if previous else 1,
                "tombstoned": event.event_type.endswith(".tombstoned.v1"),
            }
            sequences[key] = event.sequence

        await session.execute(
            delete(ProjectionRecord).where(
                ProjectionRecord.projection_name == CURRENT_ENTITY_PROJECTION
            )
        )
        await session.execute(
            delete(ProjectionCheckpoint).where(
                ProjectionCheckpoint.projection_name == CURRENT_ENTITY_PROJECTION
            )
        )
        for key in sorted(documents):
            session.add(
                ProjectionRecord(
                    projection_name=CURRENT_ENTITY_PROJECTION,
                    projection_key=key,
                    document=documents[key],
                    source_sequence=sequences[key],
                    projection_version=CURRENT_ENTITY_PROJECTION_VERSION,
                    updated_at=rebuild_time,
                )
            )
        last_sequence = events[-1].sequence if events else 0
        session.add(
            ProjectionCheckpoint(
                projection_name=CURRENT_ENTITY_PROJECTION,
                last_sequence=last_sequence,
                projection_version=CURRENT_ENTITY_PROJECTION_VERSION,
                rebuilt_at=rebuild_time,
                updated_at=rebuild_time,
            )
        )
        await session.flush()
        return ProjectionRebuildReport(
            projection_name=CURRENT_ENTITY_PROJECTION,
            projection_version=CURRENT_ENTITY_PROJECTION_VERSION,
            event_count=len(events),
            projection_count=len(documents),
            last_sequence=last_sequence,
            checksum=self.checksum(documents),
        )

    async def verify(self, session: AsyncSession) -> ProjectionIntegrityReport:
        ledger_event_count = int(
            await session.scalar(select(func.count()).select_from(LedgerEventRecord)) or 0
        )
        aggregate_pairs = (
            await session.execute(
                select(LedgerEventRecord.aggregate_type, LedgerEventRecord.aggregate_id).distinct()
            )
        ).all()
        expected_projection_count = len(aggregate_pairs)
        actual_projection_count = int(
            await session.scalar(
                select(func.count())
                .select_from(ProjectionRecord)
                .where(ProjectionRecord.projection_name == CURRENT_ENTITY_PROJECTION)
            )
            or 0
        )
        ledger_sequence = int(
            await session.scalar(select(func.max(LedgerEventRecord.sequence))) or 0
        )
        checkpoint = await session.get(ProjectionCheckpoint, CURRENT_ENTITY_PROJECTION)
        checkpoint_sequence = checkpoint.last_sequence if checkpoint else 0
        return ProjectionIntegrityReport(
            healthy=(
                expected_projection_count == actual_projection_count
                and checkpoint_sequence == ledger_sequence
            ),
            ledger_event_count=ledger_event_count,
            expected_projection_count=expected_projection_count,
            actual_projection_count=actual_projection_count,
            checkpoint_sequence=checkpoint_sequence,
            ledger_sequence=ledger_sequence,
        )

    @staticmethod
    def projection_key(event: LedgerEventRecord) -> str:
        return f"{event.aggregate_type}:{event.aggregate_id}"

    @staticmethod
    def checksum(documents: dict[str, dict[str, Any]]) -> str:
        canonical = json.dumps(documents, separators=(",", ":"), sort_keys=True).encode()
        return sha256(canonical).hexdigest()
