"""Immutable intervention-policy audit persistence."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import JSON, DateTime, Index, String, Uuid, event
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Mapped, Mapper, mapped_column

from odyssey.db.base import Base
from odyssey.db.models import ImmutableLedgerMutationError


class InterventionEvaluationRecord(Base):
    __tablename__ = "intervention_evaluations"
    __table_args__ = (
        Index("ix_intervention_evaluations_owner_time", "owner_id", "evaluated_at"),
        Index("ix_intervention_evaluations_semantic_time", "semantic_key", "evaluated_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    owner_id: Mapped[str] = mapped_column(String(50), nullable=False)
    opportunity_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    semantic_key: Mapped[str] = mapped_column(String(500), nullable=False)
    evaluated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    urgency: Mapped[str] = mapped_column(String(30), nullable=False)
    policy: Mapped[str] = mapped_column(String(30), nullable=False)
    reason_codes: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    surface: Mapped[str | None] = mapped_column(String(50))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    retry_after: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    policy_version: Mapped[str] = mapped_column(String(100), nullable=False)
    request_context_hash: Mapped[str] = mapped_column(String(64), nullable=False)


@event.listens_for(InterventionEvaluationRecord, "before_update")
def reject_intervention_evaluation_update(
    _mapper: Mapper[InterventionEvaluationRecord] | None,
    _connection: Connection | None,
    _target: InterventionEvaluationRecord,
) -> None:
    raise ImmutableLedgerMutationError("intervention evaluations are immutable")


@event.listens_for(InterventionEvaluationRecord, "before_delete")
def reject_intervention_evaluation_delete(
    _mapper: Mapper[InterventionEvaluationRecord] | None,
    _connection: Connection | None,
    _target: InterventionEvaluationRecord,
) -> None:
    raise ImmutableLedgerMutationError("intervention evaluations are immutable")
