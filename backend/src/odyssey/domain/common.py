"""Common immutable domain values shared by all Odyssey modules."""

import secrets
import time
from collections.abc import Mapping
from datetime import date, datetime
from enum import StrEnum
from typing import Annotated, Any
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator
from pydantic.functional_validators import AfterValidator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, validate_default=True)


def new_uuid7() -> UUID:
    timestamp_ms = time.time_ns() // 1_000_000
    random_a = secrets.randbits(12)
    random_b = secrets.randbits(62)
    value = timestamp_ms << 80
    value |= 0x7 << 76
    value |= random_a << 64
    value |= 0b10 << 62
    value |= random_b
    return UUID(int=value)


def validate_uuid7(value: UUID) -> UUID:
    if value.version != 7:
        raise ValueError("identifier must be UUIDv7")
    return value


UUID7 = Annotated[UUID, AfterValidator(validate_uuid7)]
InstantOrLocalDate = AwareDatetime | date


class ActorType(StrEnum):
    USER = "user"
    DEVICE = "device"
    SYSTEM = "system"
    INTEGRATION = "integration"
    MODEL = "model"


class ActorRef(StrictModel):
    actor_type: ActorType
    actor_id: str = Field(min_length=1, max_length=255)


class DataClass(StrEnum):
    PUBLIC = "public"
    PRIVATE = "private"
    SENSITIVE = "sensitive"
    HIGHLY_SENSITIVE = "highly_sensitive"
    OPERATIONAL_SECRET = "operational_secret"
    DERIVED_SENSITIVE = "derived_sensitive"


class EntityMetadata(StrictModel):
    id: UUID7
    schema_version: int = Field(ge=1)
    created_at: AwareDatetime
    created_by: ActorRef
    last_revised_at: AwareDatetime
    revision: int = Field(ge=1)
    tombstoned_at: AwareDatetime | None = None
    sensitivity: DataClass
    provenance_id: UUID

    @model_validator(mode="after")
    def validate_timeline(self) -> "EntityMetadata":
        if self.last_revised_at < self.created_at:
            raise ValueError("last_revised_at cannot precede created_at")
        if self.tombstoned_at is not None and self.tombstoned_at < self.created_at:
            raise ValueError("tombstoned_at cannot precede created_at")
        return self


class TemporalPrecision(StrEnum):
    EXACT = "exact"
    MINUTE = "minute"
    HOUR = "hour"
    DAY = "day"
    MONTH = "month"
    APPROXIMATE = "approximate"
    UNKNOWN = "unknown"


class TemporalInterval(StrictModel):
    start: InstantOrLocalDate | None = None
    end: InstantOrLocalDate | None = None
    timezone_id: str | None = None
    start_precision: TemporalPrecision = TemporalPrecision.UNKNOWN
    end_precision: TemporalPrecision = TemporalPrecision.UNKNOWN
    all_day_semantics: bool = False

    @model_validator(mode="after")
    def validate_interval(self) -> "TemporalInterval":
        if self.timezone_id is not None:
            try:
                ZoneInfo(self.timezone_id)
            except ZoneInfoNotFoundError as error:
                raise ValueError("timezone_id must be a valid IANA timezone") from error
        if self.all_day_semantics and (
            isinstance(self.start, datetime) or isinstance(self.end, datetime)
        ):
            raise ValueError("all-day intervals must use local dates")
        if self.start is not None and self.end is not None:
            if isinstance(self.start, datetime) != isinstance(self.end, datetime):
                raise ValueError("interval boundaries must use the same temporal type")
            if self.end < self.start:
                raise ValueError("interval end cannot precede start")
        return self


class EpistemicKind(StrEnum):
    OBSERVED = "observed"
    USER_STATED = "user_stated"
    EXTERNALLY_ASSERTED = "externally_asserted"
    INFERRED = "inferred"
    HYPOTHESIZED = "hypothesized"
    EXPERIMENTALLY_SUPPORTED = "experimentally_supported"
    ACCEPTED_INTERPRETATION = "accepted_interpretation"
    RETRACTED = "retracted"


class ConfidenceBand(StrEnum):
    VERY_LOW = "very_low"
    LOW = "low"
    MODERATE = "moderate"
    HIGH = "high"
    VERY_HIGH = "very_high"


class Applicability(StrEnum):
    DIRECT = "direct"
    PARTIAL = "partial"
    INDIRECT = "indirect"
    UNKNOWN = "unknown"


class EpistemicState(StrictModel):
    kind: EpistemicKind
    confidence_band: ConfidenceBand | None = None
    numeric_confidence: float | None = Field(default=None, ge=0, le=1)
    applicability: Applicability = Applicability.UNKNOWN
    last_evaluated_at: AwareDatetime | None = None
    expires_at: AwareDatetime | None = None

    @model_validator(mode="after")
    def validate_evaluation_window(self) -> "EpistemicState":
        if (
            self.last_evaluated_at is not None
            and self.expires_at is not None
            and self.expires_at < self.last_evaluated_at
        ):
            raise ValueError("expires_at cannot precede last_evaluated_at")
        return self


class ExternalRef(StrictModel):
    system: str = Field(min_length=1, max_length=100)
    identifier: str = Field(min_length=1, max_length=500)
    canonical_url: str | None = None


class Provenance(StrictModel):
    id: UUID7
    source_kind: str = Field(min_length=1, max_length=100)
    source_id: str = Field(min_length=1, max_length=500)
    captured_at: AwareDatetime
    actor: ActorRef
    transformation_chain: tuple[str, ...] = ()
    content_hash: str | None = Field(default=None, min_length=16, max_length=128)
    details: Mapping[str, Any] = Field(default_factory=dict)
