"""Immutable recommendation feedback records."""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import JSON, Boolean, DateTime, Index, String, Uuid, event
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Mapped, Mapper, mapped_column

from odyssey.db.base import Base
from odyssey.db.models import ImmutableLedgerMutationError


class RecommendationFeedbackRecord(Base):
    __tablename__ = "recommendation_feedback"
    __table_args__ = (
        Index("ix_recommendation_feedback_recommendation", "recommendation_id", "recorded_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    owner_id: Mapped[str] = mapped_column(String(50), nullable=False)
    recommendation_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    feedback_type: Mapped[str] = mapped_column(String(50), nullable=False)
    apply_scope: Mapped[str] = mapped_column(String(50), nullable=False)
    correction_assertion_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True))
    replacement_assertion_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True))
    ledger_event_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True))
    future_recommendations_affected: Mapped[bool] = mapped_column(Boolean, nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    idempotency_key_hash: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    response: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    policy_version: Mapped[str] = mapped_column(String(100), nullable=False)


@event.listens_for(RecommendationFeedbackRecord, "before_update")
def reject_recommendation_feedback_update(
    _mapper: Mapper[RecommendationFeedbackRecord] | None,
    _connection: Connection | None,
    _target: RecommendationFeedbackRecord,
) -> None:
    raise ImmutableLedgerMutationError("recommendation feedback is immutable")


@event.listens_for(RecommendationFeedbackRecord, "before_delete")
def reject_recommendation_feedback_delete(
    _mapper: Mapper[RecommendationFeedbackRecord] | None,
    _connection: Connection | None,
    _target: RecommendationFeedbackRecord,
) -> None:
    raise ImmutableLedgerMutationError("recommendation feedback is immutable")
