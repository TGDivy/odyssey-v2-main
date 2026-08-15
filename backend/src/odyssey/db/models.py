"""Durable ledger, provenance, projection, and operation models."""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    Uuid,
    event,
    text,
)
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Mapped, Mapper, mapped_column

from odyssey.db.base import Base


class ImmutableLedgerMutationError(RuntimeError):
    pass


class ProvenanceRecord(Base):
    __tablename__ = "provenance_records"

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    source_kind: Mapped[str] = mapped_column(String(100), nullable=False)
    source_id: Mapped[str] = mapped_column(String(500), nullable=False)
    source_version: Mapped[str | None] = mapped_column(String(200))
    actor_type: Mapped[str] = mapped_column(String(50), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(255), nullable=False)
    device_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True))
    observed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    transformation_chain: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)
    model_run_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True))
    confidence: Mapped[float | None] = mapped_column(Float)
    consent_scope: Mapped[str | None] = mapped_column(String(500))
    content_hash: Mapped[str | None] = mapped_column(String(128))
    details: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False, default=dict)


class LedgerEventRecord(Base):
    __tablename__ = "ledger_events"
    __table_args__ = (
        UniqueConstraint("event_id", name="uq_ledger_events_event_id"),
        Index("ix_ledger_events_aggregate", "aggregate_type", "aggregate_id", "sequence"),
        Index("ix_ledger_events_occurred_at", "occurred_at"),
        Index("ix_ledger_events_correlation_id", "correlation_id"),
    )

    sequence: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), primary_key=True, autoincrement=True
    )
    event_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    event_type: Mapped[str] = mapped_column(String(200), nullable=False)
    event_schema_version: Mapped[int] = mapped_column(Integer, nullable=False)
    aggregate_type: Mapped[str] = mapped_column(String(100), nullable=False)
    aggregate_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    actor: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    correlation_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    causation_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True))
    payload: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    provenance_id: Mapped[UUID] = mapped_column(
        ForeignKey("provenance_records.id", ondelete="RESTRICT"), nullable=False
    )


@event.listens_for(LedgerEventRecord, "before_update")
def reject_ledger_update(
    _mapper: Mapper[LedgerEventRecord] | None,
    _connection: Connection | None,
    _target: LedgerEventRecord,
) -> None:
    raise ImmutableLedgerMutationError("ledger events are append-only")


@event.listens_for(LedgerEventRecord, "before_delete")
def reject_ledger_delete(
    _mapper: Mapper[LedgerEventRecord] | None,
    _connection: Connection | None,
    _target: LedgerEventRecord,
) -> None:
    raise ImmutableLedgerMutationError("ledger events are append-only")


class SourceRecord(Base):
    __tablename__ = "source_records"
    __table_args__ = (Index("ix_source_records_kind_occurred", "source_kind", "occurred_at"),)

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    source_kind: Mapped[str] = mapped_column(String(100), nullable=False)
    external_source_id: Mapped[str | None] = mapped_column(String(500))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    observed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    timezone_id: Mapped[str | None] = mapped_column(String(100))
    temporal_precision: Mapped[str] = mapped_column(String(30), nullable=False)
    content_hash: Mapped[str] = mapped_column(String(128), nullable=False)
    sensitivity: Mapped[str] = mapped_column(String(50), nullable=False)
    payload: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    provenance_id: Mapped[UUID] = mapped_column(
        ForeignKey("provenance_records.id", ondelete="RESTRICT"), nullable=False
    )


class AssertionRecord(Base):
    __tablename__ = "assertions"
    __table_args__ = (
        Index("ix_assertions_subject_predicate", "subject_id", "predicate"),
        Index("ix_assertions_validity", "valid_from", "valid_to"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    subject_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    predicate: Mapped[str] = mapped_column(String(200), nullable=False)
    object_value: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    valid_from: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    valid_to: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    epistemic_status: Mapped[str] = mapped_column(String(50), nullable=False)
    confidence: Mapped[float | None] = mapped_column(Float)
    supersedes_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("assertions.id", ondelete="RESTRICT")
    )
    retracted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    provenance_id: Mapped[UUID] = mapped_column(
        ForeignKey("provenance_records.id", ondelete="RESTRICT"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ProjectionRecord(Base):
    __tablename__ = "projection_records"

    projection_name: Mapped[str] = mapped_column(String(100), primary_key=True)
    projection_key: Mapped[str] = mapped_column(String(500), primary_key=True)
    document: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    source_sequence: Mapped[int] = mapped_column(BigInteger, nullable=False)
    projection_version: Mapped[str] = mapped_column(String(100), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ProjectionCheckpoint(Base):
    __tablename__ = "projection_checkpoints"

    projection_name: Mapped[str] = mapped_column(String(100), primary_key=True)
    last_sequence: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    projection_version: Mapped[str] = mapped_column(String(100), nullable=False)
    rebuilt_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class OutboxRecord(Base):
    __tablename__ = "outbox_records"
    __table_args__ = (
        UniqueConstraint("idempotency_key", name="uq_outbox_records_idempotency_key"),
        Index("ix_outbox_records_claim", "status", "available_at", "created_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    topic: Mapped[str] = mapped_column(String(200), nullable=False)
    aggregate_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    payload: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(500), nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False, default="pending")
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    available_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    lease_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_error_code: Mapped[str | None] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class KillSwitch(Base):
    __tablename__ = "kill_switches"

    key: Mapped[str] = mapped_column(String(100), primary_key=True)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    reason: Mapped[str | None] = mapped_column(Text)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("CURRENT_TIMESTAMP")
    )
    updated_by: Mapped[str] = mapped_column(String(255), nullable=False)
