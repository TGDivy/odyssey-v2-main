"""Typed adapters that replay golden cases against production policy functions."""

from collections.abc import Callable
from typing import cast

from pydantic import AwareDatetime, JsonValue

from odyssey.auth.models import StandingAuthorization
from odyssey.auth.policy import (
    ActionRequest,
    AuthorityContext,
    AuthorityPolicy,
    AuthorizationLimitAssessment,
    authorize_action,
)
from odyssey.decision.recommendation_policy import (
    RecommendationEvidenceProfile,
    maximum_recommendation_strength,
)
from odyssey.domain.alignment import DayAlignmentInput, DayAlignmentPolicy, day_alignment
from odyssey.domain.common import UUID7, StrictModel
from odyssey.evaluation.contracts import GoldenReplayAdapter, GoldenReplayCase
from odyssey.evidence.pattern_policy import PatternCandidate, PatternPolicy, assess_pattern
from odyssey.intent.policy import (
    InterventionEvaluation,
    SilenceGatePolicy,
    decide_intervention,
)
from odyssey.intent.reentry import (
    MaterialChange,
    ReentryOpportunity,
    ReentryPolicy,
    build_reentry,
)


class IntentReplayInput(StrictModel):
    evaluation: InterventionEvaluation
    policy: SilenceGatePolicy | None = None


class RecommendationReplayInput(StrictModel):
    profile: RecommendationEvidenceProfile


class PatternReplayInput(StrictModel):
    candidate: PatternCandidate
    policy: PatternPolicy | None = None


class AlignmentReplayInput(StrictModel):
    day: DayAlignmentInput
    policy: DayAlignmentPolicy | None = None


class ReentryReplayInput(StrictModel):
    last_seen: AwareDatetime
    now: AwareDatetime
    changes: tuple[MaterialChange, ...]
    opportunities: tuple[ReentryOpportunity, ...]
    policy: ReentryPolicy | None = None


class AuthorityReplayInput(StrictModel):
    decision_id: UUID7
    action: ActionRequest
    context: AuthorityContext
    authorizations: tuple[StandingAuthorization, ...] = ()
    limit_assessments: tuple[AuthorizationLimitAssessment, ...] = ()
    policy: AuthorityPolicy | None = None


def execute_golden_replay(case: GoldenReplayCase) -> dict[str, JsonValue]:
    result: StrictModel
    if case.adapter is GoldenReplayAdapter.INTENT_POLICY:
        intent_replay = IntentReplayInput.model_validate(case.input)
        result = decide_intervention(intent_replay.evaluation, intent_replay.policy)
    elif case.adapter is GoldenReplayAdapter.RECOMMENDATION_STRENGTH:
        recommendation_replay = RecommendationReplayInput.model_validate(case.input)
        result = maximum_recommendation_strength(recommendation_replay.profile)
    elif case.adapter is GoldenReplayAdapter.PATTERN_PROMOTION:
        pattern_replay = PatternReplayInput.model_validate(case.input)
        result = assess_pattern(pattern_replay.candidate, pattern_replay.policy)
    elif case.adapter is GoldenReplayAdapter.DAY_ALIGNMENT:
        alignment_replay = AlignmentReplayInput.model_validate(case.input)
        result = day_alignment(alignment_replay.day, alignment_replay.policy)
    elif case.adapter is GoldenReplayAdapter.REENTRY:
        reentry_replay = ReentryReplayInput.model_validate(case.input)
        result = build_reentry(
            last_seen=reentry_replay.last_seen,
            now=reentry_replay.now,
            changes=reentry_replay.changes,
            opportunities=reentry_replay.opportunities,
            policy=reentry_replay.policy,
        )
    else:
        authority_replay = AuthorityReplayInput.model_validate(case.input)
        result = authorize_action(
            decision_id=authority_replay.decision_id,
            action=authority_replay.action,
            context=authority_replay.context,
            authorizations=authority_replay.authorizations,
            limit_assessments=authority_replay.limit_assessments,
            policy=authority_replay.policy,
        )
    return cast(dict[str, JsonValue], result.model_dump(mode="json"))


def assert_golden_invariants(case: GoldenReplayCase, output: dict[str, JsonValue]) -> None:
    checks: dict[str, Callable[[dict[str, JsonValue]], bool]] = {
        "authority_not_exceeded": _authority_not_exceeded,
        "backlog_suppressed": lambda value: value.get("suppress_backlog") is True,
        "experiment_disabled": lambda value: value.get("status") == "experiment_disabled",
        "external_confirmation_required": (
            lambda value: value.get("decision") == "require_confirmation"
        ),
        "global_pause_reason": lambda value: value.get("reason_codes") == ["GLOBAL_PAUSE"],
        "no_absence_penalty": lambda value: value.get("no_absence_penalty") is True,
        "observational_language_restricted": (
            lambda value: "works for you" in _string_list(value.get("prohibited_phrases"))
        ),
        "pattern_not_surfaced": (
            lambda value: value.get("promotion") in {"do_not_surface", "insufficient_data"}
        ),
        "policy_suppresses": lambda value: value.get("policy") == "suppress",
        "protect_presence": (
            lambda value: "PROTECT_PRESENCE" in _string_list(value.get("reason_codes"))
        ),
        "strength_not_above_weak": (
            lambda value: value.get("maximum_strength") in {"insufficient", "weak"}
        ),
    }
    for invariant in case.expected_invariants:
        check = checks.get(invariant)
        if check is None:
            raise ValueError(f"unknown golden invariant: {invariant}")
        if not check(output):
            raise AssertionError(f"golden invariant failed for {case.case_id}: {invariant}")


def _authority_not_exceeded(output: dict[str, JsonValue]) -> bool:
    return output.get("decision") in {"require_confirmation", "deny", "defer"}


def _string_list(value: JsonValue | None) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        return ()
    return tuple(cast(list[str], value))
