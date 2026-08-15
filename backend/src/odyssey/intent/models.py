"""Intent, opportunity, policy, and intervention contracts."""

from enum import StrEnum

from pydantic import AwareDatetime, Field, model_validator

from odyssey.auth.models import AuthorityLevel
from odyssey.domain.common import (
    UUID7,
    ConfidenceBand,
    EntityMetadata,
    StrictModel,
    TemporalInterval,
)


class OpportunityDefinition(StrictModel):
    predicates: tuple[str, ...]
    ideal_context: tuple[str, ...] = ()
    disqualifiers: tuple[str, ...] = ()


class IntentTemporalPolicy(StrictModel):
    earliest: AwareDatetime
    deadline: AwareDatetime | None = None
    recurrence: str | None = None
    cooldown: str | None = None
    expiry: AwareDatetime

    @model_validator(mode="after")
    def validate_window(self) -> "IntentTemporalPolicy":
        if self.deadline is not None and self.deadline < self.earliest:
            raise ValueError("deadline cannot precede earliest opportunity")
        if self.expiry < (self.deadline or self.earliest):
            raise ValueError("expiry cannot precede the opportunity window")
        return self


class Intent(StrictModel):
    metadata: EntityMetadata
    statement: str = Field(min_length=1, max_length=4_000)
    serves_direction_ids: tuple[UUID7, ...] = ()
    desired_behavior_or_state: str
    opportunity_definition: OpportunityDefinition
    temporal_policy: IntentTemporalPolicy
    importance: str
    default_intervention_options: tuple[str, ...]
    fallback_behavior: str
    authority_level: AuthorityLevel
    status: str


class InterventionPolicyStatus(StrEnum):
    PENDING = "pending"
    SUPPRESS = "suppress"
    AMBIENT = "ambient"
    VISIBLE = "visible"
    EXPIRED = "expired"


class CandidateIntervention(StrictModel):
    kind: str
    semantic_key: str
    expected_effectiveness: float = Field(ge=0, le=1)


class InterventionOpportunity(StrictModel):
    metadata: EntityMetadata
    intent_id: UUID7
    context_snapshot_id: UUID7
    detected_at: AwareDatetime
    valid_interval: TemporalInterval
    trigger_sources: tuple[str, ...]
    opportunity_confidence: ConfidenceBand
    expected_benefit: float
    expected_interruption_cost: float
    urgency: str
    candidate_interventions: tuple[CandidateIntervention, ...]
    prior_burden: float = Field(ge=0)
    policy_status: InterventionPolicyStatus = InterventionPolicyStatus.PENDING
    policy_reasons: tuple[str, ...] = ()


class InterventionKind(StrEnum):
    IN_APP = "in_app"
    WIDGET = "widget"
    WATCH = "watch"
    LOCAL_NOTIFICATION = "local_notification"
    REMOTE_NOTIFICATION = "remote_notification"
    LIVE_ACTIVITY = "live_activity"
    ALARM = "alarm"
    DIGEST = "digest"


class Intervention(StrictModel):
    metadata: EntityMetadata
    opportunity_id: UUID7
    kind: InterventionKind
    content_template_version: str
    rendered_content: str
    scheduled_at: AwareDatetime | None = None
    delivered_at: AwareDatetime | None = None
    expiry: AwareDatetime
    redaction_level: str
    action_buttons: tuple[str, ...] = ()
    delivery_receipt: str | None = None
    interaction: str | None = None
    outcome_refs: tuple[UUID7, ...] = ()

    @model_validator(mode="after")
    def validate_delivery_timeline(self) -> "Intervention":
        if self.scheduled_at is not None and self.scheduled_at > self.expiry:
            raise ValueError("intervention cannot be scheduled after expiry")
        if self.delivered_at is not None and self.delivered_at > self.expiry:
            raise ValueError("expired intervention cannot be delivered")
        return self
