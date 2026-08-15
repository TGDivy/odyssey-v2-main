"""Immutable decision preparation persistence."""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import JSON, DateTime, Index, String, Text, Uuid, event
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Mapped, Mapper, mapped_column

from odyssey.db.base import Base
from odyssey.db.models import ImmutableLedgerMutationError


class DecisionPreparationRecord(Base):
    __tablename__ = "decision_preparations"
    __table_args__ = (
        Index("ix_decision_preparations_owner_prepared", "owner_id", "prepared_at"),
        Index("ix_decision_preparations_context", "context_snapshot_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    decision_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    owner_id: Mapped[str] = mapped_column(String(50), nullable=False)
    context_snapshot_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    question: Mapped[str] = mapped_column(Text(), nullable=False)
    status: Mapped[str] = mapped_column(String(50), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    response: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    prepared_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    policy_version: Mapped[str] = mapped_column(String(100), nullable=False)


@event.listens_for(DecisionPreparationRecord, "before_update")
def reject_decision_preparation_update(
    _mapper: Mapper[DecisionPreparationRecord] | None,
    _connection: Connection | None,
    _target: DecisionPreparationRecord,
) -> None:
    raise ImmutableLedgerMutationError("decision preparations are immutable")


@event.listens_for(DecisionPreparationRecord, "before_delete")
def reject_decision_preparation_delete(
    _mapper: Mapper[DecisionPreparationRecord] | None,
    _connection: Connection | None,
    _target: DecisionPreparationRecord,
) -> None:
    raise ImmutableLedgerMutationError("decision preparations are immutable")
