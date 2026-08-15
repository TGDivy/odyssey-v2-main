"""Standing authorization and deterministic policy-decision contracts."""

from enum import IntEnum, StrEnum

from pydantic import AwareDatetime

from odyssey.domain.common import UUID7, EntityMetadata, StrictModel, TemporalInterval


class AuthorityLevel(IntEnum):
    OBSERVE = 0
    INFORM = 1
    RECOMMEND = 2
    PREPARE = 3
    EXECUTE_REVERSIBLE = 4
    COMMIT_EXTERNAL = 5


class RevocationState(StrEnum):
    ACTIVE = "active"
    SUSPENDED = "suspended"
    REVOKED = "revoked"
    EXPIRED = "expired"


class StandingAuthorization(StrictModel):
    metadata: EntityMetadata
    capability: str
    action_class: str
    resource_scope: str
    max_frequency_or_amount: str | None = None
    valid_interval: TemporalInterval
    authority_level: AuthorityLevel
    required_conditions: tuple[str, ...] = ()
    prohibited_conditions: tuple[str, ...] = ()
    revocation_state: RevocationState
    last_reviewed_at: AwareDatetime


class PolicyOutcome(StrEnum):
    ALLOW = "allow"
    REQUIRE_CONFIRMATION = "require_confirmation"
    DENY = "deny"
    DEFER = "defer"


class PolicyDecision(StrictModel):
    id: UUID7
    requested_action: str
    context_snapshot_id: UUID7
    authority_required: AuthorityLevel
    authorization_refs: tuple[UUID7, ...] = ()
    risk_factors: tuple[str, ...] = ()
    decision: PolicyOutcome
    explanation: str
    policy_version: str
