"""Transactional single-owner authentication and device lifecycle service."""

from datetime import UTC, datetime, timedelta
from hashlib import sha256
from hmac import compare_digest
from secrets import token_urlsafe
from uuid import UUID

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.auth.apple import (
    AppleIdentityConfigurationError,
    AppleIdentityKeysUnavailableError,
    AppleIdentityTokenError,
    AppleIdentityVerifier,
)
from odyssey.auth.contracts import (
    AccessTokenRefreshRequest,
    AccessTokenResponse,
    AppleChallengeRequest,
    AppleChallengeResponse,
    AppleExchangeRequest,
    DeviceEnrollmentResponse,
    DeviceListResponse,
    DeviceRevocationReason,
    DeviceStatus,
    DeviceSummary,
    OwnerPrincipal,
    RecoveryExchangeRequest,
)
from odyssey.auth.persistence import (
    AppleAuthChallengeRecord,
    AuthDeviceAuditRecord,
    AuthDeviceRecord,
    DeviceCredentialRecord,
    OwnerIdentityRecord,
    OwnerRecoveryCredentialRecord,
)
from odyssey.auth.tokens import (
    AccessTokenConfigurationError,
    AccessTokenError,
    AccessTokenService,
)
from odyssey.config import AuthMode, Settings
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7

OWNER_ID = "owner"


class AuthServiceError(RuntimeError):
    def __init__(
        self,
        *,
        code: str,
        message: str,
        status_code: int,
        retryable: bool = False,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.retryable = retryable


class AuthService:
    def __init__(
        self,
        *,
        settings: Settings,
        database: Database,
        apple_verifier: AppleIdentityVerifier | None = None,
    ) -> None:
        self.settings = settings
        self.database = database
        self.apple_verifier = apple_verifier or AppleIdentityVerifier(
            audience=settings.apple_client_id,
            issuer=settings.apple_issuer,
            jwks_url=settings.apple_jwks_url,
            cache_seconds=settings.apple_jwks_cache_seconds,
            request_timeout_seconds=settings.apple_http_timeout_seconds,
            maximum_token_age_seconds=settings.apple_identity_token_max_age_seconds,
            clock_skew_seconds=settings.auth_clock_skew_seconds,
        )
        self.access_tokens = AccessTokenService(
            signing_key=settings.auth_access_token_signing_key.get_secret_value(),
            ttl_seconds=settings.auth_access_token_ttl_seconds,
            clock_skew_seconds=settings.auth_clock_skew_seconds,
        )

    async def create_challenge(
        self,
        request: AppleChallengeRequest,
        *,
        now: datetime,
    ) -> AppleChallengeResponse:
        self.require_apple_configuration()
        nonce = token_urlsafe(32)
        expires_at = now + timedelta(seconds=self.settings.auth_challenge_ttl_seconds)
        challenge = AppleAuthChallengeRecord(
            id=new_uuid7(),
            device_id=request.device_id,
            nonce_hash=self.hash_secret(nonce),
            created_at=now,
            expires_at=expires_at,
        )
        async with self.database.sessions() as session, session.begin():
            await session.execute(
                delete(AppleAuthChallengeRecord).where(AppleAuthChallengeRecord.expires_at <= now)
            )
            pending_challenges = int(
                await session.scalar(
                    select(func.count())
                    .select_from(AppleAuthChallengeRecord)
                    .where(AppleAuthChallengeRecord.consumed_at.is_(None))
                )
                or 0
            )
            pending_for_device = int(
                await session.scalar(
                    select(func.count())
                    .select_from(AppleAuthChallengeRecord)
                    .where(
                        AppleAuthChallengeRecord.device_id == request.device_id,
                        AppleAuthChallengeRecord.consumed_at.is_(None),
                    )
                )
                or 0
            )
            if (
                pending_challenges >= self.settings.auth_max_pending_challenges
                or pending_for_device >= self.settings.auth_max_pending_challenges_per_device
            ):
                raise AuthServiceError(
                    code="AUTH_CHALLENGE_CAPACITY_REACHED",
                    message="Authentication challenge capacity is temporarily exhausted.",
                    status_code=429,
                    retryable=True,
                )
            session.add(challenge)
        return AppleChallengeResponse(
            challenge_id=challenge.id,
            nonce=nonce,
            expires_at=expires_at,
        )

    async def exchange_apple_identity(
        self,
        request: AppleExchangeRequest,
        *,
        now: datetime,
    ) -> DeviceEnrollmentResponse:
        self.require_apple_configuration()
        token_hash = self.hash_secret(request.identity_token)
        await self.validate_challenge(
            challenge_id=request.challenge_id,
            device_id=request.device_id,
            nonce=request.nonce,
            identity_token_hash=token_hash,
            now=now,
        )
        try:
            apple_identity = await self.apple_verifier.verify(
                request.identity_token,
                raw_nonce=request.nonce,
                now=now,
            )
        except AppleIdentityKeysUnavailableError as error:
            raise AuthServiceError(
                code="APPLE_IDENTITY_UNAVAILABLE",
                message="Apple identity verification is temporarily unavailable.",
                status_code=503,
                retryable=True,
            ) from error
        except AppleIdentityConfigurationError as error:
            raise self.configuration_error() from error
        except AppleIdentityTokenError as error:
            raise self.authentication_error() from error

        refresh_credential = token_urlsafe(48)
        refresh_expires_at = now + timedelta(days=self.settings.auth_refresh_credential_ttl_days)
        async with self.database.sessions() as session, session.begin():
            challenge = await session.scalar(
                select(AppleAuthChallengeRecord)
                .where(AppleAuthChallengeRecord.id == request.challenge_id)
                .with_for_update()
            )
            self.assert_challenge(
                challenge,
                device_id=request.device_id,
                nonce=request.nonce,
                identity_token_hash=token_hash,
                now=now,
            )
            identity = await session.get(OwnerIdentityRecord, OWNER_ID)
            if identity is None:
                expected_subject = self.settings.apple_bootstrap_subject.get_secret_value()
                if not expected_subject:
                    raise AuthServiceError(
                        code="OWNER_BOOTSTRAP_REQUIRED",
                        message="The owner identity must be bootstrapped by the operator.",
                        status_code=503,
                    )
                if not compare_digest(apple_identity.subject, expected_subject):
                    raise self.identity_not_allowed_error()
                identity = OwnerIdentityRecord(
                    owner_id=OWNER_ID,
                    apple_subject=apple_identity.subject,
                    created_at=now,
                    last_authenticated_at=now,
                )
                session.add(identity)
                await session.flush()
            elif not compare_digest(identity.apple_subject, apple_identity.subject):
                raise self.identity_not_allowed_error()
            else:
                identity.last_authenticated_at = now

            device = await self.enroll_device(
                session,
                device_id=request.device_id,
                display_name=request.display_name,
                platform=request.platform.value,
                app_version=request.app_version,
                refresh_credential=refresh_credential,
                refresh_expires_at=refresh_expires_at,
                now=now,
                enrolled_event="enrolled",
                reissued_event="credential_reissued",
            )
            if challenge is not None and challenge.consumed_at is None:
                challenge.consumed_at = now
                challenge.identity_token_hash = token_hash
            try:
                access_token = self.access_tokens.issue(
                    owner_id=OWNER_ID,
                    device_id=device.id,
                    now=now,
                )
            except AccessTokenConfigurationError as error:
                raise self.configuration_error() from error

        return DeviceEnrollmentResponse(
            access_token=access_token.token,
            access_token_expires_at=access_token.expires_at,
            refresh_credential=refresh_credential,
            refresh_credential_expires_at=refresh_expires_at,
            device=self.device_summary(device),
        )

    async def exchange_recovery_credential(
        self,
        request: RecoveryExchangeRequest,
        *,
        now: datetime,
    ) -> DeviceEnrollmentResponse:
        self.require_apple_configuration()
        refresh_credential = token_urlsafe(48)
        refresh_expires_at = now + timedelta(days=self.settings.auth_refresh_credential_ttl_days)
        async with self.database.sessions() as session, session.begin():
            recovery = await session.scalar(
                select(OwnerRecoveryCredentialRecord)
                .where(
                    OwnerRecoveryCredentialRecord.credential_hash
                    == self.hash_secret(request.recovery_credential)
                )
                .with_for_update()
            )
            identity = await session.get(OwnerIdentityRecord, OWNER_ID)
            if (
                recovery is None
                or identity is None
                or recovery.owner_id != OWNER_ID
                or recovery.consumed_at is not None
                or recovery.revoked_at is not None
                or self.aware(recovery.expires_at) <= now
            ):
                raise self.authentication_error()
            device = await self.enroll_device(
                session,
                device_id=request.device_id,
                display_name=request.display_name,
                platform=request.platform.value,
                app_version=request.app_version,
                refresh_credential=refresh_credential,
                refresh_expires_at=refresh_expires_at,
                now=now,
                enrolled_event="recovery_enrolled",
                reissued_event="recovery_credential_reissued",
            )
            recovery.consumed_at = now
            recovery.consumed_by_device_id = device.id
            try:
                access_token = self.access_tokens.issue(
                    owner_id=OWNER_ID,
                    device_id=device.id,
                    now=now,
                )
            except AccessTokenConfigurationError as error:
                raise self.configuration_error() from error
        return DeviceEnrollmentResponse(
            access_token=access_token.token,
            access_token_expires_at=access_token.expires_at,
            refresh_credential=refresh_credential,
            refresh_credential_expires_at=refresh_expires_at,
            device=self.device_summary(device),
        )

    async def refresh_access_token(
        self,
        request: AccessTokenRefreshRequest,
        *,
        now: datetime,
    ) -> AccessTokenResponse:
        self.require_apple_configuration()
        async with self.database.sessions() as session, session.begin():
            credential = await session.scalar(
                select(DeviceCredentialRecord)
                .where(DeviceCredentialRecord.device_id == request.device_id)
                .with_for_update()
            )
            device = await session.get(AuthDeviceRecord, request.device_id)
            if (
                credential is None
                or device is None
                or device.status != DeviceStatus.ACTIVE
                or credential.revoked_at is not None
                or self.aware(credential.expires_at) <= now
                or not compare_digest(
                    credential.credential_hash,
                    self.hash_secret(request.refresh_credential),
                )
            ):
                raise self.authentication_error()
            credential.last_used_at = now
            device.last_authenticated_at = now
            device.last_seen_at = now
            try:
                access_token = self.access_tokens.issue(
                    owner_id=device.owner_id,
                    device_id=device.id,
                    now=now,
                )
            except AccessTokenConfigurationError as error:
                raise self.configuration_error() from error
        return AccessTokenResponse(
            access_token=access_token.token,
            access_token_expires_at=access_token.expires_at,
        )

    async def authenticate_access_token(self, token: str) -> OwnerPrincipal:
        self.require_apple_configuration()
        try:
            claims = self.access_tokens.verify(token)
        except AccessTokenConfigurationError as error:
            raise self.configuration_error() from error
        except AccessTokenError as error:
            raise self.authentication_error() from error
        async with self.database.sessions() as session:
            device = await session.get(AuthDeviceRecord, claims.device_id)
            identity = await session.get(OwnerIdentityRecord, claims.owner_id)
        if (
            device is None
            or identity is None
            or device.owner_id != claims.owner_id
            or device.status != DeviceStatus.ACTIVE
        ):
            raise self.authentication_error()
        return OwnerPrincipal(
            owner_id=claims.owner_id,
            device_id=claims.device_id,
            authentication_method="odyssey_access_token",
        )

    async def list_devices(self, principal: OwnerPrincipal) -> DeviceListResponse:
        self.require_apple_configuration()
        async with self.database.sessions() as session:
            devices = tuple(
                (
                    await session.scalars(
                        select(AuthDeviceRecord)
                        .where(AuthDeviceRecord.owner_id == principal.owner_id)
                        .order_by(AuthDeviceRecord.enrolled_at, AuthDeviceRecord.id)
                    )
                ).all()
            )
        return DeviceListResponse(devices=tuple(self.device_summary(device) for device in devices))

    async def revoke_device(
        self,
        principal: OwnerPrincipal,
        *,
        device_id: UUID,
        reason: DeviceRevocationReason,
        now: datetime,
    ) -> DeviceSummary:
        self.require_apple_configuration()
        async with self.database.sessions() as session, session.begin():
            device = await session.scalar(
                select(AuthDeviceRecord)
                .where(
                    AuthDeviceRecord.id == device_id,
                    AuthDeviceRecord.owner_id == principal.owner_id,
                )
                .with_for_update()
            )
            if device is None:
                raise AuthServiceError(
                    code="DEVICE_NOT_FOUND",
                    message="The enrolled device was not found.",
                    status_code=404,
                )
            if device.status == DeviceStatus.ACTIVE:
                device.status = DeviceStatus.REVOKED
                device.revoked_at = now
                device.revocation_reason = reason.value
                credential = await session.get(DeviceCredentialRecord, device.id)
                if credential is not None:
                    credential.revoked_at = now
                session.add(
                    AuthDeviceAuditRecord(
                        id=new_uuid7(),
                        device_id=device.id,
                        event_type="revoked",
                        occurred_at=now,
                        actor_device_id=principal.device_id,
                        reason_code=reason.value,
                        details={},
                    )
                )
        return self.device_summary(device)

    async def enroll_device(
        self,
        session: AsyncSession,
        *,
        device_id: UUID,
        display_name: str,
        platform: str,
        app_version: str,
        refresh_credential: str,
        refresh_expires_at: datetime,
        now: datetime,
        enrolled_event: str,
        reissued_event: str,
    ) -> AuthDeviceRecord:
        device = await session.get(AuthDeviceRecord, device_id)
        enrolled = device is None
        if device is None:
            device = AuthDeviceRecord(
                id=device_id,
                owner_id=OWNER_ID,
                display_name=display_name,
                platform=platform,
                app_version=app_version,
                status=DeviceStatus.ACTIVE,
                enrolled_at=now,
                last_authenticated_at=now,
                last_seen_at=now,
            )
            session.add(device)
            await session.flush()
        elif device.status != DeviceStatus.ACTIVE or device.owner_id != OWNER_ID:
            raise AuthServiceError(
                code="DEVICE_REVOKED",
                message="This device enrollment has been revoked.",
                status_code=401,
            )
        else:
            device.display_name = display_name
            device.platform = platform
            device.app_version = app_version
            device.last_authenticated_at = now
            device.last_seen_at = now

        credential = await session.get(DeviceCredentialRecord, device_id)
        if credential is None:
            credential = DeviceCredentialRecord(
                device_id=device_id,
                credential_hash=self.hash_secret(refresh_credential),
                issued_at=now,
                expires_at=refresh_expires_at,
            )
            session.add(credential)
        else:
            credential.credential_hash = self.hash_secret(refresh_credential)
            credential.issued_at = now
            credential.expires_at = refresh_expires_at
            credential.last_used_at = None
            credential.revoked_at = None
        session.add(
            AuthDeviceAuditRecord(
                id=new_uuid7(),
                device_id=device.id,
                event_type=enrolled_event if enrolled else reissued_event,
                occurred_at=now,
                actor_device_id=None,
                reason_code=None,
                details={"platform": platform, "app_version": app_version},
            )
        )
        return device

    async def validate_challenge(
        self,
        *,
        challenge_id: UUID,
        device_id: UUID,
        nonce: str,
        identity_token_hash: str,
        now: datetime,
    ) -> None:
        async with self.database.sessions() as session:
            challenge = await session.get(AppleAuthChallengeRecord, challenge_id)
        self.assert_challenge(
            challenge,
            device_id=device_id,
            nonce=nonce,
            identity_token_hash=identity_token_hash,
            now=now,
        )

    def assert_challenge(
        self,
        challenge: AppleAuthChallengeRecord | None,
        *,
        device_id: UUID,
        nonce: str,
        identity_token_hash: str,
        now: datetime,
    ) -> None:
        if (
            challenge is None
            or challenge.device_id != device_id
            or self.aware(challenge.expires_at) <= now
            or not compare_digest(challenge.nonce_hash, self.hash_secret(nonce))
            or (
                challenge.consumed_at is not None
                and not compare_digest(challenge.identity_token_hash or "", identity_token_hash)
            )
        ):
            raise self.authentication_error()

    def require_apple_configuration(self) -> None:
        if self.settings.auth_mode is not AuthMode.SIGN_IN_WITH_APPLE:
            raise AuthServiceError(
                code="AUTH_MODE_DISABLED",
                message="Sign in with Apple authentication is not enabled.",
                status_code=409,
            )
        if (
            not self.settings.apple_client_id
            or len(self.settings.auth_access_token_signing_key.get_secret_value().encode()) < 32
        ):
            raise self.configuration_error()

    @staticmethod
    def device_summary(device: AuthDeviceRecord) -> DeviceSummary:
        return DeviceSummary(
            device_id=device.id,
            display_name=device.display_name,
            platform=device.platform,
            app_version=device.app_version,
            status=device.status,
            enrolled_at=AuthService.aware(device.enrolled_at),
            last_authenticated_at=AuthService.aware(device.last_authenticated_at),
            last_seen_at=AuthService.aware(device.last_seen_at),
            revoked_at=AuthService.aware(device.revoked_at) if device.revoked_at else None,
            revocation_reason=device.revocation_reason,
        )

    @staticmethod
    def hash_secret(value: str) -> str:
        return sha256(value.encode()).hexdigest()

    @staticmethod
    def aware(value: datetime) -> datetime:
        return value if value.tzinfo is not None else value.replace(tzinfo=UTC)

    @staticmethod
    def authentication_error() -> AuthServiceError:
        return AuthServiceError(
            code="AUTHENTICATION_FAILED",
            message="The authentication credential is invalid or expired.",
            status_code=401,
        )

    @staticmethod
    def identity_not_allowed_error() -> AuthServiceError:
        return AuthServiceError(
            code="OWNER_IDENTITY_NOT_ALLOWED",
            message="The verified identity is not authorized for this private deployment.",
            status_code=403,
        )

    @staticmethod
    def configuration_error() -> AuthServiceError:
        return AuthServiceError(
            code="AUTH_CONFIGURATION_UNAVAILABLE",
            message="Production authentication is not fully configured.",
            status_code=503,
        )
