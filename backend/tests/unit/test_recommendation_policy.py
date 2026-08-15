import pytest

from odyssey.decision.models import Stakes
from odyssey.decision.recommendation_policy import (
    EvidenceFreshness,
    PersonalCausalEvidence,
    ProhibitedRecommendationLanguage,
    RecommendationEvidenceProfile,
    RecommendationPresentation,
    RecommendationStrength,
    StrengthReason,
    maximum_recommendation_strength,
    validate_recommendation_language,
)
from odyssey.domain.common import Applicability, ConfidenceBand


def profile(**overrides: object) -> RecommendationEvidenceProfile:
    values: dict[str, object] = {
        "population_confidence": ConfidenceBand.HIGH,
        "applicability": Applicability.DIRECT,
        "personal_causal_evidence": PersonalCausalEvidence.EXPERIMENTAL,
        "evidence_freshness": EvidenceFreshness.FRESH,
        "personal_data_freshness": EvidenceFreshness.FRESH,
        "stakes": Stakes.MEDIUM,
    }
    values.update(overrides)
    return RecommendationEvidenceProfile.model_validate(values)


def test_strong_recommendation_requires_convergent_direct_support() -> None:
    result = maximum_recommendation_strength(profile())

    assert result.maximum_strength is RecommendationStrength.STRONG
    assert result.presentation is RecommendationPresentation.DIRECT_RECOMMENDATION
    assert set(result.reason_codes) >= {
        StrengthReason.POPULATION_SUPPORT,
        StrengthReason.DIRECT_APPLICABILITY,
        StrengthReason.PERSONAL_CAUSAL_SUPPORT,
        StrengthReason.FRESH_SUPPORT,
    }


def test_population_evidence_can_support_moderate_nonpersonal_recommendation() -> None:
    result = maximum_recommendation_strength(
        profile(personal_causal_evidence=PersonalCausalEvidence.NONE)
    )

    assert result.maximum_strength is RecommendationStrength.MODERATE
    assert result.presentation is RecommendationPresentation.DIRECT_RECOMMENDATION


def test_material_conflict_downgrades_exactly_one_level() -> None:
    result = maximum_recommendation_strength(profile(has_material_conflict=True))

    assert result.maximum_strength is RecommendationStrength.MODERATE
    assert StrengthReason.MATERIAL_EVIDENCE_CONFLICT in result.reason_codes


def test_high_stakes_weak_support_can_only_present_options() -> None:
    result = maximum_recommendation_strength(
        profile(
            population_confidence=ConfidenceBand.MODERATE,
            applicability=Applicability.INDIRECT,
            personal_causal_evidence=PersonalCausalEvidence.NONE,
            stakes=Stakes.HIGH,
        )
    )

    assert result.maximum_strength is RecommendationStrength.WEAK
    assert result.presentation is RecommendationPresentation.PRESENT_OPTIONS_OR_SEEK_INFORMATION
    assert StrengthReason.HIGH_STAKES_CAP in result.reason_codes


def test_unknown_or_stale_support_returns_insufficient_evidence() -> None:
    result = maximum_recommendation_strength(
        profile(
            population_confidence=ConfidenceBand.LOW,
            applicability=Applicability.UNKNOWN,
            personal_causal_evidence=PersonalCausalEvidence.NONE,
            evidence_freshness=EvidenceFreshness.STALE,
            personal_data_freshness=EvidenceFreshness.UNKNOWN,
        )
    )

    assert result.maximum_strength is RecommendationStrength.INSUFFICIENT
    assert result.presentation is RecommendationPresentation.INSUFFICIENT_EVIDENCE
    assert StrengthReason.SUPPORT_INSUFFICIENT in result.reason_codes


def test_replicated_personal_experiment_can_support_moderate_strength() -> None:
    result = maximum_recommendation_strength(
        profile(
            population_confidence=ConfidenceBand.LOW,
            applicability=Applicability.PARTIAL,
            personal_causal_evidence=PersonalCausalEvidence.REPLICATED_EXPERIMENT,
        )
    )

    assert result.maximum_strength is RecommendationStrength.MODERATE


def test_observational_personal_data_prohibits_causal_personalized_language() -> None:
    result = maximum_recommendation_strength(
        profile(
            personal_causal_evidence=PersonalCausalEvidence.OBSERVATIONAL,
            personal_data_is_observational_only=True,
        )
    )

    validate_recommendation_language(
        "The observations are associated with earlier sleep in this period.",
        result,
    )
    with pytest.raises(ProhibitedRecommendationLanguage, match="works for you"):
        validate_recommendation_language("This works   for YOU on busy days.", result)


def test_policy_output_is_versioned() -> None:
    result = maximum_recommendation_strength(profile())

    assert result.policy_version == "recommendation-strength-policy-1.0"
