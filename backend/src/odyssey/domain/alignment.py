"""Optional qualitative day-alignment experiment policy."""

from datetime import date
from enum import StrEnum
from typing import Literal

from pydantic import Field

from odyssey.domain.common import StrictModel


class AlignmentDimension(StrEnum):
    INTEGRITY = "integrity"
    FOUNDATIONS = "foundations"
    PRIMARY_DIRECTION = "primary_direction"
    RELATIONSHIPS_AND_EXPERIENCE = "relationships_and_experience"
    RECOVERY_OR_ADAPTATION = "recovery_or_adaptation"


class AlignmentSignalKind(StrEnum):
    ACTION_COMPLETION = "action_completion"
    STATE_OBSERVATION = "state_observation"
    USER_REFLECTION = "user_reflection"
    CONTEXT = "context"
    RELATIONSHIP_OR_EXPERIENCE = "relationship_or_experience"
    RECOVERY_ADAPTATION = "recovery_adaptation"


class AlignmentStatus(StrEnum):
    EXPERIMENT_DISABLED = "experiment_disabled"
    INSUFFICIENT_DATA = "insufficient_data"
    AVAILABLE = "available"


class AlignmentBand(StrEnum):
    ALIGNED_WITH_CURRENT_CONTEXT = "aligned_with_current_context"
    MIXED_OR_UNCERTAIN = "mixed_or_uncertain"
    CONSTRAINED_OR_ADAPTING = "constrained_or_adapting"


class AlignmentUncertainty(StrEnum):
    LOW = "low"
    MODERATE = "moderate"
    HIGH = "high"


class AlignmentReason(StrEnum):
    EXPERIMENT_DISABLED = "EXPERIMENT_DISABLED"
    COVERAGE_INSUFFICIENT = "COVERAGE_INSUFFICIENT"
    ACTION_COMPLETIONS_ONLY = "ACTION_COMPLETIONS_ONLY"
    TOO_FEW_SIGNAL_TYPES = "TOO_FEW_SIGNAL_TYPES"
    LEGITIMATE_EXCEPTION_APPLIED = "LEGITIMATE_EXCEPTION_APPLIED"
    QUALITATIVE_INDICATOR_AVAILABLE = "QUALITATIVE_INDICATOR_AVAILABLE"
    COMPARISON_CONTEXT_NOT_COMPARABLE = "COMPARISON_CONTEXT_NOT_COMPARABLE"


class AlignmentSignal(StrictModel):
    dimension: AlignmentDimension
    kind: AlignmentSignalKind
    contribution: float = Field(ge=0, le=1)
    confidence: float = Field(ge=0, le=1)


class LegitimateException(StrictModel):
    affected_dimensions: tuple[AlignmentDimension, ...]
    wise_adaptation: bool
    adaptation_quality: float = Field(default=0, ge=0, le=1)


class DayAlignmentInput(StrictModel):
    day: date
    signals: tuple[AlignmentSignal, ...]
    legitimate_exceptions: tuple[LegitimateException, ...] = ()
    observation_coverage: float = Field(ge=0, le=1)
    comparable_context_available: bool = False
    comparison_requested: bool = False


class DayAlignmentPolicy(StrictModel):
    experiment_enabled: bool = False
    minimum_observation_coverage: float = Field(default=0.6, ge=0, le=1)
    minimum_signal_kinds: int = Field(default=2, ge=2)
    policy_version: str = "day-alignment-policy-1.0"


class DimensionAssessment(StrictModel):
    dimension: AlignmentDimension
    qualitative_contribution: float = Field(ge=0, le=1)
    evidence_count: int = Field(ge=0)
    exception_adjusted: bool = False


class DayAlignmentResult(StrictModel):
    status: AlignmentStatus
    band: AlignmentBand | None = None
    dimensions: tuple[DimensionAssessment, ...] = ()
    explanation: tuple[str, ...]
    uncertainty: AlignmentUncertainty
    reason_codes: tuple[AlignmentReason, ...]
    comparison_permitted: bool = False
    people_comparison_permitted: Literal[False] = False
    canonical_history_affected: Literal[False] = False
    policy_version: str


def day_alignment(
    day: DayAlignmentInput,
    policy: DayAlignmentPolicy | None = None,
) -> DayAlignmentResult:
    active_policy = policy or DayAlignmentPolicy()
    if not active_policy.experiment_enabled:
        return DayAlignmentResult(
            status=AlignmentStatus.EXPERIMENT_DISABLED,
            explanation=("The optional day-alignment experiment is disabled.",),
            uncertainty=AlignmentUncertainty.HIGH,
            reason_codes=(AlignmentReason.EXPERIMENT_DISABLED,),
            policy_version=active_policy.policy_version,
        )

    reason_codes: list[AlignmentReason] = []
    signal_kinds = {signal.kind for signal in day.signals}
    non_completion_signal = any(
        signal.kind is not AlignmentSignalKind.ACTION_COMPLETION for signal in day.signals
    )
    if day.observation_coverage < active_policy.minimum_observation_coverage:
        reason_codes.append(AlignmentReason.COVERAGE_INSUFFICIENT)
    if day.signals and not non_completion_signal:
        reason_codes.append(AlignmentReason.ACTION_COMPLETIONS_ONLY)
    if len(signal_kinds) < active_policy.minimum_signal_kinds:
        reason_codes.append(AlignmentReason.TOO_FEW_SIGNAL_TYPES)
    if reason_codes:
        return DayAlignmentResult(
            status=AlignmentStatus.INSUFFICIENT_DATA,
            explanation=(
                "There is not enough varied, reliable context for a day-alignment band.",
                "The day remains describable without turning missing data into a judgment.",
            ),
            uncertainty=AlignmentUncertainty.HIGH,
            reason_codes=tuple(reason_codes),
            policy_version=active_policy.policy_version,
        )

    dimensions = tuple(
        _assess_dimension(dimension, day.signals, day.legitimate_exceptions)
        for dimension in AlignmentDimension
    )
    if any(item.exception_adjusted for item in dimensions):
        reason_codes.append(AlignmentReason.LEGITIMATE_EXCEPTION_APPLIED)
    reason_codes.append(AlignmentReason.QUALITATIVE_INDICATOR_AVAILABLE)
    comparison_permitted = day.comparison_requested and day.comparable_context_available
    if day.comparison_requested and not comparison_permitted:
        reason_codes.append(AlignmentReason.COMPARISON_CONTEXT_NOT_COMPARABLE)

    mean_contribution = sum(item.qualitative_contribution for item in dimensions) / len(
        dimensions
    )
    minimum_contribution = min(item.qualitative_contribution for item in dimensions)
    if mean_contribution >= 0.65 and minimum_contribution >= 0.45:
        band = AlignmentBand.ALIGNED_WITH_CURRENT_CONTEXT
    elif mean_contribution >= 0.4:
        band = AlignmentBand.MIXED_OR_UNCERTAIN
    else:
        band = AlignmentBand.CONSTRAINED_OR_ADAPTING

    weighted_confidence = sum(
        signal.confidence * signal.contribution for signal in day.signals
    ) / max(sum(signal.contribution for signal in day.signals), 1)
    uncertainty_value = 1 - day.observation_coverage * weighted_confidence
    if uncertainty_value <= 0.25:
        uncertainty = AlignmentUncertainty.LOW
    elif uncertainty_value <= 0.55:
        uncertainty = AlignmentUncertainty.MODERATE
    else:
        uncertainty = AlignmentUncertainty.HIGH
    strongest = max(
        dimensions,
        key=lambda item: (item.qualitative_contribution, item.dimension.value),
    )
    explanation = (
        f"The clearest supported dimension is {strongest.dimension.value.replace('_', ' ')}.",
        "This is a context-sensitive band, not a score or verdict on the day.",
    )
    return DayAlignmentResult(
        status=AlignmentStatus.AVAILABLE,
        band=band,
        dimensions=dimensions,
        explanation=explanation,
        uncertainty=uncertainty,
        reason_codes=tuple(reason_codes),
        comparison_permitted=comparison_permitted,
        policy_version=active_policy.policy_version,
    )


def _assess_dimension(
    dimension: AlignmentDimension,
    signals: tuple[AlignmentSignal, ...],
    exceptions: tuple[LegitimateException, ...],
) -> DimensionAssessment:
    relevant = tuple(signal for signal in signals if signal.dimension is dimension)
    contribution = 0.0
    for signal in sorted(
        relevant,
        key=lambda item: item.contribution * item.confidence,
        reverse=True,
    ):
        support = signal.contribution * signal.confidence
        contribution += (1 - contribution) * support
    applicable_exceptions = tuple(
        exception for exception in exceptions if dimension in exception.affected_dimensions
    )
    wise_adjustments = tuple(
        exception.adaptation_quality
        for exception in applicable_exceptions
        if exception.wise_adaptation
    )
    exception_adjusted = bool(wise_adjustments)
    if wise_adjustments:
        contribution = max(contribution, max(wise_adjustments))
    return DimensionAssessment(
        dimension=dimension,
        qualitative_contribution=round(min(1.0, contribution), 6),
        evidence_count=len(relevant),
        exception_adjusted=exception_adjusted,
    )
