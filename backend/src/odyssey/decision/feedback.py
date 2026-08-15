"""Append-only recommendation feedback and assertion correction service."""

import json
from datetime import UTC, datetime
from enum import StrEnum
from hashlib import sha256

from pydantic import Field, model_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.db.models import AssertionRecord
from odyssey.db.repositories import LedgerRepository, SourceRecordWrite
from odyssey.decision.feedback_persistence import RecommendationFeedbackRecord
from odyssey.domain.common import (
    UUID7,
    ActorRef,
    ActorType,
    DataClass,
    Provenance,
    StrictModel,
    new_uuid7,
)
from odyssey.domain.events import DomainEvent
from odyssey.sync.models import CanonicalEntityRecord

FEEDBACK_POLICY_VERSION = "recommendation-feedback-policy-1.0"


class RecommendationFeedbackType(StrEnum):
    WRONG_CONTEXT = "wrong_context"
    WRONG_EVIDENCE = "wrong_evidence"
    NOT_HELPFUL = "not_helpful"
    HELPFUL = "helpful"
    UNSAFE = "unsafe"
    STALE = "stale"
    OTHER = "other"


class CorrectionApplyScope(StrEnum):
    THIS_EVENT_ONLY = "this_event_only"
    FUTURE_RECOMMENDATIONS = "future_recommendations"


class RecommendationCorrection(StrictModel):
    assertion_id: UUID7
    replacement: str = Field(min_length=1, max_length=8_000)


class RecommendationFeedbackRequest(StrictModel):
    feedback_type: RecommendationFeedbackType
    correction: RecommendationCorrection | None = None
    apply_scope: CorrectionApplyScope = CorrectionApplyScope.THIS_EVENT_ONLY

    @model_validator(mode="after")
    def validate_correction(self) -> "RecommendationFeedbackRequest":
        if self.feedback_type in {
            RecommendationFeedbackType.WRONG_CONTEXT,
            RecommendationFeedbackType.WRONG_EVIDENCE,
        } and self.correction is None:
            raise ValueError("context or evidence feedback requires a correction")
        if self.correction is None and self.apply_scope is not CorrectionApplyScope.THIS_EVENT_ONLY:
            raise ValueError("future correction scope requires a correction")
        return self


class DurableRecordChange(StrictModel):
    record_type: str
    record_id: UUID7
    operation: str


class RecommendationFeedbackResponse(StrictModel):
    feedback_id: UUID7
    recommendation_id: UUID7
    records_changed: tuple[DurableRecordChange, ...]
    future_recommendations_affected: bool
    apply_scope: CorrectionApplyScope
    policy_version: str


class RecommendationFeedbackError(RuntimeError):
    def __init__(self, code: str, message: str, *, status_code: int) -> None:
        super().__init__(message)
        self.code = code
        self.status_code = status_code


class RecommendationFeedbackService:
    def __init__(self) -> None:
        self.repository = LedgerRepository()

    async def record(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        recommendation_id: UUID7,
        request: RecommendationFeedbackRequest,
        idempotency_key: str,
        now: datetime | None = None,
    ) -> RecommendationFeedbackResponse:
        recorded_at = now or datetime.now(UTC)
        request_document = {
            "recommendation_id": str(recommendation_id),
            "feedback": request.model_dump(mode="json"),
        }
        request_hash = sha256(
            json.dumps(request_document, separators=(",", ":"), sort_keys=True).encode()
        ).hexdigest()
        idempotency_hash = sha256(idempotency_key.encode()).hexdigest()
        existing = await session.scalar(
            select(RecommendationFeedbackRecord).where(
                RecommendationFeedbackRecord.idempotency_key_hash == idempotency_hash
            )
        )
        if existing is not None:
            if existing.request_hash != request_hash:
                raise RecommendationFeedbackError(
                    "FEEDBACK_IDEMPOTENCY_KEY_REUSED",
                    "The idempotency key was already used for different feedback.",
                    status_code=409,
                )
            return RecommendationFeedbackResponse.model_validate(existing.response)

        recommendation = await session.get(
            CanonicalEntityRecord,
            ("recommendation", recommendation_id),
        )
        if recommendation is None or recommendation.tombstoned:
            raise RecommendationFeedbackError(
                "RECOMMENDATION_NOT_FOUND",
                "The recommendation does not exist or is no longer available.",
                status_code=404,
            )
        if request.apply_scope is CorrectionApplyScope.FUTURE_RECOMMENDATIONS:
            raise RecommendationFeedbackError(
                "CORRECTION_SCOPE_NOT_IMPLEMENTED",
                "Future recommendation correction is disabled until retrieval consumes it.",
                status_code=409,
            )

        feedback_id = new_uuid7()
        changes: list[DurableRecordChange] = []
        replacement_assertion_id = None
        ledger_event_id = None
        if request.correction is not None:
            original = await session.get(AssertionRecord, request.correction.assertion_id)
            if original is None:
                raise RecommendationFeedbackError(
                    "ASSERTION_NOT_FOUND",
                    "The assertion selected for correction does not exist.",
                    status_code=404,
                )
            replacement_assertion_id, ledger_event_id = await self._supersede_assertion(
                session,
                owner_id=owner_id,
                feedback_id=feedback_id,
                recommendation_id=recommendation_id,
                original=original,
                replacement=request.correction.replacement,
                recorded_at=recorded_at,
            )
            changes.extend(
                (
                    DurableRecordChange(
                        record_type="assertion",
                        record_id=replacement_assertion_id,
                        operation="created_superseding_version",
                    ),
                    DurableRecordChange(
                        record_type="ledger_event",
                        record_id=ledger_event_id,
                        operation="appended",
                    ),
                )
            )
        changes.insert(
            0,
            DurableRecordChange(
                record_type="recommendation_feedback",
                record_id=feedback_id,
                operation="created",
            ),
        )
        response = RecommendationFeedbackResponse(
            feedback_id=feedback_id,
            recommendation_id=recommendation_id,
            records_changed=tuple(changes),
            future_recommendations_affected=False,
            apply_scope=request.apply_scope,
            policy_version=FEEDBACK_POLICY_VERSION,
        )
        session.add(
            RecommendationFeedbackRecord(
                id=feedback_id,
                owner_id=owner_id,
                recommendation_id=recommendation_id,
                feedback_type=request.feedback_type.value,
                apply_scope=request.apply_scope.value,
                correction_assertion_id=(
                    request.correction.assertion_id if request.correction is not None else None
                ),
                replacement_assertion_id=replacement_assertion_id,
                ledger_event_id=ledger_event_id,
                future_recommendations_affected=False,
                request_hash=request_hash,
                idempotency_key_hash=idempotency_hash,
                response=response.model_dump(mode="json"),
                recorded_at=recorded_at,
                policy_version=FEEDBACK_POLICY_VERSION,
            )
        )
        await session.flush()
        return response

    async def _supersede_assertion(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        feedback_id: UUID7,
        recommendation_id: UUID7,
        original: AssertionRecord,
        replacement: str,
        recorded_at: datetime,
    ) -> tuple[UUID7, UUID7]:
        replacement_id = new_uuid7()
        event_id = new_uuid7()
        provenance_id = new_uuid7()
        source_payload = {
            "feedback_id": str(feedback_id),
            "recommendation_id": str(recommendation_id),
            "assertion_id": str(original.id),
            "replacement_assertion_id": str(replacement_id),
            "replacement": replacement,
            "apply_scope": CorrectionApplyScope.THIS_EVENT_ONLY.value,
        }
        content_hash = sha256(
            json.dumps(source_payload, separators=(",", ":"), sort_keys=True).encode()
        ).hexdigest()
        actor = ActorRef(actor_type=ActorType.USER, actor_id=owner_id)
        provenance = Provenance(
            id=provenance_id,
            source_kind="recommendation_correction",
            source_id=str(feedback_id),
            captured_at=recorded_at,
            actor=actor,
            transformation_chain=(FEEDBACK_POLICY_VERSION,),
            content_hash=content_hash,
            details={"recommendation_id": str(recommendation_id)},
        )
        source = SourceRecordWrite(
            id=replacement_id,
            source_kind="recommendation_correction",
            occurred_at=recorded_at,
            recorded_at=recorded_at,
            temporal_precision="exact",
            content_hash=content_hash,
            sensitivity=DataClass.PRIVATE.value,
            payload=source_payload,
            provenance_id=provenance_id,
        )
        event = DomainEvent(
            event_id=event_id,
            event_type="assertion.superseded.v1",
            event_schema_version=1,
            aggregate_type="assertion",
            aggregate_id=original.id,
            occurred_at=recorded_at,
            recorded_at=recorded_at,
            actor=actor,
            correlation_id=feedback_id,
            payload={
                "assertion_id": str(original.id),
                "superseded_by_assertion_id": str(replacement_id),
            },
            provenance=provenance,
        )
        await self.repository.append_source_event(session, source=source, event=event)
        session.add(
            AssertionRecord(
                id=replacement_id,
                subject_id=original.subject_id,
                predicate=original.predicate,
                object_value={"value": replacement},
                valid_from=original.valid_from,
                valid_to=original.valid_to,
                epistemic_status="user_stated",
                confidence=1.0,
                supersedes_id=original.id,
                provenance_id=provenance_id,
                created_at=recorded_at,
            )
        )
        await session.flush()
        return replacement_id, event_id
