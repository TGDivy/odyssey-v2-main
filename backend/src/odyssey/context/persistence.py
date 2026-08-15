"""Immutable persisted context snapshots."""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import JSON, DateTime, Index, String, Uuid, event
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Mapped, Mapper, mapped_column

from odyssey.db.base import Base
from odyssey.db.models import ImmutableLedgerMutationError


class ContextSnapshotRecord(Base):
    __tablename__ = "context_snapshots"
    __table_args__ = (Index("ix_context_snapshots_owner_built", "owner_id", "built_at"),)

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    owner_id: Mapped[str] = mapped_column(String(50), nullable=False)
    as_of: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    built_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    horizon: Mapped[str] = mapped_column(String(30), nullable=False)
    purpose: Mapped[str] = mapped_column(String(200), nullable=False)
    builder_version: Mapped[str] = mapped_column(String(100), nullable=False)
    content_hash: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    document: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)


@event.listens_for(ContextSnapshotRecord, "before_update")
def reject_context_snapshot_update(
    _mapper: Mapper[ContextSnapshotRecord] | None,
    _connection: Connection | None,
    _target: ContextSnapshotRecord,
) -> None:
    raise ImmutableLedgerMutationError("context snapshots are immutable")


@event.listens_for(ContextSnapshotRecord, "before_delete")
def reject_context_snapshot_delete(
    _mapper: Mapper[ContextSnapshotRecord] | None,
    _connection: Connection | None,
    _target: ContextSnapshotRecord,
) -> None:
    raise ImmutableLedgerMutationError("context snapshots are immutable")
