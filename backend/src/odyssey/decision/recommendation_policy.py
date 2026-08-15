"""Deterministic evidence-to-recommendation strength policy."""

from enum import StrEnum

from odyssey.decision.models import Stakes
from odyssey.domain.common import Applicability, ConfidenceBand, StrictModel


class EvidenceFreshness(StrEnum):
    UNKNOWN = "unknown"
    STALE = "stale"
    ACCEPTABLE = "acceptable"
    FRESH = "fresh"


class PersonalCausalEvidence(StrEnum):
    NONE = "none"
    OBSERVATIONAL = "observational"
    QUASI_EXPERIMENTAL = "quasi_experimental"
    EXPERIMENTAL = "experimental"
    REPLICATED_EXPERIMENT = "replicated_experiment"


class RecommendationStrength(StrEnum):
    INSUFFICIENT = "insufficient"
    WEAK = "weak"
    MODERATE = "moderate"
    STRONG = "strong"


class RecommendationPresentation(StrEnum):
    INSUFFICIENT_EVIDENCE = "insufficient_evidence"
    PRESENT_OPTIONS_OR_SEEK_INFORMATION = "present_options_or_seek_information"
    TENTATIVE_RECOMMENDATION = "tentative_recommendation"
    DIRECT_RECOMMENDATION = "direct_recommendation"


class StrengthReason(StrEnum):
    POPULATION_SUPPORT = "POPULATION_SUPPORT"
    DIRECT_APPLICABILITY = "DIRECT_APPLICABILITY"
    PERSONAL_CAUSAL_SUPPORT = "PERSONAL_CAUSAL_SUPPORT"
    FRESH_SUPPORT = "FRESH_SUPPORT"
    MATERIAL_EVIDENCE_CONFLICT = "MATERIAL_EVIDENCE_CONFLICT"
    HIGH_STAKES_CAP = "HIGH_STAKES_CAP"
    OBSERVATIONAL_LANGUAGE_RESTRICTED = "OBSERVATIONAL_LANGUAGE_RESTRICTED"
    SUPPORT_INSUFFICIENT = "SUPPORT_INSUFFICIENT"


class RecommendationEvidenceProfile(StrictModel):
    population_confidence: ConfidenceBand
    applicability: Applicability
    personal_causal_evidence: PersonalCausalEvidence
    evidence_freshness: EvidenceFreshness
    personal_data_freshness: EvidenceFreshness
    personal_data_is_observational_only: bool = False
    has_material_conflict: bool = False
    stakes: Stakes


class RecommendationStrengthResult(StrictModel):
    maximum_strength: RecommendationStrength
    presentation: RecommendationPresentation
    reason_codes: tuple[StrengthReason, ...]
    prohibited_phrases: tuple[str, ...] = ()
    policy_version: str = "recommendation-strength-policy-1.0"


class ProhibitedRecommendationLanguage(ValueError):
    """Raised when recommendation copy exceeds its evidence allowance."""


_CONFIDENCE_RANK = {
    ConfidenceBand.VERY_LOW: 0,
    ConfidenceBand.LOW: 1,
    ConfidenceBand.MODERATE: 2,
    ConfidenceBand.HIGH: 3,
    ConfidenceBand.VERY_HIGH: 4,
}
_APPLICABILITY_RANK = {
    Applicability.UNKNOWN: 0,
    Applicability.INDIRECT: 1,
    Applicability.PARTIAL: 2,
    Applicability.DIRECT: 4,
}
_FRESHNESS_RANK = {
    EvidenceFreshness.UNKNOWN: 0,
    EvidenceFreshness.STALE: 1,
    EvidenceFreshness.ACCEPTABLE: 2,
    EvidenceFreshness.FRESH: 3,
}
_PERSONAL_RANK = {
    PersonalCausalEvidence.NONE: 0,
    PersonalCausalEvidence.OBSERVATIONAL: 1,
    PersonalCausalEvidence.QUASI_EXPERIMENTAL: 2,
    PersonalCausalEvidence.EXPERIMENTAL: 3,
    PersonalCausalEvidence.REPLICATED_EXPERIMENT: 4,
}
_STRENGTH_ORDER = (
    RecommendationStrength.INSUFFICIENT,
    RecommendationStrength.WEAK,
    RecommendationStrength.MODERATE,
    RecommendationStrength.STRONG,
)


def maximum_recommendation_strength(
    profile: RecommendationEvidenceProfile,
) -> RecommendationStrengthResult:
    population = _CONFIDENCE_RANK[profile.population_confidence]
    applicability = _APPLICABILITY_RANK[profile.applicability]
    personal = _PERSONAL_RANK[profile.personal_causal_evidence]
    freshness = min(
        _FRESHNESS_RANK[profile.evidence_freshness],
        _FRESHNESS_RANK[profile.personal_data_freshness],
    )
    strength = _lookup_strength(
        population=population,
        applicability=applicability,
        personal=personal,
        freshness=freshness,
    )
    reasons = _support_reasons(
        population=population,
        applicability=applicability,
        personal=personal,
        freshness=freshness,
    )

    if profile.has_material_conflict:
        strength = _downgrade(strength)
        reasons.append(StrengthReason.MATERIAL_EVIDENCE_CONFLICT)

    prohibited_phrases: tuple[str, ...] = ()
    if profile.personal_data_is_observational_only:
        prohibited_phrases = (
            "works for you",
            "causes for you",
            "will work for you",
        )
        reasons.append(StrengthReason.OBSERVATIONAL_LANGUAGE_RESTRICTED)

    if strength is RecommendationStrength.INSUFFICIENT:
        reasons.append(StrengthReason.SUPPORT_INSUFFICIENT)
        presentation = RecommendationPresentation.INSUFFICIENT_EVIDENCE
    elif (
        profile.stakes in {Stakes.HIGH, Stakes.CRITICAL}
        and _STRENGTH_ORDER.index(strength)
        < _STRENGTH_ORDER.index(RecommendationStrength.MODERATE)
    ):
        reasons.append(StrengthReason.HIGH_STAKES_CAP)
        presentation = RecommendationPresentation.PRESENT_OPTIONS_OR_SEEK_INFORMATION
    elif strength is RecommendationStrength.WEAK:
        presentation = RecommendationPresentation.TENTATIVE_RECOMMENDATION
    else:
        presentation = RecommendationPresentation.DIRECT_RECOMMENDATION

    return RecommendationStrengthResult(
        maximum_strength=strength,
        presentation=presentation,
        reason_codes=tuple(dict.fromkeys(reasons)),
        prohibited_phrases=prohibited_phrases,
    )


def validate_recommendation_language(
    text: str,
    result: RecommendationStrengthResult,
) -> None:
    normalized = " ".join(text.casefold().split())
    matched = tuple(phrase for phrase in result.prohibited_phrases if phrase in normalized)
    if matched:
        raise ProhibitedRecommendationLanguage(
            f"recommendation language is prohibited by {result.policy_version}: {matched[0]}"
        )


def _lookup_strength(
    *,
    population: int,
    applicability: int,
    personal: int,
    freshness: int,
) -> RecommendationStrength:
    if population >= 3 and applicability >= 4 and personal >= 3 and freshness >= 2:
        return RecommendationStrength.STRONG
    if population >= 3 and applicability >= 4 and freshness >= 2:
        return RecommendationStrength.MODERATE
    if population >= 2 and applicability >= 2 and personal >= 2 and freshness >= 2:
        return RecommendationStrength.MODERATE
    if personal >= 4 and applicability >= 2 and freshness >= 2:
        return RecommendationStrength.MODERATE
    if population >= 2 and applicability >= 1 and freshness >= 2:
        return RecommendationStrength.WEAK
    if personal >= 1 and applicability >= 2 and freshness >= 1:
        return RecommendationStrength.WEAK
    return RecommendationStrength.INSUFFICIENT


def _support_reasons(
    *,
    population: int,
    applicability: int,
    personal: int,
    freshness: int,
) -> list[StrengthReason]:
    reasons: list[StrengthReason] = []
    if population >= 2:
        reasons.append(StrengthReason.POPULATION_SUPPORT)
    if applicability >= 4:
        reasons.append(StrengthReason.DIRECT_APPLICABILITY)
    if personal >= 2:
        reasons.append(StrengthReason.PERSONAL_CAUSAL_SUPPORT)
    if freshness >= 2:
        reasons.append(StrengthReason.FRESH_SUPPORT)
    return reasons


def _downgrade(strength: RecommendationStrength) -> RecommendationStrength:
    position = _STRENGTH_ORDER.index(strength)
    return _STRENGTH_ORDER[max(position - 1, 0)]
