"""Transactional metadata flow for resumable content-addressed uploads."""

import base64
import hmac
import math
import secrets
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.attachments.contracts import (
    AttachmentChunkResponse,
    AttachmentCompleteResponse,
    AttachmentEncryptionMode,
    AttachmentStatus,
    AttachmentStatusResponse,
    AttachmentUploadRequest,
    AttachmentUploadResponse,
    AttachmentUploadStatus,
)
from odyssey.attachments.models import (
    AttachmentChunkRecord,
    AttachmentObjectRecord,
    AttachmentRecord,
    AttachmentUploadRecord,
)
from odyssey.attachments.storage import (
    AttachmentObjectChecksumError,
    AttachmentStorageError,
    ChunkManifest,
    LocalAttachmentStore,
)
from odyssey.db.models import OutboxRecord
from odyssey.domain.common import new_uuid7


class AttachmentError(RuntimeError):
    code = "ATTACHMENT_ERROR"
    retryable = False


class AttachmentNotFoundError(AttachmentError):
    code = "ATTACHMENT_NOT_FOUND"


class AttachmentMetadataConflictError(AttachmentError):
    code = "ATTACHMENT_METADATA_CONFLICT"


class AttachmentUploadTokenError(AttachmentError):
    code = "ATTACHMENT_UPLOAD_TOKEN_INVALID"


class AttachmentUploadExpiredError(AttachmentError):
    code = "ATTACHMENT_UPLOAD_EXPIRED"
    retryable = True


class AttachmentChunkConflictError(AttachmentError):
    code = "ATTACHMENT_CHUNK_CONFLICT"


class AttachmentChunkChecksumError(AttachmentError):
    code = "ATTACHMENT_CHUNK_CHECKSUM_MISMATCH"


class AttachmentUploadIncompleteError(AttachmentError):
    code = "ATTACHMENT_UPLOAD_INCOMPLETE"
    retryable = True


class AttachmentChecksumError(AttachmentError):
    code = "ATTACHMENT_CHECKSUM_MISMATCH"


class AttachmentStorageUnavailableError(AttachmentError):
    code = "ATTACHMENT_STORAGE_UNAVAILABLE"
    retryable = True


class UploadTokenSigner:
    def __init__(self, secret: bytes | None = None) -> None:
        self.secret = secret or secrets.token_bytes(32)

    def issue(self, upload_id: UUID, nonce: UUID, expires_at: datetime) -> str:
        signature = hmac.new(
            self.secret,
            self.message(upload_id, nonce, expires_at),
            sha256,
        ).digest()
        return base64.urlsafe_b64encode(signature).decode().rstrip("=")

    def verify(self, token: str, upload_id: UUID, nonce: UUID, expires_at: datetime) -> bool:
        expected = self.issue(upload_id, nonce, expires_at)
        return hmac.compare_digest(token, expected)

    @staticmethod
    def message(upload_id: UUID, nonce: UUID, expires_at: datetime) -> bytes:
        expiry = expires_at if expires_at.tzinfo is not None else expires_at.replace(tzinfo=UTC)
        return f"{upload_id}:{nonce}:{int(expiry.timestamp())}".encode()


class AttachmentService:
    def __init__(
        self,
        *,
        chunk_size: int,
        maximum_attachment_bytes: int,
        upload_ttl_seconds: int,
    ) -> None:
        if chunk_size < 1 or maximum_attachment_bytes < 1 or upload_ttl_seconds < 1:
            raise ValueError("attachment upload limits must be positive")
        self.chunk_size = chunk_size
        self.maximum_attachment_bytes = maximum_attachment_bytes
        self.upload_ttl_seconds = upload_ttl_seconds

    async def initialize(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        request: AttachmentUploadRequest,
        signer: UploadTokenSigner,
        now: datetime,
    ) -> AttachmentUploadResponse:
        if request.byte_size > self.maximum_attachment_bytes:
            raise AttachmentMetadataConflictError("attachment exceeds the configured size limit")
        attachment = await session.get(AttachmentRecord, request.attachment_id)
        if attachment is not None:
            self.verify_existing_metadata(attachment, owner_id, request)
            if attachment.status == AttachmentStatus.AVAILABLE:
                return self.available_upload_response(attachment, deduplicated=True)
        else:
            existing_object = await session.get(AttachmentObjectRecord, request.content_sha256)
            if existing_object is not None and existing_object.byte_size != request.byte_size:
                raise AttachmentMetadataConflictError(
                    "content hash has incompatible object metadata"
                )
            attachment = AttachmentRecord(
                id=request.attachment_id,
                owner_id=owner_id,
                expected_content_sha256=request.content_sha256,
                object_content_sha256=(
                    existing_object.content_sha256 if existing_object is not None else None
                ),
                byte_size=request.byte_size,
                media_type=request.media_type,
                sensitivity_class=request.sensitivity_class.value,
                encryption_mode=request.encryption_mode.value,
                encryption_metadata=dict(request.encryption_metadata),
                status=(
                    AttachmentStatus.AVAILABLE
                    if existing_object is not None
                    else AttachmentStatus.PENDING_UPLOAD
                ),
                created_at=now,
                committed_at=now if existing_object is not None else None,
            )
            session.add(attachment)
            await session.flush()
            if existing_object is not None:
                return self.available_upload_response(attachment, deduplicated=True)

        active_upload = await session.scalar(
            select(AttachmentUploadRecord)
            .where(
                AttachmentUploadRecord.attachment_id == attachment.id,
                AttachmentUploadRecord.status == AttachmentUploadStatus.UPLOADING,
            )
            .order_by(AttachmentUploadRecord.created_at.desc())
        )
        if active_upload is not None and self.aware(active_upload.expires_at) <= now:
            active_upload.status = AttachmentUploadStatus.EXPIRED
            active_upload = None
        if active_upload is None:
            active_upload = AttachmentUploadRecord(
                id=new_uuid7(),
                attachment_id=attachment.id,
                token_nonce=new_uuid7(),
                chunk_size=self.chunk_size,
                expected_chunks=math.ceil(attachment.byte_size / self.chunk_size),
                status=AttachmentUploadStatus.UPLOADING,
                expires_at=now + timedelta(seconds=self.upload_ttl_seconds),
                created_at=now,
            )
            session.add(active_upload)
            await session.flush()
        return self.upload_response(attachment, active_upload, signer)

    async def put_chunk(
        self,
        session: AsyncSession,
        *,
        upload_id: UUID,
        chunk_index: int,
        token: str,
        declared_content_sha256: str,
        content: bytes,
        signer: UploadTokenSigner,
        store: LocalAttachmentStore,
        now: datetime,
    ) -> AttachmentChunkResponse:
        upload = await session.get(AttachmentUploadRecord, upload_id)
        if upload is None or not signer.verify(
            token, upload.id, upload.token_nonce, self.aware(upload.expires_at)
        ):
            raise AttachmentUploadTokenError("upload token is invalid")
        if self.aware(upload.expires_at) <= now or upload.status == AttachmentUploadStatus.EXPIRED:
            upload.status = AttachmentUploadStatus.EXPIRED
            raise AttachmentUploadExpiredError("upload session expired")
        if upload.status != AttachmentUploadStatus.UPLOADING:
            raise AttachmentChunkConflictError("upload session is not accepting chunks")
        attachment = await session.get(AttachmentRecord, upload.attachment_id)
        if attachment is None:
            raise AttachmentNotFoundError("attachment metadata does not exist")
        expected_size = self.expected_chunk_size(attachment.byte_size, upload, chunk_index)
        if len(content) != expected_size:
            raise AttachmentChunkConflictError("chunk byte size does not match its index")
        content_sha256 = sha256(content).hexdigest()
        if content_sha256 != declared_content_sha256:
            raise AttachmentChunkChecksumError("chunk checksum does not match its content")
        existing = await session.get(AttachmentChunkRecord, (upload.id, chunk_index))
        if existing is not None:
            if existing.content_sha256 != content_sha256 or existing.byte_size != len(content):
                raise AttachmentChunkConflictError("chunk index was reused with different content")
            await store.write_chunk(upload.id, chunk_index, content)
            return AttachmentChunkResponse(
                upload_id=upload.id,
                chunk_index=chunk_index,
                byte_size=existing.byte_size,
                chunk_sha256=existing.content_sha256,
                created=False,
            )
        try:
            stored = await store.write_chunk(upload.id, chunk_index, content)
        except OSError as error:
            raise AttachmentStorageUnavailableError(
                "attachment chunk could not be stored"
            ) from error
        session.add(
            AttachmentChunkRecord(
                upload_id=upload.id,
                chunk_index=chunk_index,
                byte_offset=chunk_index * upload.chunk_size,
                byte_size=stored.byte_size,
                content_sha256=stored.content_sha256,
                storage_key=stored.storage_key,
                received_at=now,
            )
        )
        return AttachmentChunkResponse(
            upload_id=upload.id,
            chunk_index=chunk_index,
            byte_size=stored.byte_size,
            chunk_sha256=stored.content_sha256,
            created=True,
        )

    async def complete(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        upload_id: UUID,
        store: LocalAttachmentStore,
        now: datetime,
    ) -> AttachmentCompleteResponse:
        upload = await session.scalar(
            select(AttachmentUploadRecord)
            .where(AttachmentUploadRecord.id == upload_id)
            .with_for_update()
        )
        if upload is None:
            raise AttachmentNotFoundError("attachment upload does not exist")
        attachment = await session.get(AttachmentRecord, upload.attachment_id)
        if attachment is None or attachment.owner_id != owner_id:
            raise AttachmentNotFoundError("attachment upload does not exist")
        if upload.status == AttachmentUploadStatus.COMPLETED:
            return self.complete_response(attachment)
        if self.aware(upload.expires_at) <= now:
            upload.status = AttachmentUploadStatus.EXPIRED
            raise AttachmentUploadExpiredError("upload session expired")
        chunks = tuple(
            (
                await session.scalars(
                    select(AttachmentChunkRecord)
                    .where(AttachmentChunkRecord.upload_id == upload.id)
                    .order_by(AttachmentChunkRecord.chunk_index)
                )
            ).all()
        )
        if (
            len(chunks) != upload.expected_chunks
            or sum(chunk.byte_size for chunk in chunks) != attachment.byte_size
        ):
            raise AttachmentUploadIncompleteError("not all attachment chunks are present")
        manifests = tuple(
            ChunkManifest(
                index=chunk.chunk_index,
                storage_key=chunk.storage_key,
                content_sha256=chunk.content_sha256,
                byte_size=chunk.byte_size,
            )
            for chunk in chunks
        )
        try:
            stored_object = await store.assemble(
                upload.id,
                manifests,
                expected_content_sha256=attachment.expected_content_sha256,
                expected_byte_size=attachment.byte_size,
            )
        except AttachmentObjectChecksumError as error:
            raise AttachmentChecksumError("attachment checksum verification failed") from error
        except (AttachmentStorageError, OSError) as error:
            raise AttachmentStorageUnavailableError(
                "attachment object could not be committed"
            ) from error
        object_record = await session.get(
            AttachmentObjectRecord, attachment.expected_content_sha256
        )
        if object_record is None:
            session.add(
                AttachmentObjectRecord(
                    content_sha256=stored_object.content_sha256,
                    byte_size=stored_object.byte_size,
                    storage_key=stored_object.storage_key,
                    verified_at=now,
                )
            )
        elif object_record.byte_size != stored_object.byte_size:
            raise AttachmentMetadataConflictError("object manifest has incompatible metadata")
        attachment.object_content_sha256 = stored_object.content_sha256
        attachment.status = AttachmentStatus.AVAILABLE
        attachment.committed_at = now
        upload.status = AttachmentUploadStatus.COMPLETED
        upload.completed_at = now
        session.add(
            OutboxRecord(
                id=new_uuid7(),
                topic="attachment-committed",
                aggregate_id=attachment.id,
                payload={
                    "attachment_id": str(attachment.id),
                    "content_sha256": attachment.expected_content_sha256,
                    "byte_size": attachment.byte_size,
                },
                idempotency_key=f"attachment-committed:{attachment.id}",
                status="pending",
                attempts=0,
                available_at=now,
                created_at=now,
            )
        )
        await session.flush()
        return self.complete_response(attachment)

    async def status(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        attachment_id: UUID,
    ) -> AttachmentStatusResponse:
        attachment = await session.get(AttachmentRecord, attachment_id)
        if attachment is None or attachment.owner_id != owner_id:
            raise AttachmentNotFoundError("attachment does not exist")
        return AttachmentStatusResponse(
            attachment_id=attachment.id,
            status=AttachmentStatus(attachment.status),
            content_sha256=attachment.expected_content_sha256,
            byte_size=attachment.byte_size,
            media_type=attachment.media_type,
            sensitivity_class=attachment.sensitivity_class,
            encryption_mode=AttachmentEncryptionMode(attachment.encryption_mode),
            encryption_metadata=attachment.encryption_metadata,
            object_ref=self.object_ref(attachment.object_content_sha256),
            created_at=self.aware(attachment.created_at),
            committed_at=(
                self.aware(attachment.committed_at) if attachment.committed_at is not None else None
            ),
        )

    @staticmethod
    def verify_existing_metadata(
        attachment: AttachmentRecord,
        owner_id: str,
        request: AttachmentUploadRequest,
    ) -> None:
        expected = (
            owner_id,
            request.content_sha256,
            request.byte_size,
            request.media_type,
            request.sensitivity_class.value,
            request.encryption_mode.value,
            dict(request.encryption_metadata),
        )
        actual = (
            attachment.owner_id,
            attachment.expected_content_sha256,
            attachment.byte_size,
            attachment.media_type,
            attachment.sensitivity_class,
            attachment.encryption_mode,
            attachment.encryption_metadata,
        )
        if actual != expected:
            raise AttachmentMetadataConflictError(
                "attachment identifier was reused with different metadata"
            )

    @staticmethod
    def expected_chunk_size(
        total_size: int,
        upload: AttachmentUploadRecord,
        chunk_index: int,
    ) -> int:
        if chunk_index < 0 or chunk_index >= upload.expected_chunks:
            raise AttachmentChunkConflictError("chunk index is outside the upload manifest")
        if chunk_index < upload.expected_chunks - 1:
            return upload.chunk_size
        return total_size - (chunk_index * upload.chunk_size)

    @staticmethod
    def upload_response(
        attachment: AttachmentRecord,
        upload: AttachmentUploadRecord,
        signer: UploadTokenSigner,
    ) -> AttachmentUploadResponse:
        expires_at = AttachmentService.aware(upload.expires_at)
        token = signer.issue(upload.id, upload.token_nonce, expires_at)
        return AttachmentUploadResponse(
            attachment_id=attachment.id,
            status=AttachmentStatus(attachment.status),
            content_sha256=attachment.expected_content_sha256,
            byte_size=attachment.byte_size,
            upload_id=upload.id,
            chunk_size=upload.chunk_size,
            expected_chunks=upload.expected_chunks,
            signed_chunk_url_template=(
                f"/v1/attachments/uploads/{upload.id}/chunks/{{chunk_index}}?token={token}"
            ),
            upload_expires_at=expires_at,
        )

    @staticmethod
    def available_upload_response(
        attachment: AttachmentRecord, *, deduplicated: bool
    ) -> AttachmentUploadResponse:
        return AttachmentUploadResponse(
            attachment_id=attachment.id,
            status=AttachmentStatus.AVAILABLE,
            content_sha256=attachment.expected_content_sha256,
            byte_size=attachment.byte_size,
            deduplicated=deduplicated,
        )

    @staticmethod
    def complete_response(attachment: AttachmentRecord) -> AttachmentCompleteResponse:
        if attachment.committed_at is None or attachment.object_content_sha256 is None:
            raise AttachmentStorageUnavailableError("attachment commit metadata is incomplete")
        return AttachmentCompleteResponse(
            attachment_id=attachment.id,
            status=AttachmentStatus.AVAILABLE,
            content_sha256=attachment.expected_content_sha256,
            byte_size=attachment.byte_size,
            object_ref=AttachmentService.object_ref(attachment.object_content_sha256) or "",
            committed_at=AttachmentService.aware(attachment.committed_at),
        )

    @staticmethod
    def object_ref(content_sha256: str | None) -> str | None:
        return f"sha256:{content_sha256}" if content_sha256 is not None else None

    @staticmethod
    def aware(value: datetime) -> datetime:
        return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
