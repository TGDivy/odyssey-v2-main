"""Immutable evidence query replay records."""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import JSON, DateTime, Index, String, Text, Uuid, event
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Mapped, Mapper, mapped_column

from odyssey.db.base import Base
from odyssey.db.models import ImmutableLedgerMutationError


class EvidenceQueryRecord(Base):
    __tablename__ = "evidence_queries"
    __table_args__ = (Index("ix_evidence_queries_owner_time", "owner_id", "assembled_at"),)

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    owner_id: Mapped[str] = mapped_column(String(50), nullable=False)
    question: Mapped[str] = mapped_column(Text(), nullable=False)
    personal_scope: Mapped[str] = mapped_column(String(200), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    response: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    source_entity_ids: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    assembled_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    retrieval_version: Mapped[str] = mapped_column(String(100), nullable=False)


@event.listens_for(EvidenceQueryRecord, "before_update")
def reject_evidence_query_update(
    _mapper: Mapper[EvidenceQueryRecord] | None,
    _connection: Connection | None,
    _target: EvidenceQueryRecord,
) -> None:
    raise ImmutableLedgerMutationError("evidence queries are immutable")


@event.listens_for(EvidenceQueryRecord, "before_delete")
def reject_evidence_query_delete(
    _mapper: Mapper[EvidenceQueryRecord] | None,
    _connection: Connection | None,
    _target: EvidenceQueryRecord,
) -> None:
    raise ImmutableLedgerMutationError("evidence queries are immutable")
