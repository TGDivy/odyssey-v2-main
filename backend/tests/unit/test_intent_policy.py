from datetime import UTC, datetime, timedelta

import pytest
from pydantic import ValidationError

from odyssey.intent.models import InterventionKind
from odyssey.intent.policy import (
    DeliveryChannelCandidate,
    DeliveryPolicy,
    IntentActivityStatus,
    InterventionEvaluation,
    InterventionPurpose,
    InterventionUrgency,
    SilenceGatePolicy,
    SilenceReason,
    decide_intervention,
)

NOW = datetime(2026, 8, 15, 12, tzinfo=UTC)


def channel(
    kind: InterventionKind,
    *,
    ambient: bool,
    interruptiveness: float,
    effectiveness: float = 0.8,
    available: bool = True,
) -> DeliveryChannelCandidate:
    return DeliveryChannelCandidate(
        kind=kind,
        available=available,
        expected_effectiveness=effectiveness,
        interruptiveness=interruptiveness,
        ambient=ambient,
    )


def evaluation(**overrides: object) -> InterventionEvaluation:
    values: dict[str, object] = {
        "now": NOW,
        "expires_at": NOW + timedelta(hours=1),
        "intent_status": IntentActivityStatus.ACTIVE,
        "context_confidence": 0.9,
        "expected_benefit": 0.8,
        "expected_interruption_cost": 0.2,
        "urgency": InterventionUrgency.NORMAL,
        "channels": (
            channel(
                InterventionKind.LOCAL_NOTIFICATION,
                ambient=False,
                interruptiveness=0.8,
            ),
        ),
    }
    values.update(overrides)
    return InterventionEvaluation.model_validate(values)


@pytest.mark.parametrize(
    ("overrides", "reason"),
    [
        ({"expires_at": NOW}, SilenceReason.EXPIRED),
        ({"global_proactive_pause": True}, SilenceReason.GLOBAL_PAUSE),
        ({"intent_status": IntentActivityStatus.PAUSED}, SilenceReason.INTENT_INACTIVE),
        (
            {"material_state_changed": True, "recomputed_for_current_state": False},
            SilenceReason.STATE_RECHECK_REQUIRED,
        ),
        ({"disqualifiers_satisfied": ("driving",)}, SilenceReason.DISQUALIFIER),
        ({"action_feasible": False}, SilenceReason.ACTION_NOT_FEASIBLE),
        ({"already_handled": True}, SilenceReason.ALREADY_HANDLED),
        ({"recently_dismissed": True}, SilenceReason.RECENT_DISMISSAL),
        (
            {"more_important_intervention_recent": True},
            SilenceReason.MORE_IMPORTANT_INTERVENTION_RECENT,
        ),
        ({"purpose": InterventionPurpose.STREAK_RESCUE}, SilenceReason.PURPOSE_NOT_ALLOWED),
        ({"purpose": InterventionPurpose.OPEN_APP_ONLY}, SilenceReason.PURPOSE_NOT_ALLOWED),
        ({"safe_useful_action_available": False}, SilenceReason.NO_SAFE_OR_USEFUL_ACTION),
        ({"expected_benefit": 0}, SilenceReason.NO_POSITIVE_EXPECTED_VALUE),
    ],
)
def test_hard_suppressions(overrides: dict[str, object], reason: SilenceReason) -> None:
    result = decide_intervention(evaluation(**overrides))

    assert result.policy is DeliveryPolicy.SUPPRESS
    assert result.reason_codes == (reason,)
    assert len(result.explanation) <= 2


def test_low_confidence_uses_ambient_surface_when_available() -> None:
    result = decide_intervention(
        evaluation(
            context_confidence=0.2,
            channels=(
                channel(InterventionKind.WIDGET, ambient=True, interruptiveness=0.05),
                channel(
                    InterventionKind.LOCAL_NOTIFICATION,
                    ambient=False,
                    interruptiveness=0.8,
                ),
            ),
        )
    )

    assert result.policy is DeliveryPolicy.AMBIENT
    assert result.surface is InterventionKind.WIDGET
    assert result.reason_codes == (SilenceReason.LOW_CONTEXT_CONFIDENCE,)


def test_ordinary_budget_does_not_block_high_urgency() -> None:
    ordinary = decide_intervention(evaluation(visible_deliveries_today=2))
    high = decide_intervention(
        evaluation(
            visible_deliveries_today=2,
            urgency=InterventionUrgency.HIGH,
        )
    )

    assert ordinary.policy is DeliveryPolicy.SUPPRESS
    assert ordinary.reason_codes == (SilenceReason.BUDGET_EXHAUSTED,)
    assert high.policy is DeliveryPolicy.DELIVER


def test_low_stakes_window_returns_retry_time() -> None:
    result = decide_intervention(
        evaluation(last_low_stakes_visible_at=NOW - timedelta(hours=1))
    )

    assert result.policy is DeliveryPolicy.SUPPRESS
    assert result.reason_codes == (SilenceReason.LOW_STAKES_WINDOW_EXHAUSTED,)
    assert result.retry_after == NOW + timedelta(hours=2)


def test_ignored_advice_enters_bounded_exponential_cooldown() -> None:
    policy = SilenceGatePolicy(
        ignored_base_cooldown=timedelta(hours=1),
        ignored_max_cooldown=timedelta(hours=8),
    )
    result = decide_intervention(
        evaluation(ignored_count=5, last_ignored_at=NOW - timedelta(hours=2)),
        policy,
    )

    assert result.policy is DeliveryPolicy.SUPPRESS
    assert result.reason_codes == (SilenceReason.IGNORED_COOLDOWN,)
    assert result.retry_after == NOW + timedelta(hours=6)


def test_protected_social_moment_defers_without_ambient_surface() -> None:
    result = decide_intervention(evaluation(sensitive_or_social_moment=True))

    assert result.policy is DeliveryPolicy.DEFER
    assert result.surface is None
    assert result.reason_codes == (SilenceReason.PROTECT_PRESENCE,)


def test_critical_urgency_can_pass_protected_moment_gate() -> None:
    result = decide_intervention(
        evaluation(
            sensitive_or_social_moment=True,
            urgency=InterventionUrgency.CRITICAL,
        )
    )

    assert result.policy is DeliveryPolicy.DELIVER


def test_least_intrusive_effective_channel_is_selected() -> None:
    result = decide_intervention(
        evaluation(
            material_state_changed=True,
            recomputed_for_current_state=True,
            channels=(
                channel(
                    InterventionKind.LOCAL_NOTIFICATION,
                    ambient=False,
                    interruptiveness=0.8,
                ),
                channel(InterventionKind.WATCH, ambient=False, interruptiveness=0.3),
                channel(
                    InterventionKind.WIDGET,
                    ambient=True,
                    interruptiveness=0.05,
                    effectiveness=0.2,
                ),
            ),
        )
    )

    assert result.policy is DeliveryPolicy.DELIVER
    assert result.surface is InterventionKind.WATCH
    assert result.reason_codes == (
        SilenceReason.STATE_RECHECKED,
        SilenceReason.BENEFIT_POSITIVE,
        SilenceReason.INTERRUPTION_JUSTIFIED,
    )
    assert len(result.explanation) == 2


def test_invalid_history_is_rejected() -> None:
    with pytest.raises(ValidationError, match="positive ignored_count"):
        evaluation(last_ignored_at=NOW - timedelta(minutes=1))
