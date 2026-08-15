"""Owner authentication, Apple exchange, and revocable device routes."""

from datetime import UTC, datetime
from typing import Annotated, cast
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from odyssey.api.errors import OdysseyError
from odyssey.auth.contracts import (
    AccessTokenRefreshRequest,
    AccessTokenResponse,
    AppleChallengeRequest,
    AppleChallengeResponse,
    AppleExchangeRequest,
    DeviceEnrollmentResponse,
    DeviceListResponse,
    DeviceRevocationRequest,
    DeviceSummary,
    OwnerPrincipal,
    RecoveryExchangeRequest,
)
from odyssey.auth.service import OWNER_ID, AuthService, AuthServiceError
from odyssey.config import AuthMode
from odyssey.domain.common import UUID7

router = APIRouter(prefix="/v1/auth", tags=["authentication"])
bearer_scheme = HTTPBearer(auto_error=False)


def get_auth_service(request: Request) -> AuthService:
    return cast(AuthService, request.app.state.auth_service)


AuthServiceDependency = Annotated[AuthService, Depends(get_auth_service)]


def auth_error(error: AuthServiceError) -> OdysseyError:
    return OdysseyError(
        code=error.code,
        message=error.message,
        status_code=error.status_code,
        retryable=error.retryable,
    )


async def require_owner(
    service: AuthServiceDependency,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
) -> OwnerPrincipal:
    if service.settings.auth_mode is AuthMode.DEVELOPMENT:
        if credentials is not None and (
            credentials.scheme.lower() != "bearer" or credentials.credentials != "development-owner"
        ):
            raise OdysseyError(
                code="AUTHENTICATION_FAILED",
                message="The development owner credential is invalid.",
                status_code=401,
            )
        return OwnerPrincipal(
            owner_id=OWNER_ID,
            authentication_method="development_stub",
        )
    if (
        credentials is None
        or credentials.scheme.lower() != "bearer"
        or not credentials.credentials
        or len(credentials.credentials) > 8192
    ):
        raise OdysseyError(
            code="AUTHENTICATION_REQUIRED",
            message="A valid owner access token is required.",
            status_code=401,
        )
    try:
        return await service.authenticate_access_token(credentials.credentials)
    except AuthServiceError as error:
        raise auth_error(error) from error


OwnerDependency = Annotated[OwnerPrincipal, Depends(require_owner)]


def require_matching_device(principal: OwnerPrincipal, device_id: UUID) -> None:
    if principal.device_id is not None and principal.device_id != device_id:
        raise OdysseyError(
            code="DEVICE_ID_MISMATCH",
            message="The request device does not match the authenticated device.",
            status_code=403,
        )


@router.post("/apple/challenges", response_model=AppleChallengeResponse)
async def create_apple_challenge(
    body: AppleChallengeRequest,
    service: AuthServiceDependency,
) -> AppleChallengeResponse:
    try:
        return await service.create_challenge(body, now=datetime.now(UTC))
    except AuthServiceError as error:
        raise auth_error(error) from error


@router.post("/apple/exchange", response_model=DeviceEnrollmentResponse)
async def exchange_apple_identity(
    body: AppleExchangeRequest,
    service: AuthServiceDependency,
) -> DeviceEnrollmentResponse:
    try:
        return await service.exchange_apple_identity(body, now=datetime.now(UTC))
    except AuthServiceError as error:
        raise auth_error(error) from error


@router.post("/token/refresh", response_model=AccessTokenResponse)
async def refresh_access_token(
    body: AccessTokenRefreshRequest,
    service: AuthServiceDependency,
) -> AccessTokenResponse:
    try:
        return await service.refresh_access_token(body, now=datetime.now(UTC))
    except AuthServiceError as error:
        raise auth_error(error) from error


@router.post("/recovery/exchange", response_model=DeviceEnrollmentResponse)
async def exchange_recovery_credential(
    body: RecoveryExchangeRequest,
    service: AuthServiceDependency,
) -> DeviceEnrollmentResponse:
    try:
        return await service.exchange_recovery_credential(body, now=datetime.now(UTC))
    except AuthServiceError as error:
        raise auth_error(error) from error


@router.get("/devices", response_model=DeviceListResponse)
async def list_devices(
    owner: OwnerDependency,
    service: AuthServiceDependency,
) -> DeviceListResponse:
    try:
        return await service.list_devices(owner)
    except AuthServiceError as error:
        raise auth_error(error) from error


@router.post("/devices/{device_id}/revoke", response_model=DeviceSummary)
async def revoke_device(
    device_id: UUID7,
    body: DeviceRevocationRequest,
    owner: OwnerDependency,
    service: AuthServiceDependency,
) -> DeviceSummary:
    try:
        return await service.revoke_device(
            owner,
            device_id=device_id,
            reason=body.reason,
            now=datetime.now(UTC),
        )
    except AuthServiceError as error:
        raise auth_error(error) from error
