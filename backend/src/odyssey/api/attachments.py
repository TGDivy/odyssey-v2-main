"""Owner metadata and signed resumable attachment upload endpoints."""

from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Body, Depends, Header, Query

from odyssey.api.auth import OwnerDependency
from odyssey.api.dependencies import (
    AttachmentStoreDependency,
    SessionDependency,
    UploadTokenSignerDependency,
)
from odyssey.api.errors import OdysseyError
from odyssey.attachments.contracts import (
    SHA256_PATTERN,
    AttachmentChunkResponse,
    AttachmentCompleteResponse,
    AttachmentStatusResponse,
    AttachmentUploadRequest,
    AttachmentUploadResponse,
)
from odyssey.attachments.service import (
    AttachmentChecksumError,
    AttachmentChunkChecksumError,
    AttachmentError,
    AttachmentMetadataConflictError,
    AttachmentNotFoundError,
    AttachmentService,
    AttachmentStorageUnavailableError,
    AttachmentUploadExpiredError,
    AttachmentUploadIncompleteError,
    AttachmentUploadTokenError,
)
from odyssey.config import Settings, get_settings

router = APIRouter(prefix="/v1/attachments", tags=["attachments"])
SettingsDependency = Annotated[Settings, Depends(get_settings)]


def attachment_service(settings: Settings) -> AttachmentService:
    return AttachmentService(
        chunk_size=settings.attachment_chunk_bytes,
        maximum_attachment_bytes=settings.maximum_attachment_bytes,
        upload_ttl_seconds=settings.attachment_upload_ttl_seconds,
    )


def attachment_error(error: AttachmentError) -> OdysseyError:
    if isinstance(error, AttachmentNotFoundError):
        status_code = 404
    elif isinstance(error, AttachmentUploadTokenError):
        status_code = 401
    elif isinstance(error, AttachmentUploadExpiredError):
        status_code = 410
    elif isinstance(error, AttachmentStorageUnavailableError):
        status_code = 503
    elif isinstance(
        error,
        (
            AttachmentChunkChecksumError,
            AttachmentChecksumError,
            AttachmentUploadIncompleteError,
        ),
    ):
        status_code = 422
    elif isinstance(error, AttachmentMetadataConflictError):
        status_code = 409
    else:
        status_code = 409
    return OdysseyError(
        code=error.code,
        message="The attachment request could not be completed.",
        status_code=status_code,
        retryable=error.retryable,
    )


@router.post("/uploads", response_model=AttachmentUploadResponse)
async def initialize_upload(
    body: AttachmentUploadRequest,
    session: SessionDependency,
    owner: OwnerDependency,
    settings: SettingsDependency,
    signer: UploadTokenSignerDependency,
) -> AttachmentUploadResponse:
    try:
        async with session.begin():
            return await attachment_service(settings).initialize(
                session,
                owner_id=owner.owner_id,
                request=body,
                signer=signer,
                now=datetime.now(UTC),
            )
    except AttachmentError as error:
        raise attachment_error(error) from error


@router.put("/uploads/{upload_id}/chunks/{chunk_index}", response_model=AttachmentChunkResponse)
async def upload_chunk(
    upload_id: UUID,
    chunk_index: int,
    content: Annotated[bytes, Body(media_type="application/octet-stream")],
    session: SessionDependency,
    settings: SettingsDependency,
    store: AttachmentStoreDependency,
    signer: UploadTokenSignerDependency,
    token: Annotated[str, Query(min_length=32, max_length=256)],
    chunk_sha256: Annotated[
        str,
        Header(alias="X-Chunk-SHA256", pattern=SHA256_PATTERN.pattern),
    ],
    content_length: Annotated[int | None, Header(alias="Content-Length", ge=0)] = None,
) -> AttachmentChunkResponse:
    if content_length is not None and content_length > settings.attachment_chunk_bytes:
        raise OdysseyError(
            code="ATTACHMENT_CHUNK_TOO_LARGE",
            message="The attachment chunk exceeds the configured limit.",
            status_code=413,
        )
    if len(content) > settings.attachment_chunk_bytes:
        raise OdysseyError(
            code="ATTACHMENT_CHUNK_TOO_LARGE",
            message="The attachment chunk exceeds the configured limit.",
            status_code=413,
        )
    try:
        async with session.begin():
            return await attachment_service(settings).put_chunk(
                session,
                upload_id=upload_id,
                chunk_index=chunk_index,
                token=token,
                declared_content_sha256=chunk_sha256,
                content=content,
                signer=signer,
                store=store,
                now=datetime.now(UTC),
            )
    except AttachmentError as error:
        raise attachment_error(error) from error


@router.post(
    "/uploads/{upload_id}/complete",
    response_model=AttachmentCompleteResponse,
)
async def complete_upload(
    upload_id: UUID,
    session: SessionDependency,
    owner: OwnerDependency,
    store: AttachmentStoreDependency,
    settings: SettingsDependency,
) -> AttachmentCompleteResponse:
    try:
        async with session.begin():
            return await attachment_service(settings).complete(
                session,
                owner_id=owner.owner_id,
                upload_id=upload_id,
                store=store,
                now=datetime.now(UTC),
            )
    except AttachmentError as error:
        raise attachment_error(error) from error


@router.get("/{attachment_id}", response_model=AttachmentStatusResponse)
async def attachment_status(
    attachment_id: UUID,
    session: SessionDependency,
    owner: OwnerDependency,
    settings: SettingsDependency,
) -> AttachmentStatusResponse:
    try:
        async with session.begin():
            return await attachment_service(settings).status(
                session,
                owner_id=owner.owner_id,
                attachment_id=attachment_id,
            )
    except AttachmentError as error:
        raise attachment_error(error) from error
