"""Server-side sync operation log, canonical projection, and change stream."""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    Uuid,
    event,
)
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Mapped, Mapper, mapped_column

from odyssey.db.base import Base
from odyssey.db.models import ImmutableLedgerMutationError


class SyncDeviceRecord(Base):
    __tablename__ = "sync_devices"

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    last_device_sequence: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    last_server_cursor: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    client_schema_version: Mapped[int] = mapped_column(Integer, nullable=False)
    clock_skew_seconds: Mapped[int | None] = mapped_column(BigInteger)
    registered_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_push_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_pull_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class SyncStateRecord(Base):
    __tablename__ = "sync_state"

    key: Mapped[str] = mapped_column(String(50), primary_key=True)
    last_change_id: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class SyncOperationRecord(Base):
    __tablename__ = "sync_operations"
    __table_args__ = (
        UniqueConstraint("device_id", "device_sequence", name="uq_sync_operations_device_sequence"),
        UniqueConstraint(
            "device_id", "idempotency_key", name="uq_sync_operations_device_idempotency"
        ),
        Index("ix_sync_operations_entity", "entity_type", "entity_id"),
        Index("ix_sync_operations_received", "received_at"),
    )

    operation_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    device_id: Mapped[UUID] = mapped_column(
        ForeignKey("sync_devices.id", ondelete="RESTRICT"), nullable=False
    )
    device_sequence: Mapped[int] = mapped_column(BigInteger, nullable=False)
    entity_type: Mapped[str] = mapped_column(String(100), nullable=False)
    entity_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    mutation_type: Mapped[str] = mapped_column(String(30), nullable=False)
    base_revision: Mapped[int | None] = mapped_column(BigInteger)
    payload: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(500), nullable=False)
    sensitivity_class: Mapped[str] = mapped_column(String(50), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False)
    canonical_revision: Mapped[int | None] = mapped_column(BigInteger)
    server_change_id: Mapped[int | None] = mapped_column(BigInteger)
    conflict_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True))
    result: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)


class CanonicalEntityRecord(Base):
    __tablename__ = "canonical_entities"
    __table_args__ = (
        Index("ix_canonical_entities_updated", "updated_at"),
        Index("ix_canonical_entities_tombstone", "tombstoned", "deletion_epoch"),
    )

    entity_type: Mapped[str] = mapped_column(String(100), primary_key=True)
    entity_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    canonical_revision: Mapped[int] = mapped_column(BigInteger, nullable=False)
    document: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    field_versions: Mapped[dict[str, int]] = mapped_column(JSON, nullable=False)
    content_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    tombstoned: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    deletion_epoch: Mapped[int | None] = mapped_column(BigInteger)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_operation_id: Mapped[UUID] = mapped_column(
        ForeignKey("sync_operations.operation_id", ondelete="RESTRICT"), nullable=False
    )
    last_device_id: Mapped[UUID] = mapped_column(
        ForeignKey("sync_devices.id", ondelete="RESTRICT"), nullable=False
    )


class ServerChangeRecord(Base):
    __tablename__ = "server_changes"
    __table_args__ = (
        Index("ix_server_changes_entity", "entity_type", "entity_id", "canonical_revision"),
        Index("ix_server_changes_received", "received_at"),
    )

    change_id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=False)
    entity_type: Mapped[str] = mapped_column(String(100), nullable=False)
    entity_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    canonical_revision: Mapped[int] = mapped_column(BigInteger, nullable=False)
    mutation_type: Mapped[str] = mapped_column(String(30), nullable=False)
    payload: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    content_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    tombstone: Mapped[bool] = mapped_column(Boolean, nullable=False)
    deletion_epoch: Mapped[int | None] = mapped_column(BigInteger)
    merge_result: Mapped[str] = mapped_column(String(100), nullable=False)
    origin_operation_id: Mapped[UUID] = mapped_column(
        ForeignKey("sync_operations.operation_id", ondelete="RESTRICT"), nullable=False
    )
    origin_device_id: Mapped[UUID] = mapped_column(
        ForeignKey("sync_devices.id", ondelete="RESTRICT"), nullable=False
    )
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class SyncConflictRecord(Base):
    __tablename__ = "sync_conflicts"
    __table_args__ = (
        Index("ix_sync_conflicts_pending", "status", "created_at"),
        Index("ix_sync_conflicts_entity", "entity_type", "entity_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    operation_id: Mapped[UUID] = mapped_column(
        ForeignKey("sync_operations.operation_id", ondelete="RESTRICT"), nullable=False
    )
    device_id: Mapped[UUID] = mapped_column(
        ForeignKey("sync_devices.id", ondelete="RESTRICT"), nullable=False
    )
    entity_type: Mapped[str] = mapped_column(String(100), nullable=False)
    entity_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    conflict_code: Mapped[str] = mapped_column(String(100), nullable=False)
    base_revision: Mapped[int | None] = mapped_column(BigInteger)
    current_revision: Mapped[int | None] = mapped_column(BigInteger)
    current_document: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    incoming_document: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    conflicting_fields: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    resolution: Mapped[dict[str, Any] | None] = mapped_column(JSON)


class SyncBatchReceiptRecord(Base):
    __tablename__ = "sync_batch_receipts"
    __table_args__ = (Index("ix_sync_batch_receipts_created", "created_at"),)

    device_id: Mapped[UUID] = mapped_column(
        ForeignKey("sync_devices.id", ondelete="RESTRICT"), primary_key=True
    )
    idempotency_key: Mapped[str] = mapped_column(String(500), primary_key=True)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    response: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def reject_sync_immutable_mutation(
    _mapper: Mapper[Any] | None,
    _connection: Connection | None,
    _target: Any,
) -> None:
    raise ImmutableLedgerMutationError("sync operation/change/receipt records are append-only")


for immutable_model in (SyncOperationRecord, ServerChangeRecord, SyncBatchReceiptRecord):
    event.listen(immutable_model, "before_update", reject_sync_immutable_mutation)
    event.listen(immutable_model, "before_delete", reject_sync_immutable_mutation)
