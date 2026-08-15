"""Conservative deterministic policy for promoting personal patterns."""

from enum import StrEnum

from pydantic import Field, model_validator

from odyssey.domain.common import ConfidenceBand, StrictModel


class MissingnessMechanism(StrEnum):
    COMPLETE = "complete"
    MISSING_COMPLETELY_AT_RANDOM = "missing_completely_at_random"
    MISSING_AT_RANDOM = "missing_at_random"
    MISSING_NOT_AT_RANDOM = "missing_not_at_random"
    UNKNOWN = "unknown"


class PatternEvidenceKind(StrEnum):
    ASSOCIATION_ONLY = "association_only"
    QUASI_EXPERIMENTAL = "quasi_experimental"
    EXPERIMENTAL = "experimental"


class PatternPromotion(StrEnum):
    INSUFFICIENT_DATA = "insufficient_data"
    DO_NOT_SURFACE = "do_not_surface"
    SURFACE_AS_OBSERVATIONAL_HYPOTHESIS = "surface_as_observational_hypothesis"
    PROPOSE_PREREGISTERED_EXPERIMENT = "propose_preregistered_experiment"


class PatternReason(StrEnum):
    SAMPLE_TOO_SMALL = "SAMPLE_TOO_SMALL"
    MULTIPLICITY_PENALTY_APPLIED = "MULTIPLICITY_PENALTY_APPLIED"
    MULTIPLICITY_CANNOT_BE_ASSESSED = "MULTIPLICITY_CANNOT_BE_ASSESSED"
    MULTIPLICITY_ADJUSTED_SIGNAL_WEAK = "MULTIPLICITY_ADJUSTED_SIGNAL_WEAK"
    MISSINGNESS_TOO_HIGH = "MISSINGNESS_TOO_HIGH"
    MISSINGNESS_POTENTIALLY_INFORMATIVE = "MISSINGNESS_POTENTIALLY_INFORMATIVE"
    TEMPORAL_ORDER_NOT_ESTABLISHED = "TEMPORAL_ORDER_NOT_ESTABLISHED"
    CONFOUNDERS_UNADDRESSED = "CONFOUNDERS_UNADDRESSED"
    ROBUSTNESS_NOT_ASSESSED = "ROBUSTNESS_NOT_ASSESSED"
    LEAVE_ONE_OUT_UNSTABLE = "LEAVE_ONE_OUT_UNSTABLE"
    CONTEXT_COMPARISON_MISSING = "CONTEXT_COMPARISON_MISSING"
    CONTEXT_EFFECT_UNSTABLE = "CONTEXT_EFFECT_UNSTABLE"
    DATA_QUALITY_LOW = "DATA_QUALITY_LOW"
    ASSOCIATION_NOT_CAUSATION = "ASSOCIATION_NOT_CAUSATION"
    EXPERIMENT_NOT_SAFE = "EXPERIMENT_NOT_SAFE"
    EXPERIMENT_NOT_DECISION_RELEVANT = "EXPERIMENT_NOT_DECISION_RELEVANT"
    PREREGISTRATION_REQUIRED = "PREREGISTRATION_REQUIRED"


class PatternCandidate(StrictModel):
    sample_size: int = Field(ge=0)
    minimum_exploratory_n: int = Field(ge=2)
    tested_hypotheses: int = Field(default=1, ge=1)
    raw_p_value: float | None = Field(default=None, ge=0, le=1)
    missing_fraction: float = Field(ge=0, le=1)
    missingness_mechanism: MissingnessMechanism
    exposure_precedes_outcome: bool
    plausible_confounders: tuple[str, ...] = ()
    adjusted_confounders: tuple[str, ...] = ()
    primary_effect: float
    leave_one_out_effects: tuple[float, ...] = ()
    context_effects: dict[str, float] = Field(default_factory=dict)
    data_quality: ConfidenceBand
    evidence_kind: PatternEvidenceKind
    safe_repeatable: bool
    decision_relevant: bool
    prohibited_experiment_category: bool = False

    @model_validator(mode="after")
    def validate_confounder_names(self) -> "PatternCandidate":
        if not set(self.adjusted_confounders).issubset(self.plausible_confounders):
            raise ValueError("adjusted confounders must be named plausible confounders")
        return self


class PatternPolicy(StrictModel):
    familywise_alpha: float = Field(default=0.05, gt=0, lt=1)
    maximum_missing_fraction: float = Field(default=0.3, ge=0, le=1)
    minimum_direction_stability: float = Field(default=0.8, ge=0.5, le=1)
    policy_version: str = "pattern-promotion-policy-1.0"


class PatternAssessment(StrictModel):
    promotion: PatternPromotion
    reason_codes: tuple[PatternReason, ...]
    adjusted_p_value: float | None = Field(default=None, ge=0, le=1)
    unadjusted_confounders: tuple[str, ...] = ()
    leave_one_out_stable: bool | None = None
    across_contexts_stable: bool | None = None
    policy_version: str


def assess_pattern(
    candidate: PatternCandidate,
    policy: PatternPolicy | None = None,
) -> PatternAssessment:
    active_policy = policy or PatternPolicy()
    reasons: list[PatternReason] = []

    if candidate.sample_size < candidate.minimum_exploratory_n:
        return _result(
            PatternPromotion.INSUFFICIENT_DATA,
            reasons=[PatternReason.SAMPLE_TOO_SMALL],
            candidate=candidate,
            policy=active_policy,
        )

    adjusted_p_value = candidate.raw_p_value
    if candidate.tested_hypotheses > 1:
        reasons.append(PatternReason.MULTIPLICITY_PENALTY_APPLIED)
        if candidate.raw_p_value is None:
            reasons.append(PatternReason.MULTIPLICITY_CANNOT_BE_ASSESSED)
            return _result(
                PatternPromotion.DO_NOT_SURFACE,
                reasons=reasons,
                candidate=candidate,
                policy=active_policy,
            )
        adjusted_p_value = min(1.0, candidate.raw_p_value * candidate.tested_hypotheses)
        if adjusted_p_value > active_policy.familywise_alpha:
            reasons.append(PatternReason.MULTIPLICITY_ADJUSTED_SIGNAL_WEAK)
            return _result(
                PatternPromotion.DO_NOT_SURFACE,
                reasons=reasons,
                candidate=candidate,
                policy=active_policy,
                adjusted_p_value=adjusted_p_value,
            )

    if candidate.missing_fraction > active_policy.maximum_missing_fraction:
        reasons.append(PatternReason.MISSINGNESS_TOO_HIGH)
        return _result(
            PatternPromotion.DO_NOT_SURFACE,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
        )
    if candidate.missingness_mechanism in {
        MissingnessMechanism.MISSING_NOT_AT_RANDOM,
        MissingnessMechanism.UNKNOWN,
    } and candidate.missing_fraction > 0:
        reasons.append(PatternReason.MISSINGNESS_POTENTIALLY_INFORMATIVE)
        return _result(
            PatternPromotion.DO_NOT_SURFACE,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
        )
    if not candidate.exposure_precedes_outcome:
        reasons.append(PatternReason.TEMPORAL_ORDER_NOT_ESTABLISHED)
        return _result(
            PatternPromotion.DO_NOT_SURFACE,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
        )
    if candidate.data_quality in {ConfidenceBand.VERY_LOW, ConfidenceBand.LOW}:
        reasons.append(PatternReason.DATA_QUALITY_LOW)
        return _result(
            PatternPromotion.DO_NOT_SURFACE,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
        )

    leave_one_out_stable = _effects_stable(
        candidate.primary_effect,
        candidate.leave_one_out_effects,
        active_policy.minimum_direction_stability,
    )
    if leave_one_out_stable is None:
        reasons.append(PatternReason.ROBUSTNESS_NOT_ASSESSED)
        return _result(
            PatternPromotion.DO_NOT_SURFACE,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
        )
    if not leave_one_out_stable:
        reasons.append(PatternReason.LEAVE_ONE_OUT_UNSTABLE)
        return _result(
            PatternPromotion.DO_NOT_SURFACE,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
            leave_one_out_stable=False,
        )

    across_contexts_stable = _effects_stable(
        candidate.primary_effect,
        tuple(candidate.context_effects.values()),
        active_policy.minimum_direction_stability,
    )
    if across_contexts_stable is None:
        reasons.append(PatternReason.CONTEXT_COMPARISON_MISSING)
        return _result(
            PatternPromotion.DO_NOT_SURFACE,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
            leave_one_out_stable=True,
        )
    if not across_contexts_stable:
        reasons.append(PatternReason.CONTEXT_EFFECT_UNSTABLE)
        return _result(
            PatternPromotion.DO_NOT_SURFACE,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
            leave_one_out_stable=True,
            across_contexts_stable=False,
        )

    unadjusted_confounders = tuple(
        confounder
        for confounder in candidate.plausible_confounders
        if confounder not in candidate.adjusted_confounders
    )
    if unadjusted_confounders:
        reasons.append(PatternReason.CONFOUNDERS_UNADDRESSED)
    if candidate.evidence_kind is PatternEvidenceKind.ASSOCIATION_ONLY or unadjusted_confounders:
        reasons.append(PatternReason.ASSOCIATION_NOT_CAUSATION)
        return _result(
            PatternPromotion.SURFACE_AS_OBSERVATIONAL_HYPOTHESIS,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
            unadjusted_confounders=unadjusted_confounders,
            leave_one_out_stable=True,
            across_contexts_stable=True,
        )

    if not candidate.safe_repeatable or candidate.prohibited_experiment_category:
        reasons.append(PatternReason.EXPERIMENT_NOT_SAFE)
        return _result(
            PatternPromotion.SURFACE_AS_OBSERVATIONAL_HYPOTHESIS,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
            leave_one_out_stable=True,
            across_contexts_stable=True,
        )
    if not candidate.decision_relevant:
        reasons.append(PatternReason.EXPERIMENT_NOT_DECISION_RELEVANT)
        return _result(
            PatternPromotion.SURFACE_AS_OBSERVATIONAL_HYPOTHESIS,
            reasons=reasons,
            candidate=candidate,
            policy=active_policy,
            adjusted_p_value=adjusted_p_value,
            leave_one_out_stable=True,
            across_contexts_stable=True,
        )

    reasons.append(PatternReason.PREREGISTRATION_REQUIRED)
    return _result(
        PatternPromotion.PROPOSE_PREREGISTERED_EXPERIMENT,
        reasons=reasons,
        candidate=candidate,
        policy=active_policy,
        adjusted_p_value=adjusted_p_value,
        leave_one_out_stable=True,
        across_contexts_stable=True,
    )


def _effects_stable(
    primary: float,
    effects: tuple[float, ...],
    threshold: float,
) -> bool | None:
    if not effects or primary == 0:
        return None
    primary_positive = primary > 0
    matching = sum((effect > 0) is primary_positive for effect in effects if effect != 0)
    return matching / len(effects) >= threshold


def _result(
    promotion: PatternPromotion,
    *,
    reasons: list[PatternReason],
    candidate: PatternCandidate,
    policy: PatternPolicy,
    adjusted_p_value: float | None = None,
    unadjusted_confounders: tuple[str, ...] = (),
    leave_one_out_stable: bool | None = None,
    across_contexts_stable: bool | None = None,
) -> PatternAssessment:
    return PatternAssessment(
        promotion=promotion,
        reason_codes=tuple(dict.fromkeys(reasons)),
        adjusted_p_value=adjusted_p_value,
        unadjusted_confounders=unadjusted_confounders,
        leave_one_out_stable=leave_one_out_stable,
        across_contexts_stable=across_contexts_stable,
        policy_version=policy.policy_version,
    )
