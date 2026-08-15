"""Asynchronous owner export job and immutable transition audit models."""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    DateTime,
    Index,
    Integer,
    LargeBinary,
    String,
    Uuid,
    event,
)
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Mapped, Mapper, mapped_column

from odyssey.db.base import Base
from odyssey.db.models import ImmutableLedgerMutationError


class ExportJobRecord(Base):
    __tablename__ = "export_jobs"
    __table_args__ = (Index("ix_export_jobs_owner_created", "owner_id", "created_at"),)

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    owner_id: Mapped[str] = mapped_column(String(50), nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False)
    phase: Mapped[str] = mapped_column(String(50), nullable=False)
    scope: Mapped[str] = mapped_column(String(100), nullable=False)
    formats: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    include_raw_sources: Mapped[bool] = mapped_column(Boolean, nullable=False)
    include_model_traces: Mapped[bool] = mapped_column(Boolean, nullable=False)
    owner_key_envelope: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    worker_key_envelope: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    artifact_nonce: Mapped[bytes] = mapped_column(LargeBinary(12), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    idempotency_key_hash: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_error_code: Mapped[str | None] = mapped_column(String(100))
    artifact_content_hash: Mapped[str | None] = mapped_column(String(64))
    artifact_bytes: Mapped[int | None] = mapped_column(BigInteger)
    storage_backend: Mapped[str | None] = mapped_column(String(30))
    storage_bucket: Mapped[str | None] = mapped_column(String(255))
    storage_version_id: Mapped[str | None] = mapped_column(String(255))
    manifest_sha256: Mapped[str | None] = mapped_column(String(64))
    manifest_signature: Mapped[str | None] = mapped_column(String(128))
    signing_public_key: Mapped[str | None] = mapped_column(String(128))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class ExportJobAuditRecord(Base):
    __tablename__ = "export_job_audit"
    __table_args__ = (Index("ix_export_job_audit_job_time", "job_id", "occurred_at"),)

    sequence: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"),
        primary_key=True,
        autoincrement=True,
    )
    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False, unique=True)
    job_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    event_type: Mapped[str] = mapped_column(String(50), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    details: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)


@event.listens_for(ExportJobAuditRecord, "before_update")
def reject_export_job_audit_update(
    _mapper: Mapper[ExportJobAuditRecord] | None,
    _connection: Connection | None,
    _target: ExportJobAuditRecord,
) -> None:
    raise ImmutableLedgerMutationError("export job audit is append-only")


@event.listens_for(ExportJobAuditRecord, "before_delete")
def reject_export_job_audit_delete(
    _mapper: Mapper[ExportJobAuditRecord] | None,
    _connection: Connection | None,
    _target: ExportJobAuditRecord,
) -> None:
    raise ImmutableLedgerMutationError("export job audit is append-only")
