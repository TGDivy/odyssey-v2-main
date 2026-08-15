from datetime import UTC, datetime, timedelta

import pytest
from pydantic import ValidationError

from odyssey.domain.common import new_uuid7
from odyssey.intent.reentry import (
    MaterialChange,
    ReentryOpportunity,
    ReentryOption,
    ReentryReason,
    build_reentry,
    should_enter_reentry,
)

NOW = datetime(2026, 8, 15, 12, tzinfo=UTC)
LAST_SEEN = NOW - timedelta(days=5)


def change(
    summary: str,
    *,
    relevance: float,
    occurred_at: datetime | None = None,
    **overrides: object,
) -> MaterialChange:
    values: dict[str, object] = {
        "id": new_uuid7(),
        "occurred_at": occurred_at or NOW - timedelta(days=1),
        "summary": summary,
        "relevance": relevance,
    }
    values.update(overrides)
    return MaterialChange.model_validate(values)


def test_reentry_activates_only_after_absence_threshold() -> None:
    assert should_enter_reentry(last_seen=LAST_SEEN, now=NOW) is True
    assert should_enter_reentry(last_seen=NOW - timedelta(days=2), now=NOW) is False
    assert should_enter_reentry(last_seen=None, now=NOW) is False


def test_reentry_summarizes_at_most_three_current_material_changes() -> None:
    changes = (
        change("Highest relevance", relevance=0.95),
        change("Second relevance", relevance=0.9),
        change("Third relevance", relevance=0.8),
        change("Fourth relevance", relevance=0.7),
        change("Too weak", relevance=0.2),
        change("No longer relevant", relevance=1, currently_relevant=False),
        change("Before absence", relevance=1, occurred_at=LAST_SEEN - timedelta(days=1)),
    )

    surface = build_reentry(
        last_seen=LAST_SEEN,
        now=NOW,
        changes=changes,
        opportunities=(),
    )

    assert tuple(item.summary for item in surface.summary) == (
        "Highest relevance",
        "Second relevance",
        "Third relevance",
    )
    assert len(surface.summary) == 3


def test_only_highest_value_material_clarification_is_asked() -> None:
    surface = build_reentry(
        last_seen=LAST_SEEN,
        now=NOW,
        changes=(
            change(
                "Season changed",
                relevance=0.9,
                unresolved=True,
                clarification_question="Revise the season?",
                clarification_value=0.7,
            ),
            change(
                "Travel changed",
                relevance=0.8,
                unresolved=True,
                clarification_question="Are the travel dates still right?",
                clarification_value=0.95,
            ),
        ),
        opportunities=(),
    )

    assert surface.one_question == "Are the travel dates still right?"
    assert ReentryReason.ONE_CLARIFICATION_SELECTED in surface.reason_codes


def test_stale_active_opportunities_expire_without_becoming_backlog() -> None:
    expired = new_uuid7()
    inactive = new_uuid7()
    future = new_uuid7()
    surface = build_reentry(
        last_seen=LAST_SEEN,
        now=NOW,
        changes=(),
        opportunities=(
            ReentryOpportunity(id=expired, expires_at=NOW - timedelta(minutes=1)),
            ReentryOpportunity(
                id=inactive,
                expires_at=NOW - timedelta(days=1),
                active=False,
            ),
            ReentryOpportunity(id=future, expires_at=NOW + timedelta(hours=1)),
        ),
    )

    assert surface.expired_opportunity_ids == (expired,)
    assert surface.suppress_backlog is True
    assert ReentryReason.STALE_OPPORTUNITIES_EXPIRED in surface.reason_codes


def test_surface_guarantees_clean_options_and_no_absence_penalty() -> None:
    surface = build_reentry(
        last_seen=LAST_SEEN,
        now=NOW,
        changes=(),
        opportunities=(),
    )

    assert surface.options == (
        ReentryOption.CONTINUE,
        ReentryOption.REVISE_SEASON,
        ReentryOption.STAY_QUIET,
    )
    assert surface.no_absence_penalty is True
    assert surface.summary == ()
    assert surface.one_question is None
    assert ReentryReason.NO_CURRENT_MATERIAL_CHANGE in surface.reason_codes
    assert surface.policy_version == "reentry-policy-1.0"


def test_future_last_seen_is_rejected() -> None:
    with pytest.raises(ValueError, match="future"):
        build_reentry(
            last_seen=NOW + timedelta(seconds=1),
            now=NOW,
            changes=(),
            opportunities=(),
        )


def test_clarification_value_without_question_is_rejected() -> None:
    with pytest.raises(ValidationError, match="requires a clarification question"):
        change("Changed", relevance=0.8, clarification_value=0.5)
