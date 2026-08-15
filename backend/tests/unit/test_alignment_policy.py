from datetime import date

from odyssey.domain.alignment import (
    AlignmentBand,
    AlignmentDimension,
    AlignmentReason,
    AlignmentSignal,
    AlignmentSignalKind,
    AlignmentStatus,
    DayAlignmentInput,
    DayAlignmentPolicy,
    LegitimateException,
    day_alignment,
)

DAY = date(2026, 8, 15)
ENABLED = DayAlignmentPolicy(experiment_enabled=True)


def signal(
    dimension: AlignmentDimension,
    kind: AlignmentSignalKind,
    contribution: float,
    confidence: float = 0.9,
) -> AlignmentSignal:
    return AlignmentSignal(
        dimension=dimension,
        kind=kind,
        contribution=contribution,
        confidence=confidence,
    )


def input_day(**overrides: object) -> DayAlignmentInput:
    values: dict[str, object] = {
        "day": DAY,
        "observation_coverage": 0.9,
        "signals": (
            signal(
                AlignmentDimension.INTEGRITY,
                AlignmentSignalKind.ACTION_COMPLETION,
                0.8,
            ),
            signal(
                AlignmentDimension.FOUNDATIONS,
                AlignmentSignalKind.STATE_OBSERVATION,
                0.8,
            ),
            signal(
                AlignmentDimension.PRIMARY_DIRECTION,
                AlignmentSignalKind.USER_REFLECTION,
                0.7,
            ),
            signal(
                AlignmentDimension.RELATIONSHIPS_AND_EXPERIENCE,
                AlignmentSignalKind.RELATIONSHIP_OR_EXPERIENCE,
                0.8,
            ),
            signal(
                AlignmentDimension.RECOVERY_OR_ADAPTATION,
                AlignmentSignalKind.RECOVERY_ADAPTATION,
                0.7,
            ),
        ),
    }
    values.update(overrides)
    return DayAlignmentInput.model_validate(values)


def test_optional_experiment_is_disabled_by_default() -> None:
    result = day_alignment(input_day())

    assert result.status is AlignmentStatus.EXPERIMENT_DISABLED
    assert result.band is None
    assert result.reason_codes == (AlignmentReason.EXPERIMENT_DISABLED,)


def test_action_completions_alone_never_produce_a_band() -> None:
    result = day_alignment(
        input_day(
            signals=(
                signal(
                    AlignmentDimension.INTEGRITY,
                    AlignmentSignalKind.ACTION_COMPLETION,
                    1,
                ),
                signal(
                    AlignmentDimension.PRIMARY_DIRECTION,
                    AlignmentSignalKind.ACTION_COMPLETION,
                    1,
                ),
            )
        ),
        ENABLED,
    )

    assert result.status is AlignmentStatus.INSUFFICIENT_DATA
    assert result.band is None
    assert AlignmentReason.ACTION_COMPLETIONS_ONLY in result.reason_codes


def test_low_coverage_returns_explanation_without_band() -> None:
    result = day_alignment(input_day(observation_coverage=0.2), ENABLED)

    assert result.status is AlignmentStatus.INSUFFICIENT_DATA
    assert result.band is None
    assert AlignmentReason.COVERAGE_INSUFFICIENT in result.reason_codes


def test_varied_coverage_produces_qualitative_band_without_scalar_score() -> None:
    result = day_alignment(input_day(), ENABLED)

    assert result.status is AlignmentStatus.AVAILABLE
    assert result.band is AlignmentBand.ALIGNED_WITH_CURRENT_CONTEXT
    assert len(result.dimensions) == 5
    assert "score" not in result.model_dump()
    assert result.people_comparison_permitted is False
    assert result.canonical_history_affected is False


def test_diminishing_contributions_are_capped() -> None:
    result = day_alignment(
        input_day(
            signals=tuple(
                signal(
                    AlignmentDimension.INTEGRITY,
                    AlignmentSignalKind.USER_REFLECTION
                    if index == 0
                    else AlignmentSignalKind.STATE_OBSERVATION,
                    0.9,
                    1,
                )
                for index in range(20)
            )
        ),
        ENABLED,
    )

    integrity = next(
        item for item in result.dimensions if item.dimension is AlignmentDimension.INTEGRITY
    )
    assert integrity.qualitative_contribution <= 1


def test_legitimate_exception_rewards_adaptation_without_penalty() -> None:
    result = day_alignment(
        input_day(
            legitimate_exceptions=(
                LegitimateException(
                    affected_dimensions=(AlignmentDimension.PRIMARY_DIRECTION,),
                    wise_adaptation=True,
                    adaptation_quality=0.85,
                ),
            )
        ),
        ENABLED,
    )

    primary = next(
        item
        for item in result.dimensions
        if item.dimension is AlignmentDimension.PRIMARY_DIRECTION
    )
    assert primary.exception_adjusted is True
    assert primary.qualitative_contribution >= 0.85
    assert AlignmentReason.LEGITIMATE_EXCEPTION_APPLIED in result.reason_codes


def test_comparison_requires_explicitly_comparable_context() -> None:
    blocked = day_alignment(input_day(comparison_requested=True), ENABLED)
    allowed = day_alignment(
        input_day(
            comparison_requested=True,
            comparable_context_available=True,
        ),
        ENABLED,
    )

    assert blocked.comparison_permitted is False
    assert AlignmentReason.COMPARISON_CONTEXT_NOT_COMPARABLE in blocked.reason_codes
    assert allowed.comparison_permitted is True
