"""Owner-authenticated encrypted asynchronous export API."""

from datetime import UTC, datetime
from hashlib import sha256
from typing import Annotated

from fastapi import APIRouter, Depends, Header
from fastapi.responses import Response

from odyssey.api.auth import OwnerDependency
from odyssey.api.dependencies import AttachmentStoreDependency, SessionDependency
from odyssey.api.errors import OdysseyError
from odyssey.config import Settings, get_settings
from odyssey.domain.common import UUID7
from odyssey.exports.contracts import ExportCreateRequest, ExportJobResponse, ExportJobStatus
from odyssey.exports.crypto import ExportCryptographyError, ExportKeyManager
from odyssey.exports.service import OwnerExportError, OwnerExportService, export_job_response

router = APIRouter(prefix="/v1/exports", tags=["exports"])
service = OwnerExportService()
SettingsDependency = Annotated[Settings, Depends(get_settings)]


@router.post("", response_model=ExportJobResponse, status_code=202)
async def create_export(
    body: ExportCreateRequest,
    session: SessionDependency,
    owner: OwnerDependency,
    settings: SettingsDependency,
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=500)],
    passphrase: Annotated[
        str,
        Header(
            alias="X-Odyssey-Export-Passphrase",
            min_length=1,
            max_length=1024,
            description=(
                "Owner-controlled passphrase; never persisted or included in the request body."
            ),
        ),
    ],
) -> ExportJobResponse:
    _require_enabled(settings)
    key_manager = ExportKeyManager(settings.export_wrapping_key.get_secret_value())
    try:
        async with session.begin():
            return await service.create(
                session,
                owner_id=owner.owner_id,
                request=body,
                idempotency_key=idempotency_key,
                passphrase=passphrase,
                key_manager=key_manager,
                now=datetime.now(UTC),
            )
    except OwnerExportError as error:
        raise _api_error(error) from error
    except ExportCryptographyError as error:
        raise OdysseyError(
            code="EXPORT_ENCRYPTION_INPUT_INVALID",
            message=str(error),
            status_code=422,
        ) from error


@router.get("/{job_id}", response_model=ExportJobResponse)
async def get_export(
    job_id: UUID7,
    session: SessionDependency,
    owner: OwnerDependency,
    settings: SettingsDependency,
) -> ExportJobResponse:
    _require_enabled(settings)
    try:
        record = await service.get(session, owner_id=owner.owner_id, job_id=job_id)
    except OwnerExportError as error:
        raise _api_error(error) from error
    return export_job_response(record)


@router.get(
    "/{job_id}/download",
    response_class=Response,
    responses={
        200: {"content": {"application/vnd.odyssey.owner-export": {}}},
        206: {"content": {"application/vnd.odyssey.owner-export": {}}},
        416: {"description": "The requested byte range is not satisfiable."},
    },
)
async def download_export(
    job_id: UUID7,
    session: SessionDependency,
    owner: OwnerDependency,
    settings: SettingsDependency,
    attachment_store: AttachmentStoreDependency,
    range_header: Annotated[
        str | None,
        Header(alias="Range", max_length=200),
    ] = None,
) -> Response:
    _require_enabled(settings)
    try:
        record = await service.get(session, owner_id=owner.owner_id, job_id=job_id)
    except OwnerExportError as error:
        raise _api_error(error) from error
    if record.status == ExportJobStatus.FAILED:
        raise OdysseyError(
            code="EXPORT_FAILED",
            message="The export job failed and has no downloadable artifact.",
            status_code=409,
        )
    if (
        record.status != ExportJobStatus.COMPLETED
        or record.artifact_content_hash is None
        or record.artifact_bytes is None
    ):
        raise OdysseyError(
            code="EXPORT_NOT_READY",
            message="The export artifact is not ready for download.",
            status_code=409,
            retryable=True,
        )
    try:
        content = await attachment_store.read_object(record.artifact_content_hash)
    except Exception as error:
        raise OdysseyError(
            code="EXPORT_ARTIFACT_UNAVAILABLE",
            message="The encrypted export artifact is temporarily unavailable.",
            status_code=503,
            retryable=True,
        ) from error
    if (
        len(content) != record.artifact_bytes
        or sha256(content).hexdigest() != record.artifact_content_hash
    ):
        raise OdysseyError(
            code="EXPORT_ARTIFACT_INTEGRITY_FAILED",
            message="The encrypted export artifact failed integrity verification.",
            status_code=503,
        )

    common_headers = {
        "Accept-Ranges": "bytes",
        "Cache-Control": "private, no-store",
        "Content-Disposition": f'attachment; filename="odyssey-export-{job_id}.odyx"',
        "ETag": f'"{record.artifact_content_hash}"',
        "X-Content-Type-Options": "nosniff",
    }
    try:
        selected_range = _parse_range(range_header, total_bytes=len(content))
    except ValueError:
        return Response(
            status_code=416,
            headers=common_headers
            | {
                "Content-Range": f"bytes */{len(content)}",
                "Content-Length": "0",
            },
        )
    if selected_range is None:
        return Response(
            content=content,
            media_type="application/vnd.odyssey.owner-export",
            headers=common_headers | {"Content-Length": str(len(content))},
        )
    start, end = selected_range
    partial_content = content[start : end + 1]
    return Response(
        content=partial_content,
        status_code=206,
        media_type="application/vnd.odyssey.owner-export",
        headers=common_headers
        | {
            "Content-Range": f"bytes {start}-{end}/{len(content)}",
            "Content-Length": str(len(partial_content)),
        },
    )


def _require_enabled(settings: Settings) -> None:
    if not settings.owner_export_enabled:
        raise OdysseyError(
            code="OWNER_EXPORT_DISABLED",
            message="Owner exports are disabled until encrypted export storage is configured.",
            status_code=503,
        )


def _api_error(error: OwnerExportError) -> OdysseyError:
    return OdysseyError(
        code=error.code,
        message=str(error),
        status_code=error.status_code,
        retryable=error.retryable,
    )


def _parse_range(value: str | None, *, total_bytes: int) -> tuple[int, int] | None:
    if value is None:
        return None
    unit, separator, requested = value.strip().partition("=")
    if unit.lower() != "bytes" or separator != "=" or "," in requested:
        raise ValueError("only one byte range is supported")
    start_text, separator, end_text = requested.partition("-")
    if separator != "-" or (not start_text and not end_text):
        raise ValueError("invalid byte range")
    if start_text:
        if not start_text.isdigit() or (end_text and not end_text.isdigit()):
            raise ValueError("invalid byte range")
        start = int(start_text)
        if start >= total_bytes:
            raise ValueError("byte range starts after the artifact")
        end = int(end_text) if end_text else total_bytes - 1
        if end < start:
            raise ValueError("byte range ends before it starts")
        return start, min(end, total_bytes - 1)
    if not end_text.isdigit():
        raise ValueError("invalid byte suffix range")
    suffix_bytes = int(end_text)
    if suffix_bytes < 1:
        raise ValueError("byte suffix range must be positive")
    start = max(0, total_bytes - suffix_bytes)
    return start, total_bytes - 1
