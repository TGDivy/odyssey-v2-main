"""Durable single-owner identity and separately revocable device records."""

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


class ImmutableAuthAuditError(RuntimeError):
    pass


class OwnerIdentityRecord(Base):
    __tablename__ = "owner_identities"
    __table_args__ = (
        CheckConstraint("owner_id = 'owner'", name="single_owner_identity"),
        UniqueConstraint("apple_subject", name="uq_owner_identities_apple_subject"),
    )

    owner_id: Mapped[str] = mapped_column(String(50), primary_key=True)
    apple_subject: Mapped[str] = mapped_column(String(255), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_authenticated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class AuthDeviceRecord(Base):
    __tablename__ = "auth_devices"
    __table_args__ = (
        Index("ix_auth_devices_owner_status", "owner_id", "status"),
        Index("ix_auth_devices_last_seen", "last_seen_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    owner_id: Mapped[str] = mapped_column(
        ForeignKey("owner_identities.owner_id", ondelete="RESTRICT"), nullable=False
    )
    display_name: Mapped[str] = mapped_column(String(100), nullable=False)
    platform: Mapped[str] = mapped_column(String(30), nullable=False)
    app_version: Mapped[str] = mapped_column(String(100), nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False)
    enrolled_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_authenticated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revocation_reason: Mapped[str | None] = mapped_column(String(50))


class DeviceCredentialRecord(Base):
    __tablename__ = "auth_device_credentials"
    __table_args__ = (
        UniqueConstraint("credential_hash", name="uq_auth_device_credentials_hash"),
        Index("ix_auth_device_credentials_expires", "expires_at"),
    )

    device_id: Mapped[UUID] = mapped_column(
        ForeignKey("auth_devices.id", ondelete="RESTRICT"), primary_key=True
    )
    credential_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    issued_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class AppleAuthChallengeRecord(Base):
    __tablename__ = "apple_auth_challenges"
    __table_args__ = (
        UniqueConstraint("nonce_hash", name="uq_apple_auth_challenges_nonce_hash"),
        Index("ix_apple_auth_challenges_expires", "expires_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    device_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    nonce_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    identity_token_hash: Mapped[str | None] = mapped_column(String(64))


class AuthDeviceAuditRecord(Base):
    __tablename__ = "auth_device_audit"
    __table_args__ = (
        UniqueConstraint("id", name="uq_auth_device_audit_id"),
        Index("ix_auth_device_audit_device_occurred", "device_id", "occurred_at"),
    )

    sequence: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), primary_key=True, autoincrement=True
    )
    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    device_id: Mapped[UUID] = mapped_column(
        ForeignKey("auth_devices.id", ondelete="RESTRICT"), nullable=False
    )
    event_type: Mapped[str] = mapped_column(String(50), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    actor_device_id: Mapped[UUID | None] = mapped_column(Uuid(as_uuid=True))
    reason_code: Mapped[str | None] = mapped_column(String(50))
    details: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False, default=dict)


@event.listens_for(AuthDeviceAuditRecord, "before_update")
@event.listens_for(AuthDeviceAuditRecord, "before_delete")
def reject_auth_device_audit_mutation(
    _mapper: Mapper[AuthDeviceAuditRecord] | None,
    _connection: Connection | None,
    _target: AuthDeviceAuditRecord,
) -> None:
    raise ImmutableAuthAuditError("authentication device audit records are append-only")
