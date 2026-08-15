"""Deterministic scoped evidence retrieval with explicit uncertainty."""

import json
import re
from datetime import UTC, datetime
from enum import StrEnum
from hashlib import sha256

from pydantic import AwareDatetime, Field, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.domain.common import UUID7, ConfidenceBand, StrictModel, new_uuid7
from odyssey.evidence.query_persistence import EvidenceQueryRecord
from odyssey.sync.models import CanonicalEntityRecord

EVIDENCE_RETRIEVAL_VERSION = "evidence-retrieval-1.0"


class ClaimRelation(StrEnum):
    SUPPORTING = "supporting"
    COUNTEREVIDENCE = "counterevidence"
    UNCLEAR = "unclear"


class PersonalScopeStatus(StrEnum):
    APPROVED = "approved"
    NOT_APPROVED = "not_approved"
    NOT_REQUESTED = "not_requested"


class CounterevidenceStatus(StrEnum):
    INCLUDED = "included"
    SEARCHED_NONE_FOUND = "searched_none_found"
    NOT_REQUIRED = "not_required"


class EvidenceUncertaintyCode(StrEnum):
    NO_SCIENTIFIC_MATCH = "NO_SCIENTIFIC_MATCH"
    COUNTEREVIDENCE_NOT_FOUND = "COUNTEREVIDENCE_NOT_FOUND"
    PERSONAL_SCOPE_NOT_APPROVED = "PERSONAL_SCOPE_NOT_APPROVED"
    MALFORMED_RECORDS_EXCLUDED = "MALFORMED_RECORDS_EXCLUDED"
    APPLICABILITY_REQUIRES_JUDGMENT = "APPLICABILITY_REQUIRES_JUDGMENT"


class EvidenceSourcePolicy(StrictModel):
    minimum_quality: ConfidenceBand
    include_emerging: bool = False
    require_counterevidence: bool = True
    maximum_results: int = Field(default=20, ge=1, le=50)


class EvidenceQueryRequest(StrictModel):
    question: str = Field(min_length=3, max_length=4_000)
    population_context: dict[str, object] = Field(default_factory=dict)
    personal_context_scope: str = Field(min_length=1, max_length=200)
    source_policy: EvidenceSourcePolicy


class ScientificClaimResult(StrictModel):
    claim_id: UUID7
    claim_text: str
    relation: ClaimRelation
    source_id: UUID7
    source_title: str
    source_type: str
    confidence: ConfidenceBand
    applicability_to_user: str
    exact_support_span_refs: tuple[str, ...]
    limitations: tuple[str, ...]
    domain_tags: tuple[str, ...]
    emerging: bool = False


class PersonalObservationResult(StrictModel):
    observation_id: UUID7
    summary: str
    observed_at: AwareDatetime
    domain_tags: tuple[str, ...]
    source_refs: tuple[UUID7, ...]


class PersonalExperimentResult(StrictModel):
    experiment_id: UUID7
    interpretation: str
    effect_estimate: str
    interval_or_uncertainty: str
    replication_state: str
    domain_tags: tuple[str, ...]


class EvidenceUncertainty(StrictModel):
    code: EvidenceUncertaintyCode
    explanation: str


class EvidenceQueryResponse(StrictModel):
    query_id: UUID7
    question: str
    scientific_claims: tuple[ScientificClaimResult, ...]
    counterevidence_claims: tuple[ScientificClaimResult, ...]
    personal_observations: tuple[PersonalObservationResult, ...]
    personal_experiments: tuple[PersonalExperimentResult, ...]
    personal_scope_status: PersonalScopeStatus
    counterevidence_status: CounterevidenceStatus
    applicability_summary: tuple[str, ...]
    uncertainties: tuple[EvidenceUncertainty, ...]
    source_entity_ids: tuple[UUID7, ...]
    assembled_at: AwareDatetime
    retrieval_version: str


class _StoredSource(StrictModel):
    title: str = Field(min_length=1, max_length=2_000)
    source_type: str
    version_or_retraction_state: str = "current"


class _StoredClaim(StrictModel):
    source_id: UUID7
    claim_text_normalized: str = Field(min_length=1, max_length=8_000)
    relation: ClaimRelation = ClaimRelation.UNCLEAR
    exact_support_span_refs: tuple[str, ...]
    limitations: tuple[str, ...] = ()
    domain_tags: tuple[str, ...]


class _StoredAppraisal(StrictModel):
    claim_id: UUID7
    overall_confidence: ConfidenceBand
    applicability_to_user: str


class _StoredObservation(StrictModel):
    summary: str = Field(min_length=1, max_length=8_000)
    observed_at: AwareDatetime
    domain_tags: tuple[str, ...]
    source_refs: tuple[UUID7, ...] = ()


class _StoredExperiment(StrictModel):
    interpretation: str
    effect_estimate: str
    interval_or_uncertainty: str
    replication_state: str
    domain_tags: tuple[str, ...]


class _StoredScopeApproval(StrictModel):
    scope: str
    status: str
    domains: tuple[str, ...]


_QUALITY_RANK = {
    ConfidenceBand.VERY_LOW: 0,
    ConfidenceBand.LOW: 1,
    ConfidenceBand.MODERATE: 2,
    ConfidenceBand.HIGH: 3,
    ConfidenceBand.VERY_HIGH: 4,
}
_STOPWORDS = frozenset(
    {
        "a",
        "an",
        "and",
        "does",
        "for",
        "how",
        "is",
        "of",
        "the",
        "to",
        "what",
    }
)


class EvidenceQueryService:
    async def query(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        request: EvidenceQueryRequest,
        now: datetime | None = None,
    ) -> EvidenceQueryResponse:
        assembled_at = now or datetime.now(UTC)
        entity_types = (
            "evidence_source",
            "evidence_claim",
            "claim_appraisal",
            "personal_observation",
            "experiment_result",
            "evidence_scope_approval",
        )
        rows = tuple(
            (
                await session.scalars(
                    select(CanonicalEntityRecord)
                    .where(
                        CanonicalEntityRecord.entity_type.in_(entity_types),
                        CanonicalEntityRecord.tombstoned.is_(False),
                    )
                    .order_by(
                        CanonicalEntityRecord.entity_type,
                        CanonicalEntityRecord.entity_id,
                    )
                )
            ).all()
        )
        malformed_count = 0
        sources: dict[UUID7, _StoredSource] = {}
        appraisals: dict[UUID7, _StoredAppraisal] = {}
        claims: list[tuple[UUID7, _StoredClaim]] = []
        observations: list[tuple[UUID7, _StoredObservation]] = []
        experiments: list[tuple[UUID7, _StoredExperiment]] = []
        approvals: list[_StoredScopeApproval] = []
        for row in rows:
            try:
                if row.entity_type == "evidence_source":
                    sources[row.entity_id] = _StoredSource.model_validate(row.document)
                elif row.entity_type == "evidence_claim":
                    claims.append(
                        (row.entity_id, _StoredClaim.model_validate(row.document))
                    )
                elif row.entity_type == "claim_appraisal":
                    parsed_appraisal = _StoredAppraisal.model_validate(row.document)
                    appraisals[parsed_appraisal.claim_id] = parsed_appraisal
                elif row.entity_type == "personal_observation":
                    observations.append(
                        (row.entity_id, _StoredObservation.model_validate(row.document))
                    )
                elif row.entity_type == "experiment_result":
                    experiments.append(
                        (row.entity_id, _StoredExperiment.model_validate(row.document))
                    )
                elif row.entity_type == "evidence_scope_approval":
                    approvals.append(_StoredScopeApproval.model_validate(row.document))
            except ValidationError:
                malformed_count += 1

        tokens = _tokens(request.question)
        scientific: list[tuple[int, ScientificClaimResult]] = []
        minimum_rank = _QUALITY_RANK[request.source_policy.minimum_quality]
        for claim_id, claim in claims:
            score = _match_score(tokens, claim.claim_text_normalized, claim.domain_tags)
            if score == 0:
                continue
            source = sources.get(claim.source_id)
            appraisal = appraisals.get(claim_id)
            if source is None or appraisal is None:
                malformed_count += 1
                continue
            if source.version_or_retraction_state.casefold() == "retracted":
                continue
            quality_rank = _QUALITY_RANK[appraisal.overall_confidence]
            emerging = quality_rank < minimum_rank
            if emerging and (
                not request.source_policy.include_emerging or quality_rank + 1 < minimum_rank
            ):
                continue
            scientific.append(
                (
                    score,
                    ScientificClaimResult(
                        claim_id=claim_id,
                        claim_text=claim.claim_text_normalized,
                        relation=claim.relation,
                        source_id=claim.source_id,
                        source_title=source.title,
                        source_type=source.source_type,
                        confidence=appraisal.overall_confidence,
                        applicability_to_user=appraisal.applicability_to_user,
                        exact_support_span_refs=claim.exact_support_span_refs,
                        limitations=claim.limitations,
                        domain_tags=claim.domain_tags,
                        emerging=emerging,
                    ),
                )
            )
        scientific.sort(key=lambda item: (-item[0], str(item[1].claim_id)))
        selected = tuple(item for _, item in scientific[: request.source_policy.maximum_results])
        source_ids: list[UUID7] = [
            source_id
            for item in selected
            for source_id in (item.claim_id, item.source_id)
        ]
        supporting = tuple(
            item for item in selected if item.relation is not ClaimRelation.COUNTEREVIDENCE
        )
        counter = tuple(
            item for item in selected if item.relation is ClaimRelation.COUNTEREVIDENCE
        )

        approval = next(
            (
                item
                for item in approvals
                if item.scope == request.personal_context_scope
                and item.status.casefold() == "approved"
            ),
            None,
        )
        if request.personal_context_scope.casefold() in {"none", "not_requested"}:
            scope_status = PersonalScopeStatus.NOT_REQUESTED
        elif approval is None:
            scope_status = PersonalScopeStatus.NOT_APPROVED
        else:
            scope_status = PersonalScopeStatus.APPROVED
        approved_domains = set(approval.domains) if approval is not None else set()
        personal_observations = tuple(
            PersonalObservationResult(
                observation_id=observation_id,
                summary=observation.summary,
                observed_at=observation.observed_at,
                domain_tags=observation.domain_tags,
                source_refs=observation.source_refs,
            )
            for observation_id, observation in observations
            if scope_status is PersonalScopeStatus.APPROVED
            and bool(observation.domain_tags)
            and set(observation.domain_tags).issubset(approved_domains)
            and _match_score(tokens, observation.summary, observation.domain_tags) > 0
        )[: request.source_policy.maximum_results]
        personal_experiments = tuple(
            PersonalExperimentResult(
                experiment_id=experiment_id,
                interpretation=experiment.interpretation,
                effect_estimate=experiment.effect_estimate,
                interval_or_uncertainty=experiment.interval_or_uncertainty,
                replication_state=experiment.replication_state,
                domain_tags=experiment.domain_tags,
            )
            for experiment_id, experiment in experiments
            if scope_status is PersonalScopeStatus.APPROVED
            and bool(experiment.domain_tags)
            and set(experiment.domain_tags).issubset(approved_domains)
            and _match_score(tokens, experiment.interpretation, experiment.domain_tags) > 0
        )[: request.source_policy.maximum_results]
        source_ids.extend(item.observation_id for item in personal_observations)
        source_ids.extend(item.experiment_id for item in personal_experiments)

        uncertainties: list[EvidenceUncertainty] = []
        if not selected:
            uncertainties.append(
                EvidenceUncertainty(
                    code=EvidenceUncertaintyCode.NO_SCIENTIFIC_MATCH,
                    explanation="No stored scientific claim satisfied the query and source policy.",
                )
            )
        if request.source_policy.require_counterevidence and not counter:
            counter_status = CounterevidenceStatus.SEARCHED_NONE_FOUND
            uncertainties.append(
                EvidenceUncertainty(
                    code=EvidenceUncertaintyCode.COUNTEREVIDENCE_NOT_FOUND,
                    explanation=(
                        "No matching counterevidence was stored; "
                        "this is not evidence of no conflict."
                    ),
                )
            )
        elif counter:
            counter_status = CounterevidenceStatus.INCLUDED
        else:
            counter_status = CounterevidenceStatus.NOT_REQUIRED
        if scope_status is PersonalScopeStatus.NOT_APPROVED:
            uncertainties.append(
                EvidenceUncertainty(
                    code=EvidenceUncertaintyCode.PERSONAL_SCOPE_NOT_APPROVED,
                    explanation=(
                        "Personal evidence was excluded because the requested scope "
                        "is not approved."
                    ),
                )
            )
        if malformed_count:
            uncertainties.append(
                EvidenceUncertainty(
                    code=EvidenceUncertaintyCode.MALFORMED_RECORDS_EXCLUDED,
                    explanation=f"{malformed_count} malformed evidence record(s) were excluded.",
                )
            )
        if selected:
            uncertainties.append(
                EvidenceUncertainty(
                    code=EvidenceUncertaintyCode.APPLICABILITY_REQUIRES_JUDGMENT,
                    explanation=(
                        "Population evidence and appraisal do not establish "
                        "a personal causal effect."
                    ),
                )
            )
        applicability = tuple(
            dict.fromkeys(item.applicability_to_user for item in selected)
        )
        query_id = new_uuid7()
        response = EvidenceQueryResponse(
            query_id=query_id,
            question=request.question,
            scientific_claims=supporting,
            counterevidence_claims=counter,
            personal_observations=personal_observations,
            personal_experiments=personal_experiments,
            personal_scope_status=scope_status,
            counterevidence_status=counter_status,
            applicability_summary=applicability,
            uncertainties=tuple(uncertainties),
            source_entity_ids=tuple(dict.fromkeys(source_ids)),
            assembled_at=assembled_at,
            retrieval_version=EVIDENCE_RETRIEVAL_VERSION,
        )
        request_hash = sha256(
            json.dumps(
                request.model_dump(mode="json"),
                separators=(",", ":"),
                sort_keys=True,
            ).encode()
        ).hexdigest()
        session.add(
            EvidenceQueryRecord(
                id=query_id,
                owner_id=owner_id,
                question=request.question,
                personal_scope=request.personal_context_scope,
                request_hash=request_hash,
                response=response.model_dump(mode="json"),
                source_entity_ids=[str(item) for item in response.source_entity_ids],
                assembled_at=assembled_at,
                retrieval_version=EVIDENCE_RETRIEVAL_VERSION,
            )
        )
        await session.flush()
        return response


def _tokens(value: str) -> frozenset[str]:
    return frozenset(
        token
        for token in re.findall(r"[a-z0-9]+", value.casefold())
        if len(token) > 1 and token not in _STOPWORDS
    )


def _match_score(tokens: frozenset[str], text: str, tags: tuple[str, ...]) -> int:
    searchable = _tokens(" ".join((text, *tags)))
    return len(tokens & searchable)
