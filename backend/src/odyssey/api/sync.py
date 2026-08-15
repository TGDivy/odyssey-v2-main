"""Owner-authenticated push/pull synchronization endpoints."""

from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query

from odyssey.api.auth import OwnerDependency, require_matching_device
from odyssey.api.dependencies import SessionDependency
from odyssey.api.errors import OdysseyError
from odyssey.config import Settings, get_settings
from odyssey.domain.common import UUID7
from odyssey.operations.kill_switches import KillSwitchKey, KillSwitchService
from odyssey.sync.conflicts import (
    SyncConflictNotFoundError,
    SyncConflictService,
    SyncConflictStrategyError,
)
from odyssey.sync.contracts import (
    SyncConflictListResponse,
    SyncConflictResolutionRequest,
    SyncConflictResolutionResponse,
    SyncConflictStatusFilter,
    SyncDeviceDiagnostics,
    SyncDeviceDiagnosticsInput,
    SyncDiagnosticsResponse,
    SyncPullResponse,
    SyncPushRequest,
    SyncPushResponse,
)
from odyssey.sync.diagnostics import SyncDiagnosticsService
from odyssey.sync.models import SyncBatchReceiptRecord
from odyssey.sync.service import (
    BatchIdempotencyConflictError,
    ClientSchemaTooNewError,
    ClientSchemaTooOldError,
    CursorAheadError,
    OperationIdempotencyConflictError,
    SyncError,
    SyncService,
)

router = APIRouter(prefix="/v1/sync", tags=["sync"])
kill_switches = KillSwitchService()
SettingsDependency = Annotated[Settings, Depends(get_settings)]


def service(settings: Settings) -> SyncService:
    return SyncService(
        minimum_client_schema_version=settings.minimum_client_schema_version,
        current_schema_version=settings.current_sync_schema_version,
    )


def diagnostics_service(settings: Settings) -> SyncDiagnosticsService:
    return SyncDiagnosticsService(
        minimum_client_schema_version=settings.minimum_client_schema_version,
        current_schema_version=settings.current_sync_schema_version,
    )


def conflict_service(settings: Settings) -> SyncConflictService:
    return SyncConflictService(service(settings))


def sync_error(error: SyncError, settings: Settings) -> OdysseyError:
    if isinstance(error, SyncConflictNotFoundError):
        return OdysseyError(
            code=error.code,
            message="The requested sync conflict does not exist.",
            status_code=404,
        )
    if isinstance(error, SyncConflictStrategyError):
        return OdysseyError(
            code=error.code,
            message="That resolution would violate this entity's merge policy.",
            status_code=422,
        )
    if isinstance(error, ClientSchemaTooOldError):
        return OdysseyError(
            code=error.code,
            message="The client schema is no longer supported.",
            status_code=426,
            details={"minimum_client_schema_version": settings.minimum_client_schema_version},
        )
    if isinstance(error, ClientSchemaTooNewError):
        return OdysseyError(
            code=error.code,
            message="The client schema is newer than this server.",
            status_code=409,
            retryable=True,
            details={"current_sync_schema_version": settings.current_sync_schema_version},
        )
    if isinstance(
        error,
        (
            BatchIdempotencyConflictError,
            OperationIdempotencyConflictError,
            CursorAheadError,
        ),
    ):
        return OdysseyError(
            code=error.code,
            message="The sync request conflicts with durable server state.",
            status_code=409,
            retryable=error.retryable,
        )
    return OdysseyError(
        code=error.code,
        message="The sync request could not be processed.",
        status_code=409,
        retryable=error.retryable,
    )


@router.post("/push", response_model=SyncPushResponse)
async def push(
    body: SyncPushRequest,
    session: SessionDependency,
    owner: OwnerDependency,
    settings: SettingsDependency,
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=500)],
) -> SyncPushResponse:
    require_matching_device(owner, body.device_id)
    try:
        async with session.begin():
            receipt = await session.get(
                SyncBatchReceiptRecord,
                (body.device_id, idempotency_key),
            )
            if receipt is None and await kill_switches.is_enabled(session, KillSwitchKey.SYNC_PUSH):
                raise OdysseyError(
                    code="SYNC_PUSH_DISABLED",
                    message="New sync pushes are temporarily disabled by an operational control.",
                    status_code=503,
                    retryable=True,
                )
            return await service(settings).push(
                session,
                request=body,
                batch_idempotency_key=idempotency_key,
                server_time=datetime.now(UTC),
            )
    except SyncError as error:
        raise sync_error(error, settings) from error


@router.get("/changes", response_model=SyncPullResponse)
async def changes(
    session: SessionDependency,
    owner: OwnerDependency,
    settings: SettingsDependency,
    cursor: Annotated[str, Query(min_length=3)] = "c_0",
    limit: Annotated[int, Query(ge=1, le=500)] = 500,
    device_id: Annotated[UUID | None, Header(alias="X-Odyssey-Device-ID")] = None,
) -> SyncPullResponse:
    if device_id is not None and device_id.version != 7:
        raise OdysseyError(
            code="INVALID_DEVICE_ID",
            message="The sync device identifier must be UUIDv7.",
            status_code=422,
        )
    if device_id is not None:
        require_matching_device(owner, device_id)
    effective_device_id = owner.device_id or device_id
    try:
        async with session.begin():
            if await kill_switches.is_enabled(session, KillSwitchKey.SYNC_PULL):
                raise OdysseyError(
                    code="SYNC_PULL_DISABLED",
                    message="Sync pulls are temporarily disabled by an operational control.",
                    status_code=503,
                    retryable=True,
                )
            return await service(settings).pull(
                session,
                cursor=cursor,
                limit=limit,
                device_id=effective_device_id,
                server_time=datetime.now(UTC),
            )
    except SyncError as error:
        raise sync_error(error, settings) from error


@router.put(
    "/devices/{device_id}/diagnostics",
    response_model=SyncDeviceDiagnostics,
)
async def report_device_diagnostics(
    device_id: UUID7,
    body: SyncDeviceDiagnosticsInput,
    session: SessionDependency,
    owner: OwnerDependency,
    settings: SettingsDependency,
) -> SyncDeviceDiagnostics:
    require_matching_device(owner, device_id)
    try:
        async with session.begin():
            return await diagnostics_service(settings).report_device(
                session,
                device_id=device_id,
                report=body,
                now=datetime.now(UTC),
            )
    except SyncError as error:
        raise sync_error(error, settings) from error


@router.get("/diagnostics", response_model=SyncDiagnosticsResponse)
async def diagnostics(
    session: SessionDependency,
    owner: OwnerDependency,
    settings: SettingsDependency,
) -> SyncDiagnosticsResponse:
    async with session.begin():
        return await diagnostics_service(settings).snapshot(
            session,
            owner_id=owner.owner_id,
            now=datetime.now(UTC),
        )


@router.get("/conflicts", response_model=SyncConflictListResponse)
async def conflicts(
    session: SessionDependency,
    _owner: OwnerDependency,
    settings: SettingsDependency,
    status: SyncConflictStatusFilter = SyncConflictStatusFilter.PENDING,
    limit: Annotated[int, Query(ge=1, le=200)] = 100,
) -> SyncConflictListResponse:
    async with session.begin():
        return await conflict_service(settings).list(
            session,
            status=status,
            limit=limit,
            server_time=datetime.now(UTC),
        )


@router.post(
    "/conflicts/{conflict_id}/resolve",
    response_model=SyncConflictResolutionResponse,
)
async def resolve_conflict(
    conflict_id: UUID7,
    body: SyncConflictResolutionRequest,
    session: SessionDependency,
    owner: OwnerDependency,
    settings: SettingsDependency,
) -> SyncConflictResolutionResponse:
    require_matching_device(owner, body.device_id)
    try:
        async with session.begin():
            return await conflict_service(settings).resolve(
                session,
                conflict_id=conflict_id,
                request=body,
                server_time=datetime.now(UTC),
            )
    except SyncError as error:
        raise sync_error(error, settings) from error
