from odyssey.domain.common import ConfidenceBand
from odyssey.evidence.pattern_policy import (
    MissingnessMechanism,
    PatternCandidate,
    PatternEvidenceKind,
    PatternPromotion,
    PatternReason,
    assess_pattern,
)


def candidate(**overrides: object) -> PatternCandidate:
    values: dict[str, object] = {
        "sample_size": 40,
        "minimum_exploratory_n": 20,
        "tested_hypotheses": 1,
        "raw_p_value": 0.01,
        "missing_fraction": 0.05,
        "missingness_mechanism": MissingnessMechanism.MISSING_AT_RANDOM,
        "exposure_precedes_outcome": True,
        "plausible_confounders": ("weekday",),
        "adjusted_confounders": ("weekday",),
        "primary_effect": 0.4,
        "leave_one_out_effects": (0.35, 0.42, 0.38, 0.41, 0.36),
        "context_effects": {"workdays": 0.35, "weekends": 0.2},
        "data_quality": ConfidenceBand.HIGH,
        "evidence_kind": PatternEvidenceKind.QUASI_EXPERIMENTAL,
        "safe_repeatable": True,
        "decision_relevant": True,
    }
    values.update(overrides)
    return PatternCandidate.model_validate(values)


def test_small_sample_is_insufficient_not_a_negative_finding() -> None:
    result = assess_pattern(candidate(sample_size=10))

    assert result.promotion is PatternPromotion.INSUFFICIENT_DATA
    assert result.reason_codes == (PatternReason.SAMPLE_TOO_SMALL,)


def test_multiplicity_uses_bonferroni_and_suppresses_weak_signal() -> None:
    result = assess_pattern(
        candidate(tested_hypotheses=20, raw_p_value=0.01)
    )

    assert result.promotion is PatternPromotion.DO_NOT_SURFACE
    assert result.adjusted_p_value == 0.2
    assert result.reason_codes == (
        PatternReason.MULTIPLICITY_PENALTY_APPLIED,
        PatternReason.MULTIPLICITY_ADJUSTED_SIGNAL_WEAK,
    )


def test_unknown_informative_missingness_is_not_promoted() -> None:
    result = assess_pattern(
        candidate(
            missing_fraction=0.1,
            missingness_mechanism=MissingnessMechanism.UNKNOWN,
        )
    )

    assert result.promotion is PatternPromotion.DO_NOT_SURFACE
    assert PatternReason.MISSINGNESS_POTENTIALLY_INFORMATIVE in result.reason_codes


def test_temporal_order_is_required() -> None:
    result = assess_pattern(candidate(exposure_precedes_outcome=False))

    assert result.promotion is PatternPromotion.DO_NOT_SURFACE
    assert PatternReason.TEMPORAL_ORDER_NOT_ESTABLISHED in result.reason_codes


def test_leave_one_out_direction_instability_is_not_surfaced() -> None:
    result = assess_pattern(
        candidate(leave_one_out_effects=(0.4, -0.3, -0.2, 0.1, -0.1))
    )

    assert result.promotion is PatternPromotion.DO_NOT_SURFACE
    assert result.leave_one_out_stable is False


def test_cross_context_instability_is_not_surfaced() -> None:
    result = assess_pattern(
        candidate(context_effects={"workdays": 0.4, "weekends": -0.4})
    )

    assert result.promotion is PatternPromotion.DO_NOT_SURFACE
    assert result.across_contexts_stable is False


def test_observational_pattern_is_labeled_hypothesis_and_lists_confounders() -> None:
    result = assess_pattern(
        candidate(
            adjusted_confounders=(),
            evidence_kind=PatternEvidenceKind.ASSOCIATION_ONLY,
        )
    )

    assert result.promotion is PatternPromotion.SURFACE_AS_OBSERVATIONAL_HYPOTHESIS
    assert result.unadjusted_confounders == ("weekday",)
    assert PatternReason.ASSOCIATION_NOT_CAUSATION in result.reason_codes


def test_safe_relevant_nonobservational_pattern_proposes_preregistered_experiment() -> None:
    result = assess_pattern(candidate())

    assert result.promotion is PatternPromotion.PROPOSE_PREREGISTERED_EXPERIMENT
    assert result.reason_codes == (PatternReason.PREREGISTRATION_REQUIRED,)
    assert result.policy_version == "pattern-promotion-policy-1.0"


def test_unsafe_category_cannot_be_promoted_to_experiment() -> None:
    result = assess_pattern(candidate(prohibited_experiment_category=True))

    assert result.promotion is PatternPromotion.SURFACE_AS_OBSERVATIONAL_HYPOTHESIS
    assert PatternReason.EXPERIMENT_NOT_SAFE in result.reason_codes
