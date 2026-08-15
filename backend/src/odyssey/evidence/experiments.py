"""Conservative N-of-1 hypothesis and experiment contracts."""

from enum import StrEnum

from odyssey.domain.common import UUID7, EntityMetadata, StrictModel, TemporalInterval


class HypothesisStatus(StrEnum):
    EXPLORATORY = "exploratory"
    REVIEW = "review"
    EXPERIMENT_ELIGIBLE = "experiment_eligible"
    REJECTED = "rejected"
    SUPPORTED = "supported"
    INCONCLUSIVE = "inconclusive"
    SUPERSEDED = "superseded"


class Hypothesis(StrictModel):
    metadata: EntityMetadata
    statement: str
    domain: str
    proposed_causal_direction: str | None = None
    supporting_observations: tuple[UUID7, ...] = ()
    counterevidence: tuple[UUID7, ...] = ()
    plausible_confounders: tuple[str, ...] = ()
    prior_plausibility: str
    status: HypothesisStatus


class PersonalExperiment(StrictModel):
    metadata: EntityMetadata
    title: str
    preregistration: str
    eligibility_criteria: tuple[str, ...]
    intervention_conditions: tuple[str, ...]
    assignment_method: str
    unit_of_randomization: str
    washout_or_carryover_policy: str | None = None
    primary_outcome: str
    secondary_outcomes: tuple[str, ...] = ()
    measurement_plan: str
    sample_or_cycle_target: int
    analysis_plan: str
    multiple_testing_policy: str
    stop_rules: tuple[str, ...]
    adverse_event_policy: str
    interval: TemporalInterval
    status: str
    result_id: UUID7 | None = None


class ExperimentResult(StrictModel):
    metadata: EntityMetadata
    experiment_id: UUID7
    adherence: str
    missingness: str
    effect_estimate: str
    interval_or_uncertainty: str
    sensitivity_analyses: tuple[str, ...] = ()
    protocol_deviations: tuple[str, ...] = ()
    interpretation: str
    replication_state: str
    decision_implications: tuple[str, ...] = ()
