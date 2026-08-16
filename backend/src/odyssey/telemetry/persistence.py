"""Append-only signed feature configuration persistence."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    Index,
    Integer,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
    Uuid,
    event,
)
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Mapped, Mapper, mapped_column

from odyssey.db.base import Base
from odyssey.db.models import ImmutableLedgerMutationError


class FeatureConfigurationRecord(Base):
    __tablename__ = "feature_configurations"
    __table_args__ = (
        CheckConstraint("version >= 1", name="feature_configurations_version_positive"),
        UniqueConstraint(
            "owner_id",
            "environment",
            "audience",
            "version",
            name="uq_feature_configurations_owner_environment_audience_version",
        ),
        Index(
            "ix_feature_configurations_current",
            "owner_id",
            "environment",
            "audience",
            "not_before",
            "expires_at",
            "version",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    owner_id: Mapped[str] = mapped_column(String(50), nullable=False)
    environment: Mapped[str] = mapped_column(String(30), nullable=False)
    audience: Mapped[str] = mapped_column(String(255), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    issued_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    not_before: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    key_id: Mapped[str] = mapped_column(String(100), nullable=False)
    public_key: Mapped[bytes] = mapped_column(LargeBinary(length=32), nullable=False)
    payload: Mapped[bytes] = mapped_column(LargeBinary(length=65_536), nullable=False)
    payload_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    signature: Mapped[bytes] = mapped_column(LargeBinary(length=64), nullable=False)
    request_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    reason: Mapped[str] = mapped_column(Text, nullable=False)
    created_by: Mapped[str] = mapped_column(String(255), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


@event.listens_for(FeatureConfigurationRecord, "before_update")
def reject_feature_configuration_update(
    _mapper: Mapper[FeatureConfigurationRecord] | None,
    _connection: Connection | None,
    _target: FeatureConfigurationRecord,
) -> None:
    raise ImmutableLedgerMutationError("feature configurations are append-only")


@event.listens_for(FeatureConfigurationRecord, "before_delete")
def reject_feature_configuration_delete(
    _mapper: Mapper[FeatureConfigurationRecord] | None,
    _connection: Connection | None,
    _target: FeatureConfigurationRecord,
) -> None:
    raise ImmutableLedgerMutationError("feature configurations are append-only")
