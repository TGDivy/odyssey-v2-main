"""Context assembly request and immutable snapshot contracts."""

import re
from datetime import timedelta
from enum import StrEnum

from pydantic import AwareDatetime, Field, field_validator, model_validator

from odyssey.domain.common import UUID7, StrictModel


class ContextDomain(StrEnum):
    CALENDAR = "calendar"
    SLEEP = "sleep"
    TRAINING = "training"
    SEASON = "season"
    LOCATION = "location"
    INTENTS = "intents"
    DECISIONS = "decisions"
    RELATIONSHIPS = "relationships"
    TRAVEL = "travel"
    WEATHER = "weather"


class ContextDomainStatus(StrEnum):
    FRESH = "fresh"
    STALE = "stale"
    MISSING = "missing"
    DENIED = "denied"


class ContextReason(StrEnum):
    SOURCE_AVAILABLE = "SOURCE_AVAILABLE"
    SOURCE_MISSING = "SOURCE_MISSING"
    PERMISSION_DENIED = "PERMISSION_DENIED"
    SOURCE_STALE = "SOURCE_STALE"
    SERVER_OLDER_THAN_CLIENT = "SERVER_OLDER_THAN_CLIENT"


class ContextAssemblyRequest(StrictModel):
    as_of: AwareDatetime
    horizon: str = Field(min_length=2, max_length=30)
    purpose: str = Field(min_length=1, max_length=200)
    requested_domains: tuple[ContextDomain, ...] = Field(min_length=1, max_length=10)
    client_known_freshness: dict[ContextDomain, AwareDatetime] = Field(default_factory=dict)

    @field_validator("horizon")
    @classmethod
    def validate_horizon(cls, value: str) -> str:
        parse_horizon(value)
        return value

    @model_validator(mode="after")
    def validate_domains(self) -> "ContextAssemblyRequest":
        if len(set(self.requested_domains)) != len(self.requested_domains):
            raise ValueError("requested domains must be unique")
        if not set(self.client_known_freshness).issubset(self.requested_domains):
            raise ValueError("client freshness can only name requested domains")
        return self


class ContextFact(StrictModel):
    entity_type: str
    entity_id: UUID7
    canonical_revision: int = Field(ge=1)
    updated_at: AwareDatetime
    content_hash: str = Field(min_length=64, max_length=64)
    document: dict[str, object]


class ContextDomainSnapshot(StrictModel):
    domain: ContextDomain
    status: ContextDomainStatus
    facts: tuple[ContextFact, ...]
    freshest_source_at: AwareDatetime | None = None
    reason_codes: tuple[ContextReason, ...]


class AssembledContextSnapshot(StrictModel):
    id: UUID7
    as_of: AwareDatetime
    built_at: AwareDatetime
    horizon: str
    purpose: str
    domains: tuple[ContextDomainSnapshot, ...]
    source_fact_ids: tuple[UUID7, ...]
    builder_version: str
    content_hash: str = Field(min_length=64, max_length=64)


class ContextAssemblyResponse(StrictModel):
    snapshot: AssembledContextSnapshot
    missing_domains: tuple[ContextDomain, ...]
    denied_domains: tuple[ContextDomain, ...]
    stale_domains: tuple[ContextDomain, ...]


_HORIZON = re.compile(
    r"^P(?:(?P<days>\d+)D)?(?:T(?:(?P<hours>\d+)H)?(?:(?P<minutes>\d+)M)?)?$"
)


def parse_horizon(value: str) -> timedelta:
    match = _HORIZON.fullmatch(value)
    if match is None or not any(match.groupdict().values()):
        raise ValueError("horizon must be an ISO 8601 day/hour/minute duration")
    duration = timedelta(
        days=int(match.group("days") or 0),
        hours=int(match.group("hours") or 0),
        minutes=int(match.group("minutes") or 0),
    )
    if duration <= timedelta(0) or duration > timedelta(days=365):
        raise ValueError("horizon must be greater than zero and no more than 365 days")
    return duration
