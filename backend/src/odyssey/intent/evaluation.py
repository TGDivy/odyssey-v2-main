"""Durable intervention-opportunity evaluation service."""

import json
from datetime import UTC, datetime, time
from hashlib import sha256

from pydantic import AwareDatetime, Field, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.domain.common import UUID7, StrictModel, new_uuid7
from odyssey.intent.models import InterventionKind
from odyssey.intent.persistence import InterventionEvaluationRecord
from odyssey.intent.policy import (
    DeliveryChannelCandidate,
    IntentActivityStatus,
    InterventionEvaluation,
    InterventionPurpose,
    InterventionUrgency,
    SilenceGatePolicy,
    decide_intervention,
)
from odyssey.sync.models import CanonicalEntityRecord


class DeliveryCapabilities(StrictModel):
    local_notification: bool = False
    live_activity: bool = False
    watch_reachable: bool = False
    widget_snapshot: bool = True
    in_app: bool = True


class InterventionClientState(StrictModel):
    foreground: bool
    focus_redaction: str = Field(min_length=1, max_length=50)
    recently_handled: bool = False
    recently_dismissed: bool = False
    material_state_changed: bool = False
    recomputed_for_current_state: bool = False
    sensitive_or_social_moment: bool = False
    more_important_intervention_recent: bool = False
    local_day_started_at: AwareDatetime | None = None


class InterventionEvaluationRequest(StrictModel):
    opportunity_id: UUID7
    delivery_capabilities: DeliveryCapabilities
    client_state: InterventionClientState


class InterventionEvaluationResponse(StrictModel):
    policy: str
    reason_codes: tuple[str, ...]
    surface: str | None = None
    expires_at: AwareDatetime
    retry_after: AwareDatetime | None = None
    policy_version: str


class StoredChannel(StrictModel):
    kind: InterventionKind
    expected_effectiveness: float = Field(ge=0, le=1)
    interruptiveness: float = Field(ge=0, le=1)
    ambient: bool = False


class StoredOpportunity(StrictModel):
    intent_id: UUID7
    expires_at: AwareDatetime
    semantic_key: str = Field(min_length=1, max_length=500)
    context_confidence: float = Field(ge=0, le=1)
    action_feasible: bool = True
    disqualifiers_satisfied: tuple[str, ...] = ()
    expected_benefit: float
    expected_interruption_cost: float = Field(ge=0)
    urgency: InterventionUrgency
    purpose: InterventionPurpose = InterventionPurpose.USEFUL_ACTION
    safe_useful_action_available: bool = True
    obvious_and_ambiently_visible: bool = False
    ignored_count: int = Field(default=0, ge=0)
    last_ignored_at: AwareDatetime | None = None
    channels: tuple[StoredChannel, ...]


class InterventionEvaluationError(RuntimeError):
    def __init__(self, code: str, message: str, *, status_code: int) -> None:
        super().__init__(message)
        self.code = code
        self.status_code = status_code


class InterventionEvaluationService:
    async def evaluate(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        request: InterventionEvaluationRequest,
        now: datetime | None = None,
    ) -> InterventionEvaluationResponse:
        evaluated_at = now or datetime.now(UTC)
        opportunity_record = await session.get(
            CanonicalEntityRecord,
            ("intervention_opportunity", request.opportunity_id),
        )
        if opportunity_record is None or opportunity_record.tombstoned:
            raise InterventionEvaluationError(
                "INTERVENTION_OPPORTUNITY_NOT_FOUND",
                "The intervention opportunity does not exist or is no longer active.",
                status_code=404,
            )
        try:
            opportunity = StoredOpportunity.model_validate(opportunity_record.document)
        except ValidationError as error:
            raise InterventionEvaluationError(
                "INTERVENTION_OPPORTUNITY_INVALID",
                "The stored intervention opportunity does not satisfy the current policy contract.",
                status_code=409,
            ) from error
        intent_record = await session.get(CanonicalEntityRecord, ("intent", opportunity.intent_id))
        intent_status = IntentActivityStatus.ACTIVE
        if intent_record is None or intent_record.tombstoned:
            intent_status = IntentActivityStatus.CANCELLED
        else:
            try:
                intent_status = IntentActivityStatus(str(intent_record.document.get("status")))
            except ValueError:
                intent_status = IntentActivityStatus.CANCELLED

        proactive_pause = await self._global_pause(session)
        day_start = request.client_state.local_day_started_at or datetime.combine(
            evaluated_at.date(),
            time.min,
            tzinfo=evaluated_at.tzinfo or UTC,
        )
        visible_history = tuple(
            (
                await session.scalars(
                    select(InterventionEvaluationRecord)
                    .where(
                        InterventionEvaluationRecord.owner_id == owner_id,
                        InterventionEvaluationRecord.evaluated_at >= day_start,
                        InterventionEvaluationRecord.evaluated_at <= evaluated_at,
                        InterventionEvaluationRecord.policy == "deliver",
                    )
                    .order_by(InterventionEvaluationRecord.evaluated_at)
                )
            ).all()
        )
        last_low_stakes = next(
            (
                _aware(record.evaluated_at)
                for record in reversed(visible_history)
                if record.urgency in {"low", "normal"}
            ),
            None,
        )
        evaluation = InterventionEvaluation(
            now=evaluated_at,
            expires_at=opportunity.expires_at,
            intent_status=intent_status,
            material_state_changed=request.client_state.material_state_changed,
            recomputed_for_current_state=request.client_state.recomputed_for_current_state,
            global_proactive_pause=proactive_pause,
            disqualifiers_satisfied=opportunity.disqualifiers_satisfied,
            context_confidence=opportunity.context_confidence,
            action_feasible=opportunity.action_feasible,
            already_handled=request.client_state.recently_handled,
            recently_dismissed=request.client_state.recently_dismissed,
            more_important_intervention_recent=(
                request.client_state.more_important_intervention_recent
            ),
            ignored_count=opportunity.ignored_count,
            last_ignored_at=opportunity.last_ignored_at,
            purpose=opportunity.purpose,
            safe_useful_action_available=opportunity.safe_useful_action_available,
            obvious_and_ambiently_visible=opportunity.obvious_and_ambiently_visible,
            expected_benefit=opportunity.expected_benefit,
            expected_interruption_cost=opportunity.expected_interruption_cost,
            urgency=opportunity.urgency,
            visible_deliveries_today=len(visible_history),
            last_low_stakes_visible_at=last_low_stakes,
            sensitive_or_social_moment=request.client_state.sensitive_or_social_moment,
            channels=self._channels(opportunity.channels, request),
        )
        policy_result = decide_intervention(evaluation, SilenceGatePolicy())
        surface = _surface_name(policy_result.surface)
        response = InterventionEvaluationResponse(
            policy=policy_result.policy.value,
            reason_codes=tuple(reason.value for reason in policy_result.reason_codes),
            surface=surface,
            expires_at=policy_result.expires_at,
            retry_after=policy_result.retry_after,
            policy_version=policy_result.policy_version,
        )
        request_hash = sha256(
            json.dumps(
                request.model_dump(mode="json"),
                separators=(",", ":"),
                sort_keys=True,
            ).encode()
        ).hexdigest()
        session.add(
            InterventionEvaluationRecord(
                id=new_uuid7(),
                owner_id=owner_id,
                opportunity_id=request.opportunity_id,
                semantic_key=opportunity.semantic_key,
                evaluated_at=evaluated_at,
                urgency=opportunity.urgency.value,
                policy=response.policy,
                reason_codes=list(response.reason_codes),
                surface=response.surface,
                expires_at=response.expires_at,
                retry_after=response.retry_after,
                policy_version=response.policy_version,
                request_context_hash=request_hash,
            )
        )
        await session.flush()
        return response

    @staticmethod
    async def _global_pause(session: AsyncSession) -> bool:
        record = await session.scalar(
            select(CanonicalEntityRecord)
            .where(
                CanonicalEntityRecord.entity_type == "proactive_control",
                CanonicalEntityRecord.tombstoned.is_(False),
            )
            .order_by(CanonicalEntityRecord.updated_at.desc())
            .limit(1)
        )
        return bool(record and record.document.get("paused") is True)

    @staticmethod
    def _channels(
        channels: tuple[StoredChannel, ...],
        request: InterventionEvaluationRequest,
    ) -> tuple[DeliveryChannelCandidate, ...]:
        capabilities = request.delivery_capabilities
        availability = {
            InterventionKind.IN_APP: capabilities.in_app and request.client_state.foreground,
            InterventionKind.WIDGET: capabilities.widget_snapshot,
            InterventionKind.WATCH: capabilities.watch_reachable,
            InterventionKind.LOCAL_NOTIFICATION: capabilities.local_notification,
            InterventionKind.LIVE_ACTIVITY: capabilities.live_activity,
            InterventionKind.REMOTE_NOTIFICATION: False,
            InterventionKind.ALARM: False,
            InterventionKind.DIGEST: capabilities.in_app,
        }
        return tuple(
            DeliveryChannelCandidate(
                kind=channel.kind,
                available=availability[channel.kind],
                expected_effectiveness=channel.expected_effectiveness,
                interruptiveness=channel.interruptiveness,
                ambient=channel.ambient,
            )
            for channel in channels
        )


def _surface_name(kind: InterventionKind | None) -> str | None:
    if kind is InterventionKind.WIDGET:
        return "widget_snapshot"
    return kind.value if kind is not None else None


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
