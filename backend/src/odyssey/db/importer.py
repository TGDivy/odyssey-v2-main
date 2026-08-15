"""Idempotent import of source-linked Odyssey domain-event fixtures."""

import asyncio
import json
from dataclasses import asdict, dataclass
from datetime import datetime
from hashlib import sha256
from pathlib import Path
from time import monotonic
from typing import Any
from uuid import UUID

from odyssey.db.projections import CurrentEntityProjectionRebuilder, ProjectionRebuildReport
from odyssey.db.repositories import LedgerRepository, SourceRecordWrite
from odyssey.db.session import Database
from odyssey.domain.common import ActorRef, ActorType, Provenance
from odyssey.domain.events import DomainEvent


@dataclass(frozen=True, slots=True)
class ImportReport:
    event_count: int
    created_count: int
    duplicate_count: int
    source_record_count: int
    source_created_count: int
    source_duplicate_count: int
    available_source_record_count: int
    elapsed_seconds: float
    projection: ProjectionRebuildReport | None

    def as_json(self) -> dict[str, Any]:
        return asdict(self)


def load_json_lines(path: Path, *, limit: int | None = None) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if limit is not None and len(values) >= limit:
                break
            values.append(json.loads(line))
    return values


def parse_instant(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def deterministic_uuid7(occurred_at: datetime, entropy: bytes) -> UUID:
    timestamp_ms = int(occurred_at.timestamp() * 1_000) & ((1 << 48) - 1)
    digest = sha256(entropy).digest()
    random_a = int.from_bytes(digest[:2]) & ((1 << 12) - 1)
    random_b = int.from_bytes(digest[2:10]) & ((1 << 62) - 1)
    value = timestamp_ms << 80
    value |= 0x7 << 76
    value |= random_a << 64
    value |= 0b10 << 62
    value |= random_b
    return UUID(int=value)


def source_provenance(record: dict[str, Any]) -> Provenance:
    canonical = json.dumps(record, separators=(",", ":"), sort_keys=True).encode()
    occurred_at = parse_instant(record["occurred_at"])
    return Provenance(
        id=deterministic_uuid7(occurred_at, b"synthetic-source-registration.v1\0" + canonical),
        source_kind="synthetic_fixture",
        source_id=record["id"],
        captured_at=occurred_at,
        actor=ActorRef(actor_type=ActorType.SYSTEM, actor_id="synthetic-fixture-importer"),
        transformation_chain=("synthetic-source-registration.v1",),
        content_hash=sha256(canonical).hexdigest(),
        details={
            "contains_real_personal_data": False,
            "registration_only": True,
        },
    )


def source_write(
    record: dict[str, Any],
    *,
    provenance_id: UUID,
    recorded_at: datetime,
) -> SourceRecordWrite:
    canonical = json.dumps(record, separators=(",", ":"), sort_keys=True).encode()
    data = record["data"]
    timezone_id = data.get("timezone") or data.get("to_timezone")
    occurred_at = parse_instant(record["occurred_at"])
    return SourceRecordWrite(
        id=UUID(record["id"]),
        source_kind=record["record_type"],
        occurred_at=occurred_at,
        observed_at=occurred_at,
        recorded_at=recorded_at,
        timezone_id=timezone_id,
        temporal_precision="exact",
        content_hash=sha256(canonical).hexdigest(),
        sensitivity="private",
        payload=record,
        provenance_id=provenance_id,
    )


async def import_fixture(
    database: Database,
    *,
    ledger_path: Path,
    source_records_path: Path,
    batch_size: int = 250,
    limit: int | None = None,
    rebuild_projections: bool = True,
) -> ImportReport:
    started_at = monotonic()
    event_documents, source_documents = await asyncio.gather(
        asyncio.to_thread(load_json_lines, ledger_path, limit=limit),
        asyncio.to_thread(load_json_lines, source_records_path),
    )
    sources = {document["id"]: document for document in source_documents}
    repository = LedgerRepository()
    created_count = 0
    duplicate_count = 0
    source_created_count = 0
    source_duplicate_count = 0
    processed_source_ids: set[str] = set()

    for offset in range(0, len(event_documents), batch_size):
        batch = event_documents[offset : offset + batch_size]
        async with database.sessions() as session, session.begin():
            for document in batch:
                event = DomainEvent.model_validate(document)
                source_document = sources.get(event.provenance.source_id)
                if source_document is None:
                    missing_source = event.provenance.source_id
                    raise ValueError(
                        f"event {event.event_id} references missing source {missing_source}"
                    )
                result = await repository.append_source_event(
                    session,
                    source=source_write(
                        source_document,
                        provenance_id=event.provenance.id,
                        recorded_at=event.recorded_at,
                    ),
                    event=event,
                    outbox_topic="imported-domain-event",
                )
                if result.created:
                    created_count += 1
                else:
                    duplicate_count += 1
                if event.provenance.source_id not in processed_source_ids:
                    if result.source_created:
                        source_created_count += 1
                    else:
                        source_duplicate_count += 1
                    processed_source_ids.add(event.provenance.source_id)

    if limit is None:
        unlinked_sources = [
            document
            for source_id, document in sources.items()
            if source_id not in processed_source_ids
        ]
        for offset in range(0, len(unlinked_sources), batch_size):
            batch = unlinked_sources[offset : offset + batch_size]
            async with database.sessions() as session, session.begin():
                for document in batch:
                    provenance = source_provenance(document)
                    created = await repository.append_source_record(
                        session,
                        source=source_write(
                            document,
                            provenance_id=provenance.id,
                            recorded_at=provenance.captured_at,
                        ),
                        provenance=provenance,
                    )
                    if created:
                        source_created_count += 1
                    else:
                        source_duplicate_count += 1
                    processed_source_ids.add(document["id"])

    projection_report: ProjectionRebuildReport | None = None
    if rebuild_projections:
        async with database.sessions() as session, session.begin():
            projection_report = await CurrentEntityProjectionRebuilder().rebuild(session)
    return ImportReport(
        event_count=len(event_documents),
        created_count=created_count,
        duplicate_count=duplicate_count,
        source_record_count=len(processed_source_ids),
        source_created_count=source_created_count,
        source_duplicate_count=source_duplicate_count,
        available_source_record_count=len(sources),
        elapsed_seconds=round(monotonic() - started_at, 6),
        projection=projection_report,
    )
