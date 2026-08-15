"""Closed authentication, enrollment, and device-lifecycle contracts."""

from enum import StrEnum
from typing import Literal

from pydantic import AwareDatetime, Field

from odyssey.domain.common import UUID7, StrictModel


class DevicePlatform(StrEnum):
    IOS = "ios"
    IPADOS = "ipados"
    MACOS = "macos"
    WATCHOS = "watchos"
    VISIONOS = "visionos"


class DeviceStatus(StrEnum):
    ACTIVE = "active"
    REVOKED = "revoked"


class DeviceRevocationReason(StrEnum):
    COMPROMISED = "compromised"
    LOST = "lost"
    OWNER_REQUEST = "owner_request"
    REINSTALLED = "reinstalled"
    RETIRED = "retired"


class OwnerPrincipal(StrictModel):
    owner_id: str
    device_id: UUID7 | None = None
    authentication_method: str


class AppleChallengeRequest(StrictModel):
    device_id: UUID7


class AppleChallengeResponse(StrictModel):
    challenge_id: UUID7
    nonce: str
    expires_at: AwareDatetime


class AppleExchangeRequest(StrictModel):
    challenge_id: UUID7
    device_id: UUID7
    nonce: str = Field(min_length=32, max_length=200)
    identity_token: str = Field(min_length=100, max_length=16_384)
    display_name: str = Field(min_length=1, max_length=100)
    platform: DevicePlatform
    app_version: str = Field(min_length=1, max_length=100)


class DeviceSummary(StrictModel):
    device_id: UUID7
    display_name: str
    platform: DevicePlatform
    app_version: str
    status: DeviceStatus
    enrolled_at: AwareDatetime
    last_authenticated_at: AwareDatetime
    last_seen_at: AwareDatetime
    revoked_at: AwareDatetime | None = None
    revocation_reason: DeviceRevocationReason | None = None


class DeviceEnrollmentResponse(StrictModel):
    token_type: Literal["Bearer"] = Field(default="Bearer")
    access_token: str
    access_token_expires_at: AwareDatetime
    refresh_credential: str
    refresh_credential_expires_at: AwareDatetime
    device: DeviceSummary


class AccessTokenRefreshRequest(StrictModel):
    device_id: UUID7
    refresh_credential: str = Field(min_length=32, max_length=512)


class AccessTokenResponse(StrictModel):
    token_type: Literal["Bearer"] = Field(default="Bearer")
    access_token: str
    access_token_expires_at: AwareDatetime


class DeviceListResponse(StrictModel):
    devices: tuple[DeviceSummary, ...]


class DeviceRevocationRequest(StrictModel):
    reason: DeviceRevocationReason
