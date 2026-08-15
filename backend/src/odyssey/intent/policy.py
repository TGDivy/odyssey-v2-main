"""Deterministic silence-gate and intervention-delivery policy."""

from datetime import datetime, timedelta
from enum import StrEnum
from typing import cast

from pydantic import AwareDatetime, Field, model_validator

from odyssey.domain.common import StrictModel
from odyssey.intent.models import InterventionKind


class IntentActivityStatus(StrEnum):
    ACTIVE = "active"
    PAUSED = "paused"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    EXPIRED = "expired"


class InterventionUrgency(StrEnum):
    LOW = "low"
    NORMAL = "normal"
    HIGH = "high"
    CRITICAL = "critical"


class InterventionPurpose(StrEnum):
    USEFUL_ACTION = "useful_action"
    STREAK_RESCUE = "streak_rescue"
    OPEN_APP_ONLY = "open_app_only"


class DeliveryPolicy(StrEnum):
    SUPPRESS = "suppress"
    AMBIENT = "ambient"
    DEFER = "defer"
    DELIVER = "deliver"


class SilenceReason(StrEnum):
    EXPIRED = "EXPIRED"
    GLOBAL_PAUSE = "GLOBAL_PAUSE"
    INTENT_INACTIVE = "INTENT_INACTIVE"
    STATE_RECHECK_REQUIRED = "STATE_RECHECK_REQUIRED"
    DISQUALIFIER = "DISQUALIFIER"
    LOW_CONTEXT_CONFIDENCE = "LOW_CONTEXT_CONFIDENCE"
    ACTION_NOT_FEASIBLE = "ACTION_NOT_FEASIBLE"
    ALREADY_HANDLED = "ALREADY_HANDLED"
    RECENT_DISMISSAL = "RECENT_DISMISSAL"
    MORE_IMPORTANT_INTERVENTION_RECENT = "MORE_IMPORTANT_INTERVENTION_RECENT"
    IGNORED_COOLDOWN = "IGNORED_COOLDOWN"
    PURPOSE_NOT_ALLOWED = "PURPOSE_NOT_ALLOWED"
    NO_SAFE_OR_USEFUL_ACTION = "NO_SAFE_OR_USEFUL_ACTION"
    OBVIOUS_AMBIENTLY = "OBVIOUS_AMBIENTLY"
    NO_POSITIVE_EXPECTED_VALUE = "NO_POSITIVE_EXPECTED_VALUE"
    BUDGET_EXHAUSTED = "BUDGET_EXHAUSTED"
    LOW_STAKES_WINDOW_EXHAUSTED = "LOW_STAKES_WINDOW_EXHAUSTED"
    PROTECT_PRESENCE = "PROTECT_PRESENCE"
    INTERRUPTION_NOT_JUSTIFIED = "INTERRUPTION_NOT_JUSTIFIED"
    NO_EFFECTIVE_CHANNEL = "NO_EFFECTIVE_CHANNEL"
    STATE_RECHECKED = "STATE_RECHECKED"
    BENEFIT_POSITIVE = "BENEFIT_POSITIVE"
    INTERRUPTION_JUSTIFIED = "INTERRUPTION_JUSTIFIED"


class DeliveryChannelCandidate(StrictModel):
    kind: InterventionKind
    available: bool = True
    expected_effectiveness: float = Field(ge=0, le=1)
    interruptiveness: float = Field(ge=0, le=1)
    ambient: bool = False


class SilenceGatePolicy(StrictModel):
    minimum_context_confidence: float = Field(default=0.6, ge=0, le=1)
    visible_threshold: float = 0.15
    minimum_channel_effectiveness: float = Field(default=0.4, ge=0, le=1)
    ordinary_daily_visible_limit: int = Field(default=2, ge=0)
    low_stakes_window: timedelta = Field(default=timedelta(hours=3), gt=timedelta(0))
    ignored_base_cooldown: timedelta = Field(default=timedelta(hours=3), gt=timedelta(0))
    ignored_max_cooldown: timedelta = Field(default=timedelta(days=7), gt=timedelta(0))
    policy_version: str = "intent-policy-1.0"

    @model_validator(mode="after")
    def validate_cooldown_bounds(self) -> "SilenceGatePolicy":
        if self.ignored_max_cooldown < self.ignored_base_cooldown:
            raise ValueError("maximum ignored cooldown cannot be shorter than its base")
        return self


class InterventionEvaluation(StrictModel):
    now: AwareDatetime
    expires_at: AwareDatetime
    intent_status: IntentActivityStatus
    material_state_changed: bool = False
    recomputed_for_current_state: bool = False
    global_proactive_pause: bool = False
    disqualifiers_satisfied: tuple[str, ...] = ()
    context_confidence: float = Field(ge=0, le=1)
    action_feasible: bool = True
    already_handled: bool = False
    recently_dismissed: bool = False
    more_important_intervention_recent: bool = False
    ignored_count: int = Field(default=0, ge=0)
    last_ignored_at: AwareDatetime | None = None
    purpose: InterventionPurpose = InterventionPurpose.USEFUL_ACTION
    safe_useful_action_available: bool = True
    obvious_and_ambiently_visible: bool = False
    expected_benefit: float
    expected_interruption_cost: float = Field(ge=0)
    urgency: InterventionUrgency
    visible_deliveries_today: int = Field(default=0, ge=0)
    last_low_stakes_visible_at: AwareDatetime | None = None
    sensitive_or_social_moment: bool = False
    channels: tuple[DeliveryChannelCandidate, ...]

    @model_validator(mode="after")
    def validate_timeline(self) -> "InterventionEvaluation":
        for timestamp in (self.last_ignored_at, self.last_low_stakes_visible_at):
            if timestamp is not None and timestamp > self.now:
                raise ValueError("intervention history cannot be in the future")
        if self.ignored_count == 0 and self.last_ignored_at is not None:
            raise ValueError("last_ignored_at requires a positive ignored_count")
        return self


class InterventionPolicyResult(StrictModel):
    policy: DeliveryPolicy
    reason_codes: tuple[SilenceReason, ...]
    surface: InterventionKind | None = None
    expires_at: AwareDatetime
    policy_version: str
    explanation: tuple[str, ...] = Field(max_length=2)
    retry_after: AwareDatetime | None = None


_REASON_EXPLANATIONS: dict[SilenceReason, str] = {
    SilenceReason.EXPIRED: "The opportunity has expired.",
    SilenceReason.GLOBAL_PAUSE: "Proactive guidance is paused.",
    SilenceReason.INTENT_INACTIVE: "The underlying intent is not active.",
    SilenceReason.STATE_RECHECK_REQUIRED: "Material context changed and must be rechecked.",
    SilenceReason.DISQUALIFIER: "A configured exclusion condition applies.",
    SilenceReason.LOW_CONTEXT_CONFIDENCE: "Context confidence is too low for interruption.",
    SilenceReason.ACTION_NOT_FEASIBLE: "The action is no longer feasible.",
    SilenceReason.ALREADY_HANDLED: "The same advice was already handled.",
    SilenceReason.RECENT_DISMISSAL: "The same advice was dismissed recently.",
    SilenceReason.MORE_IMPORTANT_INTERVENTION_RECENT: "A more important intervention was recent.",
    SilenceReason.IGNORED_COOLDOWN: "Repeatedly ignored advice is cooling down.",
    SilenceReason.PURPOSE_NOT_ALLOWED: "This purpose does not justify a proactive interruption.",
    SilenceReason.NO_SAFE_OR_USEFUL_ACTION: "No safe and useful action is available.",
    SilenceReason.OBVIOUS_AMBIENTLY: "The suggestion is already obvious on an ambient surface.",
    SilenceReason.NO_POSITIVE_EXPECTED_VALUE: "Expected benefit is not positive.",
    SilenceReason.BUDGET_EXHAUSTED: "The ordinary visible-intervention budget is exhausted.",
    SilenceReason.LOW_STAKES_WINDOW_EXHAUSTED: "A low-stakes intervention was delivered recently.",
    SilenceReason.PROTECT_PRESENCE: "The current moment should remain interruption-free.",
    SilenceReason.INTERRUPTION_NOT_JUSTIFIED: "Expected benefit does not justify interruption.",
    SilenceReason.NO_EFFECTIVE_CHANNEL: "No available delivery channel is effective enough.",
    SilenceReason.STATE_RECHECKED: "Material context was rechecked before delivery.",
    SilenceReason.BENEFIT_POSITIVE: "Expected benefit is positive.",
    SilenceReason.INTERRUPTION_JUSTIFIED: "Expected benefit exceeds interruption cost.",
}


def decide_intervention(
    evaluation: InterventionEvaluation,
    policy: SilenceGatePolicy | None = None,
) -> InterventionPolicyResult:
    active_policy = policy or SilenceGatePolicy()

    if evaluation.now >= evaluation.expires_at:
        return _result(evaluation, active_policy, DeliveryPolicy.SUPPRESS, SilenceReason.EXPIRED)
    if evaluation.global_proactive_pause:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.GLOBAL_PAUSE,
        )
    if evaluation.intent_status is not IntentActivityStatus.ACTIVE:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.INTENT_INACTIVE,
        )
    if evaluation.material_state_changed and not evaluation.recomputed_for_current_state:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.STATE_RECHECK_REQUIRED,
        )
    if evaluation.disqualifiers_satisfied:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.DISQUALIFIER,
        )
    if evaluation.context_confidence < active_policy.minimum_context_confidence:
        return _ambient_or_suppress(
            evaluation,
            active_policy,
            SilenceReason.LOW_CONTEXT_CONFIDENCE,
        )
    if not evaluation.action_feasible:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.ACTION_NOT_FEASIBLE,
        )
    if evaluation.already_handled:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.ALREADY_HANDLED,
        )
    if evaluation.recently_dismissed:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.RECENT_DISMISSAL,
        )
    if evaluation.more_important_intervention_recent:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.MORE_IMPORTANT_INTERVENTION_RECENT,
        )

    cooldown_end = _ignored_cooldown_end(evaluation, active_policy)
    if cooldown_end is not None and evaluation.now < cooldown_end:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.IGNORED_COOLDOWN,
            retry_after=cooldown_end,
        )
    if evaluation.purpose is not InterventionPurpose.USEFUL_ACTION:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.PURPOSE_NOT_ALLOWED,
        )
    if not evaluation.safe_useful_action_available:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.NO_SAFE_OR_USEFUL_ACTION,
        )
    if evaluation.obvious_and_ambiently_visible:
        return _ambient_or_suppress(
            evaluation,
            active_policy,
            SilenceReason.OBVIOUS_AMBIENTLY,
        )
    if evaluation.expected_benefit <= 0:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.NO_POSITIVE_EXPECTED_VALUE,
        )

    ordinary_urgency = evaluation.urgency in {
        InterventionUrgency.LOW,
        InterventionUrgency.NORMAL,
    }
    if (
        ordinary_urgency
        and evaluation.visible_deliveries_today >= active_policy.ordinary_daily_visible_limit
    ):
        return _ambient_or_suppress(
            evaluation,
            active_policy,
            SilenceReason.BUDGET_EXHAUSTED,
        )
    if ordinary_urgency and evaluation.last_low_stakes_visible_at is not None:
        next_low_stakes_at = evaluation.last_low_stakes_visible_at + active_policy.low_stakes_window
        if evaluation.now < next_low_stakes_at:
            return _ambient_or_suppress(
                evaluation,
                active_policy,
                SilenceReason.LOW_STAKES_WINDOW_EXHAUSTED,
                retry_after=next_low_stakes_at,
            )
    if (
        evaluation.sensitive_or_social_moment
        and evaluation.urgency is not InterventionUrgency.CRITICAL
    ):
        ambient = _ambient_channel(evaluation, active_policy)
        if ambient is not None:
            return _result(
                evaluation,
                active_policy,
                DeliveryPolicy.AMBIENT,
                SilenceReason.PROTECT_PRESENCE,
                surface=ambient.kind,
            )
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.DEFER,
            SilenceReason.PROTECT_PRESENCE,
        )
    net_benefit = evaluation.expected_benefit - evaluation.expected_interruption_cost
    if net_benefit < active_policy.visible_threshold:
        return _ambient_or_suppress(
            evaluation,
            active_policy,
            SilenceReason.INTERRUPTION_NOT_JUSTIFIED,
        )

    selected_channel = _least_intrusive_effective_channel(evaluation, active_policy)
    if selected_channel is None:
        return _result(
            evaluation,
            active_policy,
            DeliveryPolicy.SUPPRESS,
            SilenceReason.NO_EFFECTIVE_CHANNEL,
        )
    reason_codes: list[SilenceReason] = []
    if evaluation.material_state_changed:
        reason_codes.append(SilenceReason.STATE_RECHECKED)
    reason_codes.extend((SilenceReason.BENEFIT_POSITIVE, SilenceReason.INTERRUPTION_JUSTIFIED))
    return _result(
        evaluation,
        active_policy,
        DeliveryPolicy.AMBIENT if selected_channel.ambient else DeliveryPolicy.DELIVER,
        *reason_codes,
        surface=selected_channel.kind,
    )


def _ignored_cooldown_end(
    evaluation: InterventionEvaluation,
    policy: SilenceGatePolicy,
) -> datetime | None:
    if evaluation.ignored_count == 0 or evaluation.last_ignored_at is None:
        return None
    multiplier = 2 ** min(evaluation.ignored_count - 1, 20)
    cooldown = min(policy.ignored_base_cooldown * multiplier, policy.ignored_max_cooldown)
    return cast(datetime, evaluation.last_ignored_at + cooldown)


def _least_intrusive_effective_channel(
    evaluation: InterventionEvaluation,
    policy: SilenceGatePolicy,
) -> DeliveryChannelCandidate | None:
    eligible = (
        channel
        for channel in evaluation.channels
        if channel.available
        and channel.expected_effectiveness >= policy.minimum_channel_effectiveness
    )
    return min(
        eligible,
        key=lambda channel: (channel.interruptiveness, channel.kind.value),
        default=None,
    )


def _ambient_channel(
    evaluation: InterventionEvaluation,
    policy: SilenceGatePolicy,
) -> DeliveryChannelCandidate | None:
    eligible = (
        channel
        for channel in evaluation.channels
        if channel.ambient
        and channel.available
        and channel.expected_effectiveness >= policy.minimum_channel_effectiveness
    )
    return min(
        eligible,
        key=lambda channel: (channel.interruptiveness, channel.kind.value),
        default=None,
    )


def _ambient_or_suppress(
    evaluation: InterventionEvaluation,
    policy: SilenceGatePolicy,
    reason: SilenceReason,
    *,
    retry_after: AwareDatetime | None = None,
) -> InterventionPolicyResult:
    ambient = _ambient_channel(evaluation, policy)
    if ambient is None:
        return _result(
            evaluation,
            policy,
            DeliveryPolicy.SUPPRESS,
            reason,
            retry_after=retry_after,
        )
    return _result(
        evaluation,
        policy,
        DeliveryPolicy.AMBIENT,
        reason,
        surface=ambient.kind,
        retry_after=retry_after,
    )


def _result(
    evaluation: InterventionEvaluation,
    policy: SilenceGatePolicy,
    decision: DeliveryPolicy,
    *reasons: SilenceReason,
    surface: InterventionKind | None = None,
    retry_after: AwareDatetime | None = None,
) -> InterventionPolicyResult:
    return InterventionPolicyResult(
        policy=decision,
        reason_codes=reasons,
        surface=surface,
        expires_at=evaluation.expires_at,
        policy_version=policy.policy_version,
        explanation=tuple(_REASON_EXPLANATIONS[reason] for reason in reasons[:2]),
        retry_after=retry_after,
    )
