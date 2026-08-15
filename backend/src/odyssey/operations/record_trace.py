"""Payload-free relational trace from source ingestion through device sync."""

import json
import re
from datetime import UTC, datetime
from hashlib import sha256
from typing import Any
from uuid import NAMESPACE_URL, UUID, uuid5

from pydantic import AwareDatetime, Field, model_validator
from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.db.models import (
    LedgerEventRecord,
    OutboxRecord,
    ProjectionCheckpoint,
    ProjectionRecord,
    ProvenanceRecord,
    SourceRecord,
)
from odyssey.domain.common import StrictModel
from odyssey.sync.models import (
    CanonicalEntityRecord,
    ServerChangeRecord,
    SyncOperationRecord,
)

TRACE_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
SPAN_ID_PATTERN = re.compile(r"^[0-9a-f]{16}$")


class RecordTraceNotFoundError(RuntimeError):
    """Raised when the selected durable record does not exist."""


class HttpTraceReference(StrictModel):
    phase: str = Field(min_length=1, max_length=100, pattern=r"^[A-Za-z0-9_.-]+$")
    correlation_id: str = Field(min_length=1, max_length=200)
    trace_id: str
    span_id: str

    @model_validator(mode="after")
    def validate_w3c_identifiers(self) -> "HttpTraceReference":
        if not TRACE_ID_PATTERN.fullmatch(self.trace_id):
            raise ValueError("trace_id must be 32 lowercase hexadecimal characters")
        if not SPAN_ID_PATTERN.fullmatch(self.span_id):
            raise ValueError("span_id must be 16 lowercase hexadecimal characters")
        return self


class RecordTraceQuery(StrictModel):
    source_record_id: UUID | None = None
    event_id: UUID | None = None
    aggregate_id: UUID | None = None
    correlation_id: UUID | None = None
    ledger_sequence: int | None = Field(default=None, ge=1)
    http_traces: tuple[HttpTraceReference, ...] = ()

    @model_validator(mode="after")
    def require_one_selector(self) -> "RecordTraceQuery":
        selectors = (
            self.source_record_id,
            self.event_id,
            self.aggregate_id,
            self.correlation_id,
            self.ledger_sequence,
        )
        if sum(value is not None for value in selectors) != 1:
            raise ValueError("exactly one record trace selector is required")
        phases = [trace.phase for trace in self.http_traces]
        if len(phases) != len(set(phases)):
            raise ValueError("HTTP trace phases must be unique")
        return self

    def selector(self) -> tuple[str, str]:
        for name in (
            "source_record_id",
            "event_id",
            "aggregate_id",
            "correlation_id",
            "ledger_sequence",
        ):
            value = getattr(self, name)
            if value is not None:
                return name, str(value)
        raise RuntimeError("validated trace query has no selector")


class SourceRecordTrace(StrictModel):
    id: UUID
    source_kind: str
    occurred_at: AwareDatetime
    recorded_at: AwareDatetime
    content_hash: str
    content_hash_valid: bool
    sensitivity: str
    provenance_id: UUID


class ProvenanceTrace(StrictModel):
    id: UUID
    source_kind: str
    source_id_hash: str
    actor_type: str
    actor_id_hash: str
    device_id: UUID | None
    recorded_at: AwareDatetime
    transformation_chain: tuple[str, ...]
    content_hash: str | None


class LedgerEventTrace(StrictModel):
    sequence: int
    event_id: UUID
    event_type: str
    event_schema_version: int
    aggregate_type: str
    aggregate_id: UUID
    occurred_at: AwareDatetime
    recorded_at: AwareDatetime
    correlation_id: UUID
    causation_id: UUID | None
    provenance_id: UUID


class OutboxTrace(StrictModel):
    id: UUID
    topic: str
    aggregate_id: UUID
    idempotency_key: str
    status: str
    attempts: int
    available_at: AwareDatetime
    created_at: AwareDatetime
    completed_at: AwareDatetime | None
    last_error_code: str | None


class ProjectionTrace(StrictModel):
    projection_name: str
    projection_key: str
    source_sequence: int
    projection_version: str
    updated_at: AwareDatetime


class ProjectionCheckpointTrace(StrictModel):
    projection_name: str
    last_sequence: int
    projection_version: str
    rebuilt_at: AwareDatetime | None
    updated_at: AwareDatetime


class SyncOperationTrace(StrictModel):
    operation_id: UUID
    device_id: UUID
    device_sequence: int
    entity_type: str
    entity_id: UUID
    mutation_type: str
    base_revision: int | None
    created_at: AwareDatetime
    received_at: AwareDatetime
    sensitivity_class: str
    request_hash: str
    status: str
    canonical_revision: int | None
    server_change_id: int | None
    conflict_id: UUID | None


class ServerChangeTrace(StrictModel):
    change_id: int
    entity_type: str
    entity_id: UUID
    canonical_revision: int
    mutation_type: str
    content_hash: str
    content_hash_valid: bool
    tombstone: bool
    deletion_epoch: int | None
    merge_result: str
    origin_operation_id: UUID
    origin_device_id: UUID
    received_at: AwareDatetime


class CanonicalEntityTrace(StrictModel):
    entity_type: str
    entity_id: UUID
    canonical_revision: int
    content_hash: str
    content_hash_valid: bool
    tombstoned: bool
    deletion_epoch: int | None
    updated_at: AwareDatetime
    last_operation_id: UUID
    last_device_id: UUID


class TraceLink(StrictModel):
    code: str
    linked: bool
    evidence: tuple[str, ...] = ()


class RecordTraceReport(StrictModel):
    generated_at: AwareDatetime
    selector_type: str
    selector_value: str
    payload_fields_omitted: tuple[str, ...]
    source_records: tuple[SourceRecordTrace, ...]
    provenance_records: tuple[ProvenanceTrace, ...]
    ledger_events: tuple[LedgerEventTrace, ...]
    outbox_records: tuple[OutboxTrace, ...]
    projections: tuple[ProjectionTrace, ...]
    projection_checkpoints: tuple[ProjectionCheckpointTrace, ...]
    sync_operations: tuple[SyncOperationTrace, ...]
    server_changes: tuple[ServerChangeTrace, ...]
    canonical_entities: tuple[CanonicalEntityTrace, ...]
    http_traces: tuple[HttpTraceReference, ...]
    links: tuple[TraceLink, ...]
    complete: bool
    missing_links: tuple[str, ...]


class RecordTraceEnvelope(StrictModel):
    report_sha256: str = Field(min_length=64, max_length=64)
    report: RecordTraceReport


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def _canonical_hash(value: dict[str, Any]) -> str:
    encoded = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
    return sha256(encoded).hexdigest()


def _normalized_correlation_id(value: str) -> UUID:
    try:
        return UUID(value)
    except ValueError:
        return uuid5(NAMESPACE_URL, value)


def _pair_predicate(
    model_type: Any,
    model_id: Any,
    pairs: set[tuple[str, UUID]],
) -> Any:
    return or_(
        *(
            and_(model_type == entity_type, model_id == entity_id)
            for entity_type, entity_id in pairs
        )
    )


class RecordTraceService:
    async def trace(
        self,
        session: AsyncSession,
        query: RecordTraceQuery,
        *,
        generated_at: datetime | None = None,
    ) -> RecordTraceEnvelope:
        selected_sources, events = await self._resolve_selector(session, query)
        sources = await self._load_sources(session, selected_sources, events)
        provenance = await self._load_provenance(session, sources, events)
        aggregate_pairs = {(event.aggregate_type, event.aggregate_id) for event in events}
        operations = await self._load_operations(session, aggregate_pairs)
        operation_ids = {operation.operation_id for operation in operations}
        changes = await self._load_changes(session, aggregate_pairs, operation_ids)
        canonical_pairs = aggregate_pairs | {
            (operation.entity_type, operation.entity_id) for operation in operations
        }
        canonical = await self._load_canonical(session, canonical_pairs)
        projections = await self._load_projections(session, aggregate_pairs)
        checkpoints = await self._load_checkpoints(session, projections)
        outbox = await self._load_outbox(session, events, changes)
        links = self._links(
            sources=sources,
            provenance=provenance,
            events=events,
            outbox=outbox,
            projections=projections,
            checkpoints=checkpoints,
            operations=operations,
            changes=changes,
            canonical=canonical,
            http_traces=query.http_traces,
        )
        selector_type, selector_value = query.selector()
        missing_links = tuple(link.code for link in links if not link.linked)
        report = RecordTraceReport(
            generated_at=_aware(generated_at or datetime.now(UTC)),
            selector_type=selector_type,
            selector_value=selector_value,
            payload_fields_omitted=(
                "source_records.payload",
                "ledger_events.payload",
                "outbox_records.payload",
                "projection_records.document",
                "sync_operations.payload",
                "server_changes.payload",
                "canonical_entities.document",
                "provenance_records.details",
            ),
            source_records=tuple(self._source_contract(record) for record in sources),
            provenance_records=tuple(self._provenance_contract(record) for record in provenance),
            ledger_events=tuple(self._event_contract(record) for record in events),
            outbox_records=tuple(self._outbox_contract(record) for record in outbox),
            projections=tuple(self._projection_contract(record) for record in projections),
            projection_checkpoints=tuple(
                self._checkpoint_contract(record) for record in checkpoints
            ),
            sync_operations=tuple(self._operation_contract(record) for record in operations),
            server_changes=tuple(self._change_contract(record) for record in changes),
            canonical_entities=tuple(self._canonical_contract(record) for record in canonical),
            http_traces=query.http_traces,
            links=links,
            complete=not missing_links,
            missing_links=missing_links,
        )
        canonical_report = json.dumps(
            report.model_dump(mode="json"), separators=(",", ":"), sort_keys=True
        ).encode()
        return RecordTraceEnvelope(
            report_sha256=sha256(canonical_report).hexdigest(),
            report=report,
        )

    async def _resolve_selector(
        self,
        session: AsyncSession,
        query: RecordTraceQuery,
    ) -> tuple[tuple[SourceRecord, ...], tuple[LedgerEventRecord, ...]]:
        selected_sources: tuple[SourceRecord, ...] = ()
        event_statement = select(LedgerEventRecord)
        if query.source_record_id is not None:
            source = await session.get(SourceRecord, query.source_record_id)
            if source is None:
                raise RecordTraceNotFoundError("source record does not exist")
            selected_sources = (source,)
            event_statement = event_statement.where(
                or_(
                    LedgerEventRecord.aggregate_id == source.id,
                    LedgerEventRecord.provenance_id == source.provenance_id,
                )
            )
        elif query.event_id is not None:
            event_statement = event_statement.where(LedgerEventRecord.event_id == query.event_id)
        elif query.aggregate_id is not None:
            event_statement = event_statement.where(
                LedgerEventRecord.aggregate_id == query.aggregate_id
            )
        elif query.correlation_id is not None:
            event_statement = event_statement.where(
                LedgerEventRecord.correlation_id == query.correlation_id
            )
        else:
            event_statement = event_statement.where(
                LedgerEventRecord.sequence == query.ledger_sequence
            )
        events = tuple(
            (
                await session.scalars(event_statement.order_by(LedgerEventRecord.sequence.asc()))
            ).all()
        )
        if not events and not selected_sources:
            raise RecordTraceNotFoundError("selected ledger record does not exist")
        return selected_sources, events

    async def _load_sources(
        self,
        session: AsyncSession,
        selected: tuple[SourceRecord, ...],
        events: tuple[LedgerEventRecord, ...],
    ) -> tuple[SourceRecord, ...]:
        if selected:
            return selected
        aggregate_ids = {event.aggregate_id for event in events}
        provenance_ids = {event.provenance_id for event in events}
        return tuple(
            (
                await session.scalars(
                    select(SourceRecord)
                    .where(
                        or_(
                            SourceRecord.id.in_(aggregate_ids),
                            SourceRecord.provenance_id.in_(provenance_ids),
                        )
                    )
                    .order_by(SourceRecord.recorded_at, SourceRecord.id)
                )
            ).all()
        )

    async def _load_provenance(
        self,
        session: AsyncSession,
        sources: tuple[SourceRecord, ...],
        events: tuple[LedgerEventRecord, ...],
    ) -> tuple[ProvenanceRecord, ...]:
        provenance_ids = {source.provenance_id for source in sources} | {
            event.provenance_id for event in events
        }
        if not provenance_ids:
            return ()
        return tuple(
            (
                await session.scalars(
                    select(ProvenanceRecord)
                    .where(ProvenanceRecord.id.in_(provenance_ids))
                    .order_by(ProvenanceRecord.recorded_at, ProvenanceRecord.id)
                )
            ).all()
        )

    async def _load_operations(
        self,
        session: AsyncSession,
        pairs: set[tuple[str, UUID]],
    ) -> tuple[SyncOperationRecord, ...]:
        if not pairs:
            return ()
        return tuple(
            (
                await session.scalars(
                    select(SyncOperationRecord)
                    .where(
                        _pair_predicate(
                            SyncOperationRecord.entity_type,
                            SyncOperationRecord.entity_id,
                            pairs,
                        )
                    )
                    .order_by(
                        SyncOperationRecord.received_at,
                        SyncOperationRecord.device_id,
                        SyncOperationRecord.device_sequence,
                    )
                )
            ).all()
        )

    async def _load_changes(
        self,
        session: AsyncSession,
        pairs: set[tuple[str, UUID]],
        operation_ids: set[UUID],
    ) -> tuple[ServerChangeRecord, ...]:
        predicates: list[Any] = []
        if pairs:
            predicates.append(
                _pair_predicate(
                    ServerChangeRecord.entity_type,
                    ServerChangeRecord.entity_id,
                    pairs,
                )
            )
        if operation_ids:
            predicates.append(ServerChangeRecord.origin_operation_id.in_(operation_ids))
        if not predicates:
            return ()
        return tuple(
            (
                await session.scalars(
                    select(ServerChangeRecord)
                    .where(or_(*predicates))
                    .order_by(ServerChangeRecord.change_id)
                )
            ).all()
        )

    async def _load_canonical(
        self,
        session: AsyncSession,
        pairs: set[tuple[str, UUID]],
    ) -> tuple[CanonicalEntityRecord, ...]:
        if not pairs:
            return ()
        return tuple(
            (
                await session.scalars(
                    select(CanonicalEntityRecord)
                    .where(
                        _pair_predicate(
                            CanonicalEntityRecord.entity_type,
                            CanonicalEntityRecord.entity_id,
                            pairs,
                        )
                    )
                    .order_by(
                        CanonicalEntityRecord.entity_type,
                        CanonicalEntityRecord.entity_id,
                    )
                )
            ).all()
        )

    async def _load_projections(
        self,
        session: AsyncSession,
        pairs: set[tuple[str, UUID]],
    ) -> tuple[ProjectionRecord, ...]:
        keys = {f"{entity_type}:{entity_id}" for entity_type, entity_id in pairs}
        if not keys:
            return ()
        return tuple(
            (
                await session.scalars(
                    select(ProjectionRecord)
                    .where(ProjectionRecord.projection_key.in_(keys))
                    .order_by(ProjectionRecord.projection_name, ProjectionRecord.projection_key)
                )
            ).all()
        )

    async def _load_checkpoints(
        self,
        session: AsyncSession,
        projections: tuple[ProjectionRecord, ...],
    ) -> tuple[ProjectionCheckpoint, ...]:
        names = {projection.projection_name for projection in projections}
        if not names:
            return ()
        return tuple(
            (
                await session.scalars(
                    select(ProjectionCheckpoint)
                    .where(ProjectionCheckpoint.projection_name.in_(names))
                    .order_by(ProjectionCheckpoint.projection_name)
                )
            ).all()
        )

    async def _load_outbox(
        self,
        session: AsyncSession,
        events: tuple[LedgerEventRecord, ...],
        changes: tuple[ServerChangeRecord, ...],
    ) -> tuple[OutboxRecord, ...]:
        keys = {f"ledger:{event.event_id}" for event in events} | {
            f"sync-change:{change.change_id}" for change in changes
        }
        if not keys:
            return ()
        return tuple(
            (
                await session.scalars(
                    select(OutboxRecord)
                    .where(OutboxRecord.idempotency_key.in_(keys))
                    .order_by(OutboxRecord.created_at, OutboxRecord.id)
                )
            ).all()
        )

    def _links(
        self,
        *,
        sources: tuple[SourceRecord, ...],
        provenance: tuple[ProvenanceRecord, ...],
        events: tuple[LedgerEventRecord, ...],
        outbox: tuple[OutboxRecord, ...],
        projections: tuple[ProjectionRecord, ...],
        checkpoints: tuple[ProjectionCheckpoint, ...],
        operations: tuple[SyncOperationRecord, ...],
        changes: tuple[ServerChangeRecord, ...],
        canonical: tuple[CanonicalEntityRecord, ...],
        http_traces: tuple[HttpTraceReference, ...],
    ) -> tuple[TraceLink, ...]:
        provenance_ids = {record.id for record in provenance}
        outbox_keys = {record.idempotency_key for record in outbox}
        projection_by_key = {record.projection_key: record for record in projections}
        checkpoint_by_name = {record.projection_name: record for record in checkpoints}
        operation_ids = {record.operation_id for record in operations}
        changes_by_operation = {record.origin_operation_id for record in changes}
        canonical_by_pair = {(record.entity_type, record.entity_id): record for record in canonical}
        source_hashes_valid = bool(sources) and all(
            _canonical_hash(record.payload) == record.content_hash for record in sources
        )
        event_projection_links = bool(events) and all(
            (projection := projection_by_key.get(f"{event.aggregate_type}:{event.aggregate_id}"))
            is not None
            and projection.source_sequence >= event.sequence
            for event in events
        )
        projection_checkpoint_links = bool(projections) and all(
            (checkpoint := checkpoint_by_name.get(projection.projection_name)) is not None
            and checkpoint.last_sequence >= projection.source_sequence
            for projection in projections
        )
        accepted_operations = tuple(record for record in operations if record.status == "accepted")
        latest_change_by_pair: dict[tuple[str, UUID], ServerChangeRecord] = {}
        for change in changes:
            latest_change_by_pair[(change.entity_type, change.entity_id)] = change
        canonical_links = bool(changes) and all(
            (entity := canonical_by_pair.get(pair)) is not None
            and entity.canonical_revision == change.canonical_revision
            and entity.content_hash == change.content_hash
            for pair, change in latest_change_by_pair.items()
        )
        event_correlations = {event.correlation_id for event in events}
        traced_correlations = {
            _normalized_correlation_id(trace.correlation_id) for trace in http_traces
        }
        return (
            TraceLink(
                code="source_to_provenance",
                linked=bool(sources)
                and all(source.provenance_id in provenance_ids for source in sources),
                evidence=tuple(str(source.provenance_id) for source in sources),
            ),
            TraceLink(
                code="source_content_hash_valid",
                linked=source_hashes_valid,
                evidence=tuple(source.content_hash for source in sources),
            ),
            TraceLink(
                code="provenance_to_ledger",
                linked=bool(events)
                and all(event.provenance_id in provenance_ids for event in events),
                evidence=tuple(str(event.event_id) for event in events),
            ),
            TraceLink(
                code="ledger_to_outbox",
                linked=bool(events)
                and all(f"ledger:{event.event_id}" in outbox_keys for event in events),
                evidence=tuple(f"ledger:{event.event_id}" for event in events),
            ),
            TraceLink(
                code="ledger_to_projection",
                linked=event_projection_links,
                evidence=tuple(sorted(projection_by_key)),
            ),
            TraceLink(
                code="projection_to_checkpoint",
                linked=projection_checkpoint_links,
                evidence=tuple(sorted(checkpoint_by_name)),
            ),
            TraceLink(
                code="aggregate_to_sync_operation",
                linked=bool(operations),
                evidence=tuple(str(operation.operation_id) for operation in operations),
            ),
            TraceLink(
                code="sync_operation_to_server_change",
                linked=bool(accepted_operations)
                and all(
                    operation.operation_id in changes_by_operation
                    for operation in accepted_operations
                ),
                evidence=tuple(
                    str(operation_id) for operation_id in sorted(operation_ids, key=str)
                ),
            ),
            TraceLink(
                code="server_change_to_outbox",
                linked=bool(changes)
                and all(f"sync-change:{change.change_id}" in outbox_keys for change in changes),
                evidence=tuple(f"sync-change:{change.change_id}" for change in changes),
            ),
            TraceLink(
                code="server_change_to_canonical",
                linked=canonical_links,
                evidence=tuple(f"{entity.entity_type}:{entity.entity_id}" for entity in canonical),
            ),
            TraceLink(
                code="canonical_content_hash_valid",
                linked=bool(canonical)
                and all(
                    _canonical_hash(entity.document) == entity.content_hash for entity in canonical
                ),
                evidence=tuple(entity.content_hash for entity in canonical),
            ),
            TraceLink(
                code="ledger_correlation_to_http_trace",
                linked=bool(http_traces) and bool(event_correlations & traced_correlations),
                evidence=tuple(trace.phase for trace in http_traces),
            ),
        )

    @staticmethod
    def _source_contract(record: SourceRecord) -> SourceRecordTrace:
        return SourceRecordTrace(
            id=record.id,
            source_kind=record.source_kind,
            occurred_at=_aware(record.occurred_at),
            recorded_at=_aware(record.recorded_at),
            content_hash=record.content_hash,
            content_hash_valid=_canonical_hash(record.payload) == record.content_hash,
            sensitivity=record.sensitivity,
            provenance_id=record.provenance_id,
        )

    @staticmethod
    def _provenance_contract(record: ProvenanceRecord) -> ProvenanceTrace:
        return ProvenanceTrace(
            id=record.id,
            source_kind=record.source_kind,
            source_id_hash=sha256(record.source_id.encode()).hexdigest(),
            actor_type=record.actor_type,
            actor_id_hash=sha256(record.actor_id.encode()).hexdigest(),
            device_id=record.device_id,
            recorded_at=_aware(record.recorded_at),
            transformation_chain=tuple(record.transformation_chain),
            content_hash=record.content_hash,
        )

    @staticmethod
    def _event_contract(record: LedgerEventRecord) -> LedgerEventTrace:
        return LedgerEventTrace(
            sequence=record.sequence,
            event_id=record.event_id,
            event_type=record.event_type,
            event_schema_version=record.event_schema_version,
            aggregate_type=record.aggregate_type,
            aggregate_id=record.aggregate_id,
            occurred_at=_aware(record.occurred_at),
            recorded_at=_aware(record.recorded_at),
            correlation_id=record.correlation_id,
            causation_id=record.causation_id,
            provenance_id=record.provenance_id,
        )

    @staticmethod
    def _outbox_contract(record: OutboxRecord) -> OutboxTrace:
        completed_at = record.completed_at
        return OutboxTrace(
            id=record.id,
            topic=record.topic,
            aggregate_id=record.aggregate_id,
            idempotency_key=record.idempotency_key,
            status=record.status,
            attempts=record.attempts,
            available_at=_aware(record.available_at),
            created_at=_aware(record.created_at),
            completed_at=_aware(completed_at) if completed_at is not None else None,
            last_error_code=record.last_error_code,
        )

    @staticmethod
    def _projection_contract(record: ProjectionRecord) -> ProjectionTrace:
        return ProjectionTrace(
            projection_name=record.projection_name,
            projection_key=record.projection_key,
            source_sequence=record.source_sequence,
            projection_version=record.projection_version,
            updated_at=_aware(record.updated_at),
        )

    @staticmethod
    def _checkpoint_contract(record: ProjectionCheckpoint) -> ProjectionCheckpointTrace:
        rebuilt_at = record.rebuilt_at
        return ProjectionCheckpointTrace(
            projection_name=record.projection_name,
            last_sequence=record.last_sequence,
            projection_version=record.projection_version,
            rebuilt_at=_aware(rebuilt_at) if rebuilt_at is not None else None,
            updated_at=_aware(record.updated_at),
        )

    @staticmethod
    def _operation_contract(record: SyncOperationRecord) -> SyncOperationTrace:
        return SyncOperationTrace(
            operation_id=record.operation_id,
            device_id=record.device_id,
            device_sequence=record.device_sequence,
            entity_type=record.entity_type,
            entity_id=record.entity_id,
            mutation_type=record.mutation_type,
            base_revision=record.base_revision,
            created_at=_aware(record.created_at),
            received_at=_aware(record.received_at),
            sensitivity_class=record.sensitivity_class,
            request_hash=record.request_hash,
            status=record.status,
            canonical_revision=record.canonical_revision,
            server_change_id=record.server_change_id,
            conflict_id=record.conflict_id,
        )

    @staticmethod
    def _change_contract(record: ServerChangeRecord) -> ServerChangeTrace:
        return ServerChangeTrace(
            change_id=record.change_id,
            entity_type=record.entity_type,
            entity_id=record.entity_id,
            canonical_revision=record.canonical_revision,
            mutation_type=record.mutation_type,
            content_hash=record.content_hash,
            content_hash_valid=_canonical_hash(record.payload) == record.content_hash,
            tombstone=record.tombstone,
            deletion_epoch=record.deletion_epoch,
            merge_result=record.merge_result,
            origin_operation_id=record.origin_operation_id,
            origin_device_id=record.origin_device_id,
            received_at=_aware(record.received_at),
        )

    @staticmethod
    def _canonical_contract(record: CanonicalEntityRecord) -> CanonicalEntityTrace:
        return CanonicalEntityTrace(
            entity_type=record.entity_type,
            entity_id=record.entity_id,
            canonical_revision=record.canonical_revision,
            content_hash=record.content_hash,
            content_hash_valid=_canonical_hash(record.document) == record.content_hash,
            tombstoned=record.tombstoned,
            deletion_epoch=record.deletion_epoch,
            updated_at=_aware(record.updated_at),
            last_operation_id=record.last_operation_id,
            last_device_id=record.last_device_id,
        )
