"""Decision, option, recommendation, choice, and consequence contracts."""

from enum import StrEnum

from pydantic import AwareDatetime, Field, model_validator

from odyssey.domain.common import (
    UUID7,
    ConfidenceBand,
    EntityMetadata,
    StrictModel,
    TemporalInterval,
)


class DecisionStatus(StrEnum):
    CANDIDATE = "candidate"
    ACTIVE = "active"
    DEFERRED = "deferred"
    CHOSEN = "chosen"
    ENACTED = "enacted"
    CLOSED = "closed"
    SUPERSEDED = "superseded"


class Stakes(StrEnum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"


class Reversibility(StrEnum):
    REVERSIBLE = "reversible"
    COSTLY_TO_REVERSE = "costly_to_reverse"
    IRREVERSIBLE = "irreversible"
    UNKNOWN = "unknown"


class Externality(StrEnum):
    PRIVATE = "private"
    AFFECTS_KNOWN_PEOPLE = "affects_known_people"
    PUBLIC_OR_CONTRACTUAL = "public_or_contractual"


class DecisionOwner(StrEnum):
    USER = "user"
    DELEGATED_WITHIN_SCOPE = "delegated_within_scope"


class Decision(StrictModel):
    metadata: EntityMetadata
    question: str = Field(min_length=1, max_length=4_000)
    status: DecisionStatus
    detected_at: AwareDatetime
    decision_window: TemporalInterval
    stakes: Stakes
    importance_dimensions: tuple[str, ...] = ()
    reversibility: Reversibility
    externality: Externality
    urgency: str
    current_context_snapshot_id: UUID7
    charter_and_season_refs: tuple[UUID7, ...]
    option_ids: tuple[UUID7, ...] = ()
    recommendation_id: UUID7 | None = None
    missing_information: tuple[str, ...] = ()
    decision_owner: DecisionOwner = DecisionOwner.USER
    follow_up_plan: str | None = None


class ConsequenceDirection(StrEnum):
    BENEFICIAL = "beneficial"
    HARMFUL = "harmful"
    MIXED = "mixed"
    NEUTRAL = "neutral"


class OptionConsequence(StrictModel):
    outcome_type: str
    direction: ConsequenceDirection
    magnitude_band: str
    time_horizon: str
    probability_or_uncertainty: str | None = None
    evidence_refs: tuple[UUID7, ...] = ()
    assumptions: tuple[str, ...] = ()


class DecisionOption(StrictModel):
    metadata: EntityMetadata
    decision_id: UUID7
    label: str = Field(min_length=1, max_length=500)
    description: str = Field(min_length=1, max_length=8_000)
    prerequisites: tuple[str, ...] = ()
    consequences: tuple[OptionConsequence, ...] = ()
    opportunity_costs: tuple[str, ...] = ()
    value_alignment: tuple[str, ...] = ()
    constraint_violations: tuple[str, ...] = ()
    reversibility: Reversibility


class GenerationMethod(StrEnum):
    DETERMINISTIC = "deterministic"
    HYBRID = "hybrid"
    MODEL = "model"


class RecommendationReason(StrictModel):
    code: str
    explanation: str
    source_refs: tuple[UUID7, ...] = ()


class Recommendation(StrictModel):
    metadata: EntityMetadata
    decision_id: UUID7 | None = None
    intervention_opportunity_id: UUID7 | None = None
    recommended_option_or_action: str = Field(min_length=1, max_length=4_000)
    rationale_short: str = Field(min_length=1, max_length=1_000)
    rationale_structured: tuple[RecommendationReason, ...]
    counterarguments: tuple[str, ...] = ()
    material_uncertainties: tuple[str, ...] = ()
    what_would_change_this: tuple[str, ...] = ()
    evidence_pack_id: UUID7
    confidence_band: ConfidenceBand
    generation_method: GenerationMethod
    policy_result_id: UUID7

    @model_validator(mode="after")
    def validate_subject(self) -> "Recommendation":
        if self.decision_id is None and self.intervention_opportunity_id is None:
            raise ValueError("recommendation must reference a decision or intervention opportunity")
        return self


class ChoiceSource(StrEnum):
    EXPLICIT_USER = "explicit_user"
    STANDING_AUTHORITY = "standing_authority"
    IMPORTED_EXTERNAL = "imported_external"


class Choice(StrictModel):
    metadata: EntityMetadata
    decision_id: UUID7
    selected_option_id: UUID7 | None = None
    adapted_action: str | None = None
    chosen_at: AwareDatetime
    rationale_optional: str | None = None
    confidence_optional: ConfidenceBand | None = None
    source: ChoiceSource
    supersedes_choice_id: UUID7 | None = None

    @model_validator(mode="after")
    def validate_selection(self) -> "Choice":
        if self.selected_option_id is None and not self.adapted_action:
            raise ValueError("choice requires a selected option or adapted action")
        return self


class AccumulationModel(StrEnum):
    NONE = "none"
    COUNT = "count"
    DOSE = "dose"
    DEBT = "debt"
    THRESHOLD = "threshold"
    CUSTOM = "custom"


class ConsequenceCandidate(StrictModel):
    id: UUID7
    source_action_or_option: UUID7
    affected_state_or_landmark: str
    causal_path: tuple[str, ...]
    direction: ConsequenceDirection
    expected_magnitude_band: str
    uncertainty_band: ConfidenceBand
    earliest_effect: AwareDatetime
    latest_relevant_effect: AwareDatetime | None = None
    accumulation_model: AccumulationModel
    decay_model: str | None = None
    assumptions: tuple[str, ...] = ()
    personal_evidence_refs: tuple[UUID7, ...] = ()
    population_evidence_refs: tuple[UUID7, ...] = ()
    rule_or_model_version: str
    causal_status: str

    @model_validator(mode="after")
    def validate_effect_window(self) -> "ConsequenceCandidate":
        if (
            self.latest_relevant_effect is not None
            and self.latest_relevant_effect < self.earliest_effect
        ):
            raise ValueError("latest relevant effect cannot precede earliest effect")
        return self
