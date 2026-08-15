"""Append-only accepted life-model versions."""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import (
    JSON,
    BigInteger,
    CheckConstraint,
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


class LifeModelVersionRecord(Base):
    __tablename__ = "life_model_versions"
    __table_args__ = (
        CheckConstraint(
            "kind IN ('charter', 'life_stage', 'season')",
            name="life_model_versions_kind",
        ),
        CheckConstraint("version_number >= 1", name="life_model_versions_version_positive"),
        CheckConstraint(
            "acceptance_sequence >= 1",
            name="life_model_versions_acceptance_sequence_positive",
        ),
        UniqueConstraint("event_id", name="uq_life_model_versions_event_id"),
        UniqueConstraint(
            "owner_id",
            "kind",
            "logical_id",
            "version_number",
            name="uq_life_model_versions_logical_version",
        ),
        UniqueConstraint(
            "owner_id",
            "kind",
            "acceptance_sequence",
            name="uq_life_model_versions_acceptance_sequence",
        ),
        Index(
            "ix_life_model_versions_owner_kind_accepted",
            "owner_id",
            "kind",
            "accepted_at",
        ),
        Index("ix_life_model_versions_logical", "kind", "logical_id", "version_number"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    owner_id: Mapped[str] = mapped_column(String(50), nullable=False)
    kind: Mapped[str] = mapped_column(String(30), nullable=False)
    logical_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    version_number: Mapped[int] = mapped_column(Integer, nullable=False)
    acceptance_sequence: Mapped[int] = mapped_column(Integer, nullable=False)
    supersedes_version_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("life_model_versions.id", ondelete="RESTRICT")
    )
    status: Mapped[str | None] = mapped_column(String(30))
    acceptance_method: Mapped[str] = mapped_column(String(40), nullable=False)
    accepted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    content_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    document: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    event_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    event_type: Mapped[str] = mapped_column(String(100), nullable=False)
    ledger_sequence: Mapped[int] = mapped_column(BigInteger, nullable=False, unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


@event.listens_for(LifeModelVersionRecord, "before_update")
def reject_life_model_version_update(
    _mapper: Mapper[LifeModelVersionRecord] | None,
    _connection: Connection | None,
    _target: LifeModelVersionRecord,
) -> None:
    raise ImmutableLedgerMutationError("accepted life-model versions are immutable")


@event.listens_for(LifeModelVersionRecord, "before_delete")
def reject_life_model_version_delete(
    _mapper: Mapper[LifeModelVersionRecord] | None,
    _connection: Connection | None,
    _target: LifeModelVersionRecord,
) -> None:
    raise ImmutableLedgerMutationError("accepted life-model versions are immutable")
