"""Versioned Charter, life-stage, season, direction, and action contracts."""

from datetime import date
from enum import StrEnum

from pydantic import AwareDatetime, Field, model_validator

from odyssey.domain.common import UUID7, EntityMetadata, StrictModel, TemporalInterval


class CharterValue(StrictModel):
    id: UUID7
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(min_length=1, max_length=4_000)
    positive_expression: str = Field(min_length=1, max_length=2_000)
    anti_value_or_failure_mode: str | None = Field(default=None, max_length=2_000)


class CharterVersion(StrictModel):
    metadata: EntityMetadata
    charter_id: UUID7
    version_number: int = Field(ge=1)
    effective_interval: TemporalInterval
    values: tuple[CharterValue, ...]
    responsibilities: tuple[str, ...]
    desired_ways_of_being: tuple[str, ...]
    non_negotiable_boundaries: tuple[str, ...]
    anti_optimization_statements: tuple[str, ...]
    interpretation_notes: str = ""
    supersedes_version_id: UUID7 | None = None
    accepted_at: AwareDatetime


class LifeStageVersion(StrictModel):
    metadata: EntityMetadata
    stage_id: UUID7
    effective_interval: TemporalInterval
    title: str = Field(min_length=1, max_length=200)
    career_context: str = ""
    partnership_family_context: str = ""
    health_capability_context: str = ""
    geography_context: str = ""
    financial_context: str = ""
    care_responsibilities: tuple[str, ...] = ()
    identity_transitions: tuple[str, ...] = ()
    horizons: tuple[str, ...] = ()
    uncertainties: tuple[str, ...] = ()


class SeasonStatus(StrEnum):
    DRAFT = "draft"
    CALIBRATION = "calibration"
    ACTIVE = "active"
    TRANSITIONING = "transitioning"
    COMPLETE = "complete"
    ABANDONED = "abandoned"


class DirectionRole(StrEnum):
    PRIMARY = "primary"
    FOUNDATION = "foundation"
    MAINTENANCE = "maintenance"
    EXPLORATION = "exploration"
    DORMANT = "dormant"


class AllocationBand(StrEnum):
    MINIMAL = "minimal"
    LOW = "low"
    MODERATE = "moderate"
    HIGH = "high"
    DOMINANT = "dominant"


class SeasonPortfolioItem(StrictModel):
    direction_id: UUID7
    role: DirectionRole
    allocation_band: AllocationBand
    minimum_viable_commitment: str | None = None
    sacrifice_limit: str | None = None
    success_signals: tuple[str, ...] = ()
    review_date: date | None = None


class Season(StrictModel):
    metadata: EntityMetadata
    title: str = Field(min_length=1, max_length=200)
    effective_interval: TemporalInterval
    status: SeasonStatus
    rationale: str = Field(min_length=1, max_length=8_000)
    triggering_context: tuple[str, ...] = ()
    portfolio_items: tuple[SeasonPortfolioItem, ...]
    constraints: tuple[str, ...] = ()
    protected_experiences: tuple[str, ...] = ()
    known_tradeoffs: tuple[str, ...] = ()
    transition_notes: str | None = None
    primary_override_explanation: str | None = None

    @model_validator(mode="after")
    def validate_primary_limit(self) -> "Season":
        primary_count = sum(item.role is DirectionRole.PRIMARY for item in self.portfolio_items)
        if primary_count > 2 and not self.primary_override_explanation:
            raise ValueError("more than two primary directions requires an explanation")
        if len({item.direction_id for item in self.portfolio_items}) != len(self.portfolio_items):
            raise ValueError("a direction can appear only once in a season portfolio")
        return self


class Direction(StrictModel):
    metadata: EntityMetadata
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(min_length=1, max_length=8_000)
    serves_charter_elements: tuple[UUID7, ...] = ()
    horizon: str
    desired_change: str
    constraints: tuple[str, ...] = ()
    status: str


class Commitment(StrictModel):
    metadata: EntityMetadata
    statement: str = Field(min_length=1, max_length=4_000)
    parties: tuple[UUID7, ...] = ()
    effective_interval: TemporalInterval
    importance: str
    reversibility: str
    externality: str
    renegotiation_terms: str | None = None
    fulfillment_state: str
    linked_direction_ids: tuple[UUID7, ...] = ()


class ActionStatus(StrEnum):
    PROPOSED = "proposed"
    PREPARED = "prepared"
    SCHEDULED = "scheduled"
    STARTED = "started"
    COMPLETED = "completed"
    SKIPPED = "skipped"
    CANCELLED = "cancelled"
    FAILED = "failed"
    SUPERSEDED = "superseded"


class Action(StrictModel):
    metadata: EntityMetadata
    action_type: str
    description: str = Field(min_length=1, max_length=4_000)
    status: ActionStatus
    planned_interval: TemporalInterval | None = None
    actual_interval: TemporalInterval | None = None
    linked_decision_id: UUID7 | None = None
    linked_intent_id: UUID7 | None = None
    external_system_ref: str | None = None
    completion_evidence: tuple[UUID7, ...] = ()
    effort_estimate: str | None = None
    outcome_ids: tuple[UUID7, ...] = ()


class Project(StrictModel):
    metadata: EntityMetadata
    title: str = Field(min_length=1, max_length=200)
    description: str = ""
    direction_ids: tuple[UUID7, ...] = ()
    action_ids: tuple[UUID7, ...] = ()
    completion_condition: str = Field(min_length=1, max_length=4_000)
    status: str
