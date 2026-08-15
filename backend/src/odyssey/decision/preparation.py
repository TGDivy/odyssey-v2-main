"""Deterministic decision preparation bound to an immutable context snapshot."""

import json
from datetime import UTC, datetime
from enum import StrEnum
from hashlib import sha256

from pydantic import AwareDatetime, Field, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.context.contracts import parse_horizon
from odyssey.context.persistence import ContextSnapshotRecord
from odyssey.decision.consequences import (
    ConsequenceContext,
    ConsequenceDerivation,
    DependencyGraph,
    DependencyRule,
    DirectEffect,
    derive_consequences,
)
from odyssey.decision.models import Stakes
from odyssey.decision.persistence import DecisionPreparationRecord
from odyssey.decision.recommendation_policy import (
    EvidenceFreshness,
    PersonalCausalEvidence,
    RecommendationEvidenceProfile,
    RecommendationStrengthResult,
    maximum_recommendation_strength,
)
from odyssey.domain.common import UUID7, Applicability, ConfidenceBand, StrictModel, new_uuid7
from odyssey.sync.models import CanonicalEntityRecord

DECISION_PREPARATION_POLICY_VERSION = "decision-preparation-policy-1.0"


class DesiredDecisionDepth(StrEnum):
    GLANCEABLE = "glanceable"
    INTERACTIVE = "interactive"
    DEEP = "deep"


class DecisionPreparationStatus(StrEnum):
    STRUCTURED_OPTIONS = "structured_options"
    INSUFFICIENT_EVIDENCE = "insufficient_evidence"
    INFORMATION_REQUIRED = "information_required"


class OptionEvidenceInput(StrictModel):
    population_confidence: ConfidenceBand
    applicability: Applicability
    personal_causal_evidence: PersonalCausalEvidence
    evidence_freshness: EvidenceFreshness
    personal_data_freshness: EvidenceFreshness
    personal_data_is_observational_only: bool = False
    has_material_conflict: bool = False


class KnownDecisionOption(StrictModel):
    option_id: UUID7 = Field(default_factory=new_uuid7)
    label: str = Field(min_length=1, max_length=500)
    description: str = Field(min_length=1, max_length=8_000)
    direct_effects: tuple[DirectEffect, ...] = ()
    evidence: OptionEvidenceInput | None = None


class DecisionPreparationRequest(StrictModel):
    question: str = Field(min_length=1, max_length=4_000)
    context_snapshot_id: UUID7
    known_options: tuple[KnownDecisionOption, ...] = Field(default=(), max_length=20)
    desired_depth: DesiredDecisionDepth
    max_latency_ms: int = Field(ge=100, le=30_000)
    stakes: Stakes = Stakes.MEDIUM


class PreparedDecisionOption(StrictModel):
    option_id: UUID7
    label: str
    description: str
    consequences: ConsequenceDerivation | None = None
    recommendation_strength: RecommendationStrengthResult | None = None


class DecisionPreparationResponse(StrictModel):
    preparation_id: UUID7
    decision_id: UUID7
    question: str
    context_snapshot_id: UUID7
    context_content_hash: str = Field(min_length=64, max_length=64)
    status: DecisionPreparationStatus
    recommendation_status: str
    options: tuple[PreparedDecisionOption, ...]
    missing_information: tuple[str, ...]
    information_request: str | None = None
    prepared_at: AwareDatetime
    model_used: bool = False
    route_policy: str = "deterministic_only"
    policy_versions: tuple[str, ...]


class DecisionPreparationError(RuntimeError):
    def __init__(self, code: str, message: str, *, status_code: int) -> None:
        super().__init__(message)
        self.code = code
        self.status_code = status_code


class DecisionPreparationService:
    async def prepare(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        request: DecisionPreparationRequest,
        now: datetime | None = None,
    ) -> DecisionPreparationResponse:
        prepared_at = now or datetime.now(UTC)
        snapshot = await session.get(ContextSnapshotRecord, request.context_snapshot_id)
        if snapshot is None or snapshot.owner_id != owner_id:
            raise DecisionPreparationError(
                "CONTEXT_SNAPSHOT_NOT_FOUND",
                "The requested context snapshot does not exist for this owner.",
                status_code=404,
            )
        graph = await self._dependency_graph(session)
        decision_id = new_uuid7()
        preparation_id = new_uuid7()
        options: list[PreparedDecisionOption] = []
        missing: list[str] = []
        if not request.known_options:
            missing.append("known_options")
        context = self._consequence_context(snapshot)
        for option in request.known_options:
            consequences = None
            if option.direct_effects:
                consequences = derive_consequences(
                    action_type=f"decision_option:{option.option_id}",
                    direct_effects=option.direct_effects,
                    context=context,
                    graph=graph,
                )
            else:
                missing.append(f"direct_effects:{option.option_id}")
            strength = None
            if option.evidence is not None:
                strength = maximum_recommendation_strength(
                    RecommendationEvidenceProfile(
                        **option.evidence.model_dump(),
                        stakes=request.stakes,
                    )
                )
            else:
                missing.append(f"evidence:{option.option_id}")
            options.append(
                PreparedDecisionOption(
                    option_id=option.option_id,
                    label=option.label,
                    description=option.description,
                    consequences=consequences,
                    recommendation_strength=strength,
                )
            )

        if not request.known_options:
            status = DecisionPreparationStatus.INFORMATION_REQUIRED
            information_request = "What options are currently under consideration?"
            recommendation_status = "insufficient_information"
        elif missing:
            status = DecisionPreparationStatus.INSUFFICIENT_EVIDENCE
            information_request = (
                "Add material option effects or evidence before requesting a recommendation."
            )
            recommendation_status = "insufficient_evidence"
        else:
            status = DecisionPreparationStatus.STRUCTURED_OPTIONS
            information_request = None
            recommendation_status = "options_prepared_for_owner_choice"

        response = DecisionPreparationResponse(
            preparation_id=preparation_id,
            decision_id=decision_id,
            question=request.question,
            context_snapshot_id=request.context_snapshot_id,
            context_content_hash=snapshot.content_hash,
            status=status,
            recommendation_status=recommendation_status,
            options=tuple(options),
            missing_information=tuple(dict.fromkeys(missing)),
            information_request=information_request,
            prepared_at=prepared_at,
            policy_versions=(
                DECISION_PREPARATION_POLICY_VERSION,
                "consequence-policy-1.0",
                "recommendation-strength-policy-1.0",
            ),
        )
        request_hash = sha256(
            json.dumps(
                request.model_dump(mode="json"),
                separators=(",", ":"),
                sort_keys=True,
            ).encode()
        ).hexdigest()
        session.add(
            DecisionPreparationRecord(
                id=preparation_id,
                decision_id=decision_id,
                owner_id=owner_id,
                context_snapshot_id=request.context_snapshot_id,
                question=request.question,
                status=status.value,
                request_hash=request_hash,
                response=response.model_dump(mode="json"),
                prepared_at=prepared_at,
                policy_version=DECISION_PREPARATION_POLICY_VERSION,
            )
        )
        await session.flush()
        return response

    @staticmethod
    async def _dependency_graph(session: AsyncSession) -> DependencyGraph:
        rows = tuple(
            (
                await session.scalars(
                    select(CanonicalEntityRecord)
                    .where(
                        CanonicalEntityRecord.entity_type == "consequence_rule",
                        CanonicalEntityRecord.tombstoned.is_(False),
                    )
                    .order_by(CanonicalEntityRecord.entity_id)
                )
            ).all()
        )
        try:
            rules = tuple(DependencyRule.model_validate(row.document) for row in rows)
            return DependencyGraph(rules=rules)
        except ValidationError as error:
            raise DecisionPreparationError(
                "CONSEQUENCE_RULE_INVALID",
                "An active consequence rule does not satisfy the current policy contract.",
                status_code=409,
            ) from error

    @staticmethod
    def _consequence_context(snapshot: ContextSnapshotRecord) -> ConsequenceContext:
        as_of = _aware(snapshot.as_of)
        domain_documents = snapshot.document.get("snapshot", {}).get("domains", [])
        active_conditions = frozenset(
            str(item.get("domain"))
            for item in domain_documents
            if isinstance(item, dict) and item.get("status") == "fresh"
        )
        return ConsequenceContext(
            now=as_of,
            latest_relevant_at=as_of + parse_horizon(snapshot.horizon),
            active_conditions=active_conditions,
            default_input_quality=0.5,
            default_model_calibration=0.5,
        )


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
