"""Durable attachment, upload-session, chunk, and object manifests."""

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import (
    JSON,
    BigInteger,
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


class AttachmentObjectRecord(Base):
    __tablename__ = "attachment_objects"
    __table_args__ = (UniqueConstraint("storage_key", name="uq_attachment_objects_storage_key"),)

    content_sha256: Mapped[str] = mapped_column(String(64), primary_key=True)
    byte_size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    storage_key: Mapped[str] = mapped_column(String(1024), nullable=False)
    storage_backend: Mapped[str] = mapped_column(String(30), nullable=False, default="local")
    bucket_name: Mapped[str | None] = mapped_column(String(255))
    object_version_id: Mapped[str | None] = mapped_column(String(255))
    verified_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class AttachmentRecord(Base):
    __tablename__ = "attachments"
    __table_args__ = (
        Index("ix_attachments_owner_created", "owner_id", "created_at"),
        Index("ix_attachments_status", "status", "created_at"),
        Index("ix_attachments_expected_hash", "expected_content_sha256"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    owner_id: Mapped[str] = mapped_column(String(255), nullable=False)
    expected_content_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    object_content_sha256: Mapped[str | None] = mapped_column(
        ForeignKey(
            "attachment_objects.content_sha256",
            name="fk_attachments_object_content_sha256_attachment_objects",
            ondelete="RESTRICT",
        )
    )
    byte_size: Mapped[int] = mapped_column(BigInteger, nullable=False)
    media_type: Mapped[str] = mapped_column(String(200), nullable=False)
    sensitivity_class: Mapped[str] = mapped_column(String(50), nullable=False)
    encryption_mode: Mapped[str] = mapped_column(String(30), nullable=False)
    encryption_metadata: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    committed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class AttachmentUploadRecord(Base):
    __tablename__ = "attachment_uploads"
    __table_args__ = (
        UniqueConstraint("token_nonce", name="uq_attachment_uploads_token_nonce"),
        Index("ix_attachment_uploads_attachment", "attachment_id", "created_at"),
        Index("ix_attachment_uploads_status_expiry", "status", "expires_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True)
    attachment_id: Mapped[UUID] = mapped_column(
        ForeignKey("attachments.id", name="fk_attachment_uploads_attachment_id_attachments"),
        nullable=False,
    )
    token_nonce: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    chunk_size: Mapped[int] = mapped_column(Integer, nullable=False)
    expected_chunks: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[str] = mapped_column(String(30), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class AttachmentChunkRecord(Base):
    __tablename__ = "attachment_chunks"
    __table_args__ = (Index("ix_attachment_chunks_received", "received_at"),)

    upload_id: Mapped[UUID] = mapped_column(
        ForeignKey(
            "attachment_uploads.id",
            name="fk_attachment_chunks_upload_id_attachment_uploads",
            ondelete="RESTRICT",
        ),
        primary_key=True,
    )
    chunk_index: Mapped[int] = mapped_column(Integer, primary_key=True)
    byte_offset: Mapped[int] = mapped_column(BigInteger, nullable=False)
    byte_size: Mapped[int] = mapped_column(Integer, nullable=False)
    content_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    storage_key: Mapped[str] = mapped_column(String(1024), nullable=False)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def reject_attachment_manifest_mutation(
    _mapper: Mapper[Any] | None,
    _connection: Connection | None,
    _target: Any,
) -> None:
    raise ImmutableLedgerMutationError("attachment object/chunk manifests are append-only")


for immutable_model in (AttachmentObjectRecord, AttachmentChunkRecord):
    event.listen(immutable_model, "before_update", reject_attachment_manifest_mutation)
    event.listen(immutable_model, "before_delete", reject_attachment_manifest_mutation)
