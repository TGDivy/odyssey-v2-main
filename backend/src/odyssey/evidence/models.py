"""Scientific and personal evidence contracts with explicit appraisal."""

from datetime import date
from enum import StrEnum

from pydantic import AwareDatetime, Field

from odyssey.domain.common import UUID7, ConfidenceBand, EntityMetadata, ExternalRef, StrictModel


class EvidenceSourceType(StrEnum):
    SYSTEMATIC_REVIEW = "systematic_review"
    META_ANALYSIS = "meta_analysis"
    RANDOMIZED_TRIAL = "randomized_trial"
    OBSERVATIONAL = "observational"
    GUIDELINE = "guideline"
    EXPERT_CONSENSUS = "expert_consensus"
    MECHANISM = "mechanism"
    QUALITATIVE = "qualitative"
    OFFICIAL_DOCUMENTATION = "official_documentation"
    PERSONAL_EXPERIMENT = "personal_experiment"
    PERSONAL_OBSERVATION = "personal_observation"
    OTHER = "other"


class EvidenceIdentifier(StrictModel):
    kind: str
    identifier: str


class AcquisitionLicense(StrictModel):
    acquisition_method: str
    license_name: str | None = None
    redistribution_allowed: bool = False
    full_text_storage_allowed: bool = False


class EvidenceSource(StrictModel):
    metadata: EntityMetadata
    title: str = Field(min_length=1, max_length=2_000)
    authors: tuple[str, ...]
    publication: str
    publication_date: date | None = None
    source_type: EvidenceSourceType
    identifiers: tuple[EvidenceIdentifier, ...]
    version_or_retraction_state: str
    acquisition_and_license: AcquisitionLicense
    content_hash: str | None = Field(default=None, min_length=16, max_length=128)
    external_refs: tuple[ExternalRef, ...] = ()


class EffectEstimate(StrictModel):
    measure: str
    estimate: float | None = None
    lower_bound: float | None = None
    upper_bound: float | None = None
    unit: str | None = None
    notes: str | None = None


class EvidenceClaim(StrictModel):
    metadata: EntityMetadata
    source_id: UUID7
    claim_text_normalized: str = Field(min_length=1, max_length=8_000)
    exact_support_span_refs: tuple[str, ...]
    population: str
    exposure_or_intervention: str
    comparator: str | None = None
    outcomes: tuple[str, ...]
    effect_estimates: tuple[EffectEstimate, ...] = ()
    limitations: tuple[str, ...] = ()
    domain_tags: tuple[str, ...]
    appraisal_id: UUID7


class AppraisalBand(StrEnum):
    LOW_CONCERN = "low_concern"
    SOME_CONCERN = "some_concern"
    HIGH_CONCERN = "high_concern"
    UNKNOWN = "unknown"


class ClaimAppraisal(StrictModel):
    metadata: EntityMetadata
    claim_id: UUID7
    study_design_quality: AppraisalBand
    risk_of_bias: AppraisalBand
    inconsistency: AppraisalBand
    indirectness: AppraisalBand
    imprecision: AppraisalBand
    publication_bias_or_reporting_concern: AppraisalBand
    applicability_to_user: str
    overall_confidence: ConfidenceBand
    appraised_by: str
    review_due_at: AwareDatetime | None = None


class EvidencePack(StrictModel):
    id: UUID7
    question: str = Field(min_length=1, max_length=4_000)
    personal_facts: tuple[UUID7, ...] = ()
    scientific_claims: tuple[UUID7, ...] = ()
    contradictory_claims: tuple[UUID7, ...] = ()
    exclusions: tuple[str, ...] = ()
    retrieval_query_and_version: str
    assembled_at: AwareDatetime
    freshness: str
