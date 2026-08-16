"""Owner-governed publication and retrieval of signed feature configurations."""

import base64
import json
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from typing import NoReturn

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.telemetry.feature_flags import (
    FeatureConfigurationError,
    FeatureConfigurationSigner,
    verified_feature_payload,
)
from odyssey.telemetry.models import (
    FeatureConfigurationCreateRequest,
    FeatureConfigurationEnvelope,
    FeatureConfigurationPayload,
    FeatureConfigurationPublication,
)
from odyssey.telemetry.persistence import FeatureConfigurationRecord

MAXIMUM_CONFIGURATION_LIFETIME = timedelta(days=90)


class FeatureConfigurationServiceError(RuntimeError):
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


class FeatureConfigurationService:
    async def publish(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        environment: str,
        request: FeatureConfigurationCreateRequest,
        signer: FeatureConfigurationSigner | None,
        created_by: str,
        now: datetime | None = None,
    ) -> FeatureConfigurationPublication:
        issued_at = normalize_datetime(now or datetime.now(UTC))
        request_hash = canonical_request_hash(request)
        existing = await session.get(FeatureConfigurationRecord, request.configuration_id)
        if existing is not None:
            if existing.owner_id != owner_id or existing.request_sha256 != request_hash:
                self._invalid(
                    "FEATURE_CONFIGURATION_ID_REUSED",
                    "The configuration identifier was already used for different content.",
                    status_code=409,
                )
            return self._publication(existing, created=False)
        if signer is None:
            self._invalid(
                "FEATURE_CONFIGURATION_SIGNING_UNAVAILABLE",
                "Feature configuration signing is not configured.",
                status_code=503,
                retryable=True,
            )
        not_before = normalize_datetime(request.not_before or issued_at)
        expires_at = normalize_datetime(request.expires_at)
        if not_before < issued_at:
            self._invalid(
                "FEATURE_CONFIGURATION_BACKDATED",
                "Feature configurations cannot activate before they are issued.",
            )
        if expires_at <= not_before or expires_at - not_before > MAXIMUM_CONFIGURATION_LIFETIME:
            self._invalid(
                "FEATURE_CONFIGURATION_LIFETIME_INVALID",
                "Feature configurations require a positive lifetime of at most 90 days.",
            )
        if request.reason != request.reason.strip():
            self._invalid(
                "FEATURE_CONFIGURATION_REASON_INVALID",
                "The configuration reason cannot have surrounding whitespace.",
            )

        current = await session.scalar(
            select(FeatureConfigurationRecord)
            .where(
                FeatureConfigurationRecord.owner_id == owner_id,
                FeatureConfigurationRecord.environment == environment,
                FeatureConfigurationRecord.audience == request.audience,
            )
            .order_by(FeatureConfigurationRecord.version.desc())
            .limit(1)
            .with_for_update()
        )
        current_version = current.version if current is not None else 0
        if request.expected_current_version != current_version:
            self._invalid(
                "FEATURE_CONFIGURATION_VERSION_CONFLICT",
                "The expected feature configuration version is stale.",
                status_code=409,
            )
        version = current_version + 1
        payload = FeatureConfigurationPayload(
            configuration_id=request.configuration_id,
            version=version,
            environment=environment,
            audience=request.audience,
            issued_at=issued_at,
            not_before=not_before,
            expires_at=expires_at,
            flags=request.flags,
        )
        envelope = signer.sign(payload)
        payload_bytes = base64.b64decode(envelope.payload_base64, validate=True)
        signature = base64.b64decode(envelope.signature_base64, validate=True)
        public_key = base64.b64decode(signer.public_key_base64, validate=True)
        record = FeatureConfigurationRecord(
            id=request.configuration_id,
            owner_id=owner_id,
            environment=environment,
            audience=request.audience,
            version=version,
            issued_at=issued_at,
            not_before=not_before,
            expires_at=expires_at,
            key_id=envelope.key_id,
            public_key=public_key,
            payload=payload_bytes,
            payload_sha256=envelope.payload_sha256,
            signature=signature,
            request_sha256=request_hash,
            reason=request.reason,
            created_by=created_by,
            created_at=issued_at,
        )
        session.add(record)
        await session.flush()
        return self._publication(record, created=True)

    async def current(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        environment: str,
        audience: str,
        now: datetime | None = None,
    ) -> FeatureConfigurationEnvelope:
        current_time = normalize_datetime(now or datetime.now(UTC))
        record = await session.scalar(
            select(FeatureConfigurationRecord)
            .where(
                FeatureConfigurationRecord.owner_id == owner_id,
                FeatureConfigurationRecord.environment == environment,
                FeatureConfigurationRecord.audience == audience,
                FeatureConfigurationRecord.not_before <= current_time,
                FeatureConfigurationRecord.expires_at > current_time,
            )
            .order_by(FeatureConfigurationRecord.version.desc())
            .limit(1)
        )
        if record is None:
            self._invalid(
                "FEATURE_CONFIGURATION_UNAVAILABLE",
                "No active feature configuration is available for this client.",
                status_code=404,
            )
        return self._envelope(record)

    def _publication(
        self,
        record: FeatureConfigurationRecord,
        *,
        created: bool,
    ) -> FeatureConfigurationPublication:
        return FeatureConfigurationPublication(
            configuration_id=record.id,
            version=record.version,
            issued_at=normalize_datetime(record.issued_at),
            not_before=normalize_datetime(record.not_before),
            expires_at=normalize_datetime(record.expires_at),
            reason=record.reason,
            created=created,
            envelope=self._envelope(record),
        )

    def _envelope(self, record: FeatureConfigurationRecord) -> FeatureConfigurationEnvelope:
        envelope = FeatureConfigurationEnvelope(
            key_id=record.key_id,
            payload_base64=base64.b64encode(record.payload).decode(),
            payload_sha256=record.payload_sha256,
            signature_base64=base64.b64encode(record.signature).decode(),
        )
        try:
            payload = verified_feature_payload(
                envelope,
                public_key_base64=base64.b64encode(record.public_key).decode(),
                expected_key_id=record.key_id,
            )
        except FeatureConfigurationError as error:
            raise FeatureConfigurationServiceError(
                "FEATURE_CONFIGURATION_INTEGRITY_FAILED",
                "The stored feature configuration failed integrity verification.",
                status_code=500,
            ) from error
        if (
            payload.configuration_id != record.id
            or payload.version != record.version
            or payload.environment != record.environment
            or payload.audience != record.audience
            or payload.issued_at != normalize_datetime(record.issued_at)
            or payload.not_before != normalize_datetime(record.not_before)
            or payload.expires_at != normalize_datetime(record.expires_at)
        ):
            raise FeatureConfigurationServiceError(
                "FEATURE_CONFIGURATION_INTEGRITY_FAILED",
                "The stored feature configuration metadata does not match its signed payload.",
                status_code=500,
            )
        return envelope

    def _invalid(
        self,
        code: str,
        message: str,
        *,
        status_code: int = 422,
        retryable: bool = False,
    ) -> NoReturn:
        raise FeatureConfigurationServiceError(
            code,
            message,
            status_code=status_code,
            retryable=retryable,
        )


def canonical_request_hash(request: FeatureConfigurationCreateRequest) -> str:
    content = json.dumps(
        request.model_dump(mode="json"),
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    return sha256(content).hexdigest()


def normalize_datetime(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
