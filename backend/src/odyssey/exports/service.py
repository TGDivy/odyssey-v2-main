"""Idempotent owner export jobs and retry-safe asynchronous processing."""

import asyncio
import json
from base64 import b64encode
from datetime import UTC, datetime
from hashlib import sha256
from os import urandom
from typing import cast
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.attachments.storage import AttachmentStore
from odyssey.db.models import OutboxRecord
from odyssey.db.session import Database
from odyssey.domain.common import UUID7, new_uuid7
from odyssey.exports.archive import (
    OwnerArchiveBuilder,
    OwnerArchiveIntegrityError,
    OwnerArchiveTooLargeError,
)
from odyssey.exports.contracts import (
    ExportCreateRequest,
    ExportFormat,
    ExportJobResponse,
    ExportJobStatus,
)
from odyssey.exports.crypto import ExportKeyManager, encrypt_artifact, wrap_for_owner
from odyssey.exports.persistence import ExportJobAuditRecord, ExportJobRecord
from odyssey.jobs.outbox import OutboxJob, OutboxStatus

OWNER_EXPORT_TOPIC = "owner-export"


class OwnerExportError(RuntimeError):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        status_code: int,
        retryable: bool = False,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status_code = status_code
        self.retryable = retryable


class OwnerExportService:
    async def create(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        request: ExportCreateRequest,
        idempotency_key: str,
        passphrase: str,
        key_manager: ExportKeyManager,
        now: datetime | None = None,
    ) -> ExportJobResponse:
        created_at = now or datetime.now(UTC)
        passphrase_fingerprint = key_manager.passphrase_fingerprint(passphrase)
        request_hash = _request_hash(
            owner_id=owner_id,
            request=request,
            passphrase_fingerprint=passphrase_fingerprint,
        )
        idempotency_key_hash = sha256(f"{owner_id}\0{idempotency_key}".encode()).hexdigest()
        existing = await self._find_by_idempotency_key(session, idempotency_key_hash)
        if existing is not None:
            return self._idempotent_response(existing, request_hash=request_hash)

        job_id = new_uuid7()
        data_key = key_manager.generate_data_key()
        owner_key_envelope = await asyncio.to_thread(
            wrap_for_owner,
            data_key,
            passphrase=passphrase,
            job_id=job_id,
        )
        worker_key_envelope = key_manager.wrap_for_worker(data_key, job_id=job_id)
        record = ExportJobRecord(
            id=job_id,
            owner_id=owner_id,
            status=ExportJobStatus.QUEUED,
            phase="queued",
            scope=request.scope,
            formats=[export_format.value for export_format in request.formats],
            include_raw_sources=request.include_raw_sources,
            include_model_traces=request.include_model_traces,
            owner_key_envelope=owner_key_envelope,
            worker_key_envelope=worker_key_envelope,
            artifact_nonce=urandom(12),
            request_hash=request_hash,
            idempotency_key_hash=idempotency_key_hash,
            attempts=0,
            created_at=created_at,
            updated_at=created_at,
        )
        audit = _audit_record(
            job_id=job_id,
            event_type="queued",
            occurred_at=created_at,
            details={
                "scope": request.scope.value,
                "formats": [export_format.value for export_format in request.formats],
                "include_raw_sources": request.include_raw_sources,
                "include_model_traces": request.include_model_traces,
            },
        )
        outbox = OutboxRecord(
            id=new_uuid7(),
            topic=OWNER_EXPORT_TOPIC,
            aggregate_id=job_id,
            payload={"job_id": str(job_id)},
            idempotency_key=f"owner-export:{idempotency_key_hash}",
            status=OutboxStatus.PENDING,
            attempts=0,
            available_at=created_at,
            created_at=created_at,
        )
        try:
            async with session.begin_nested():
                session.add_all((record, audit, outbox))
                await session.flush()
        except IntegrityError:
            existing = await self._find_by_idempotency_key(session, idempotency_key_hash)
            if existing is None:
                raise
            return self._idempotent_response(existing, request_hash=request_hash)
        return export_job_response(record)

    async def get(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        job_id: UUID7,
    ) -> ExportJobRecord:
        record = await session.scalar(
            select(ExportJobRecord).where(
                ExportJobRecord.id == job_id,
                ExportJobRecord.owner_id == owner_id,
            )
        )
        if record is None:
            raise OwnerExportError(
                "EXPORT_NOT_FOUND",
                "The export job does not exist.",
                status_code=404,
            )
        return record

    async def _find_by_idempotency_key(
        self,
        session: AsyncSession,
        idempotency_key_hash: str,
    ) -> ExportJobRecord | None:
        return cast(
            ExportJobRecord | None,
            await session.scalar(
                select(ExportJobRecord).where(
                    ExportJobRecord.idempotency_key_hash == idempotency_key_hash
                )
            ),
        )

    def _idempotent_response(
        self,
        record: ExportJobRecord,
        *,
        request_hash: str,
    ) -> ExportJobResponse:
        if record.request_hash != request_hash:
            raise OwnerExportError(
                "EXPORT_IDEMPOTENCY_KEY_REUSED",
                "The idempotency key was already used for a different export request.",
                status_code=409,
            )
        return export_job_response(record)


class OwnerExportProcessor:
    def __init__(
        self,
        *,
        database: Database,
        attachment_store: AttachmentStore,
        key_manager: ExportKeyManager,
        maximum_bytes: int,
        maximum_attempts: int,
    ) -> None:
        if maximum_attempts < 1:
            raise ValueError("maximum export attempts must be positive")
        self.database = database
        self.attachment_store = attachment_store
        self.key_manager = key_manager
        self.maximum_bytes = maximum_bytes
        self.maximum_attempts = maximum_attempts
        self.archive_builder = OwnerArchiveBuilder(maximum_bytes=maximum_bytes)

    async def handle(self, job: OutboxJob) -> None:
        payload_job_id = job.payload.get("job_id")
        if payload_job_id != str(job.aggregate_id):
            raise OwnerExportError(
                "EXPORT_OUTBOX_PAYLOAD_INVALID",
                "The export outbox payload is invalid.",
                status_code=500,
            )
        should_process = await self._mark_processing(job)
        if not should_process:
            return
        try:
            await self._build_and_store(job)
        except OwnerArchiveTooLargeError:
            await self._record_failure(
                job,
                error_code="EXPORT_SIZE_LIMIT_EXCEEDED",
                terminal=True,
            )
        except OwnerArchiveIntegrityError:
            await self._record_failure(
                job,
                error_code="EXPORT_SOURCE_INTEGRITY_FAILED",
                terminal=True,
            )
        except Exception as error:
            terminal = job.attempt >= self.maximum_attempts
            await self._record_failure(
                job,
                error_code=type(error).__name__[:100],
                terminal=terminal,
            )
            raise

    async def _mark_processing(self, job: OutboxJob) -> bool:
        now = datetime.now(UTC)
        async with self.database.sessions() as session, session.begin():
            record = await _lock_export_job(session, job.aggregate_id)
            if record is None:
                raise OwnerExportError(
                    "EXPORT_JOB_MISSING",
                    "The queued export job no longer exists.",
                    status_code=500,
                )
            if record.status in {ExportJobStatus.COMPLETED, ExportJobStatus.FAILED}:
                return False
            record.status = ExportJobStatus.PROCESSING
            record.phase = "assembling"
            record.attempts = max(record.attempts, job.attempt)
            record.last_error_code = None
            record.updated_at = now
            session.add(
                _audit_record(
                    job_id=record.id,
                    event_type="processing_started",
                    occurred_at=now,
                    details={"attempt": job.attempt},
                )
            )
        return True

    async def _build_and_store(self, job: OutboxJob) -> None:
        generated_at = datetime.now(UTC)
        async with self.database.sessions() as session, session.begin():
            record = await _lock_export_job(session, job.aggregate_id)
            if record is None:
                raise OwnerExportError(
                    "EXPORT_JOB_MISSING",
                    "The queued export job no longer exists.",
                    status_code=500,
                )
            if record.status == ExportJobStatus.COMPLETED:
                return
            formats = tuple(ExportFormat(value) for value in record.formats)
            archive = await self.archive_builder.build(
                session,
                owner_id=record.owner_id,
                job_id=record.id,
                requested_at=record.created_at,
                generated_at=generated_at,
                formats=formats,
                include_raw_sources=record.include_raw_sources,
                include_model_traces=record.include_model_traces,
                attachment_store=self.attachment_store,
                key_manager=self.key_manager,
            )
            data_key = self.key_manager.unwrap_for_worker(
                dict(record.worker_key_envelope),
                job_id=record.id,
            )
            artifact_nonce = urandom(12)
            artifact = encrypt_artifact(
                archive.plaintext,
                data_key=data_key,
                artifact_nonce=artifact_nonce,
                job_id=record.id,
                owner_key_envelope=dict(record.owner_key_envelope),
                manifest_sha256=archive.manifest_sha256,
                manifest_signature=archive.manifest_signature,
                signing_public_key=archive.signing_public_key,
            )
            if len(artifact) > self.maximum_bytes:
                raise OwnerArchiveTooLargeError("owner export exceeds its configured size limit")
            artifact_hash = sha256(artifact).hexdigest()
            stored_object = await self.attachment_store.write_object(artifact_hash, artifact)
            if stored_object.content_sha256 != artifact_hash or stored_object.byte_size != len(
                artifact
            ):
                raise OwnerArchiveIntegrityError("stored export artifact verification failed")
            completed_at = datetime.now(UTC)
            record.status = ExportJobStatus.COMPLETED
            record.phase = "ready"
            record.last_error_code = None
            record.artifact_nonce = artifact_nonce
            record.artifact_content_hash = artifact_hash
            record.artifact_bytes = len(artifact)
            record.storage_backend = stored_object.storage_backend
            record.storage_bucket = stored_object.bucket_name
            record.storage_version_id = stored_object.version_id
            record.manifest_sha256 = archive.manifest_sha256
            record.manifest_signature = b64encode(archive.manifest_signature).decode()
            record.signing_public_key = b64encode(archive.signing_public_key).decode()
            record.updated_at = completed_at
            record.completed_at = completed_at
            session.add(
                _audit_record(
                    job_id=record.id,
                    event_type="completed",
                    occurred_at=completed_at,
                    details={
                        "attempt": job.attempt,
                        "artifact_sha256": artifact_hash,
                        "artifact_bytes": len(artifact),
                        "manifest_sha256": archive.manifest_sha256,
                        "storage_backend": stored_object.storage_backend,
                    },
                )
            )

    async def _record_failure(
        self,
        job: OutboxJob,
        *,
        error_code: str,
        terminal: bool,
    ) -> None:
        occurred_at = datetime.now(UTC)
        async with self.database.sessions() as session, session.begin():
            record = await _lock_export_job(session, job.aggregate_id)
            if record is None or record.status == ExportJobStatus.COMPLETED:
                return
            record.status = ExportJobStatus.FAILED if terminal else ExportJobStatus.QUEUED
            record.phase = "failed" if terminal else "retry_pending"
            record.attempts = max(record.attempts, job.attempt)
            record.last_error_code = error_code
            record.updated_at = occurred_at
            session.add(
                _audit_record(
                    job_id=record.id,
                    event_type="failed" if terminal else "retry_scheduled",
                    occurred_at=occurred_at,
                    details={
                        "attempt": job.attempt,
                        "error_code": error_code,
                        "terminal": terminal,
                    },
                )
            )


def export_job_response(record: ExportJobRecord) -> ExportJobResponse:
    completed = record.status == ExportJobStatus.COMPLETED
    return ExportJobResponse(
        job_id=record.id,
        status=ExportJobStatus(record.status),
        phase=record.phase,
        status_url=f"/v1/exports/{record.id}",
        download_url=f"/v1/exports/{record.id}/download" if completed else None,
        created_at=_as_utc(record.created_at),
        updated_at=_as_utc(record.updated_at),
        completed_at=_as_utc(record.completed_at) if record.completed_at is not None else None,
        attempts=record.attempts,
        artifact_sha256=record.artifact_content_hash,
        artifact_bytes=record.artifact_bytes,
        manifest_sha256=record.manifest_sha256,
        signing_public_key=record.signing_public_key,
        last_error_code=record.last_error_code,
    )


async def _lock_export_job(
    session: AsyncSession,
    job_id: UUID,
) -> ExportJobRecord | None:
    return cast(
        ExportJobRecord | None,
        await session.scalar(
            select(ExportJobRecord).where(ExportJobRecord.id == job_id).with_for_update()
        ),
    )


def _request_hash(
    *,
    owner_id: str,
    request: ExportCreateRequest,
    passphrase_fingerprint: str,
) -> str:
    document = {
        "owner_id": owner_id,
        "request": request.model_dump(mode="json"),
        "passphrase_fingerprint": passphrase_fingerprint,
    }
    encoded = json.dumps(document, separators=(",", ":"), sort_keys=True).encode()
    return sha256(encoded).hexdigest()


def _audit_record(
    *,
    job_id: UUID,
    event_type: str,
    occurred_at: datetime,
    details: dict[str, object],
) -> ExportJobAuditRecord:
    return ExportJobAuditRecord(
        id=new_uuid7(),
        job_id=job_id,
        event_type=event_type,
        occurred_at=occurred_at,
        details=details,
    )


def _as_utc(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
