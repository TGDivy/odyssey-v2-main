"""Deterministic standing-authority evaluation."""

from datetime import date, datetime, timedelta
from enum import StrEnum

from pydantic import AwareDatetime, Field

from odyssey.auth.models import (
    AuthorityLevel,
    PolicyDecision,
    PolicyOutcome,
    RevocationState,
    StandingAuthorization,
)
from odyssey.decision.models import Externality, Reversibility
from odyssey.domain.common import UUID7, ConfidenceBand, DataClass, StrictModel


class CostOfError(StrEnum):
    LOW = "low"
    MODERATE = "moderate"
    HIGH = "high"
    SEVERE = "severe"


class AuthorityRisk(StrEnum):
    COSTLY_OR_IRREVERSIBLE = "COSTLY_OR_IRREVERSIBLE"
    UNKNOWN_REVERSIBILITY = "UNKNOWN_REVERSIBILITY"
    EXTERNAL_CONSEQUENCE = "EXTERNAL_CONSEQUENCE"
    OTHER_PERSON_AFFECTED = "OTHER_PERSON_AFFECTED"
    MATERIAL_COST = "MATERIAL_COST"
    HIGH_SENSITIVITY = "HIGH_SENSITIVITY"
    LOW_RECOMMENDATION_CONFIDENCE = "LOW_RECOMMENDATION_CONFIDENCE"
    HIGH_COST_OF_ERROR = "HIGH_COST_OF_ERROR"
    EXTERNAL_ACTIONS_PAUSED = "EXTERNAL_ACTIONS_PAUSED"
    MATERIAL_CONTEXT_MISSING = "MATERIAL_CONTEXT_MISSING"
    STANDING_AUTHORITY_DISABLED = "STANDING_AUTHORITY_DISABLED"
    AUTHORIZATION_SCOPE_TOO_BROAD = "AUTHORIZATION_SCOPE_TOO_BROAD"
    AUTHORIZATION_REVIEW_OVERDUE = "AUTHORIZATION_REVIEW_OVERDUE"
    AUTHORIZATION_LIMIT_EXCEEDED = "AUTHORIZATION_LIMIT_EXCEEDED"
    AUTHORIZATION_LIMIT_NOT_EVALUATED = "AUTHORIZATION_LIMIT_NOT_EVALUATED"
    EXPLICIT_CONFIRMATION_REQUIRED = "EXPLICIT_CONFIRMATION_REQUIRED"


class ActionRequest(StrictModel):
    requested_action: str = Field(min_length=1, max_length=2_000)
    capability: str = Field(min_length=1, max_length=200)
    action_class: str = Field(min_length=1, max_length=200)
    resource: str = Field(min_length=1, max_length=1_000)
    base_authority: AuthorityLevel
    reversibility: Reversibility
    externality: Externality
    sensitivity: DataClass
    financial_or_contractual_cost: float = Field(default=0, ge=0)
    recommendation_confidence: ConfidenceBand
    affects_other_person: bool = False
    cost_of_error: CostOfError = CostOfError.LOW
    always_requires_confirmation: bool = False


class AuthorityContext(StrictModel):
    context_snapshot_id: UUID7
    now: AwareDatetime
    satisfied_conditions: frozenset[str] = frozenset()
    material_context_complete: bool = True
    global_external_actions_paused: bool = False
    anomalous_behavior_detected: bool = False
    material_model_change: bool = False


class AuthorizationLimitAssessment(StrictModel):
    authorization_id: UUID7
    within_limit: bool


class AuthorityPolicy(StrictModel):
    maximum_review_age: timedelta = Field(default=timedelta(days=180), gt=timedelta(0))
    policy_version: str = "authority-policy-1.0"


def required_authority(action: ActionRequest) -> tuple[AuthorityLevel, tuple[AuthorityRisk, ...]]:
    required = action.base_authority
    risks: list[AuthorityRisk] = []

    if action.reversibility in {Reversibility.COSTLY_TO_REVERSE, Reversibility.IRREVERSIBLE}:
        risks.append(AuthorityRisk.COSTLY_OR_IRREVERSIBLE)
    elif action.reversibility is Reversibility.UNKNOWN:
        risks.append(AuthorityRisk.UNKNOWN_REVERSIBILITY)
    if action.externality is not Externality.PRIVATE:
        risks.append(AuthorityRisk.EXTERNAL_CONSEQUENCE)
    if action.affects_other_person:
        risks.append(AuthorityRisk.OTHER_PERSON_AFFECTED)
    if action.financial_or_contractual_cost > 0:
        risks.append(AuthorityRisk.MATERIAL_COST)
    if action.sensitivity in {DataClass.HIGHLY_SENSITIVE, DataClass.OPERATIONAL_SECRET}:
        risks.append(AuthorityRisk.HIGH_SENSITIVITY)
    if action.recommendation_confidence in {ConfidenceBand.VERY_LOW, ConfidenceBand.LOW}:
        risks.append(AuthorityRisk.LOW_RECOMMENDATION_CONFIDENCE)
    if action.cost_of_error in {CostOfError.HIGH, CostOfError.SEVERE}:
        risks.append(AuthorityRisk.HIGH_COST_OF_ERROR)

    if required >= AuthorityLevel.EXECUTE_REVERSIBLE and risks:
        required = AuthorityLevel.COMMIT_EXTERNAL
    return required, tuple(risks)


def authorize_action(
    *,
    decision_id: UUID7,
    action: ActionRequest,
    context: AuthorityContext,
    authorizations: tuple[StandingAuthorization, ...] = (),
    limit_assessments: tuple[AuthorizationLimitAssessment, ...] = (),
    policy: AuthorityPolicy | None = None,
) -> PolicyDecision:
    active_policy = policy or AuthorityPolicy()
    required, derived_risks = required_authority(action)
    risks = list(derived_risks)

    external_execution = (
        action.externality is not Externality.PRIVATE
        and action.base_authority >= AuthorityLevel.EXECUTE_REVERSIBLE
    )
    if context.global_external_actions_paused and external_execution:
        risks.append(AuthorityRisk.EXTERNAL_ACTIONS_PAUSED)
        return _decision(
            decision_id=decision_id,
            action=action,
            context=context,
            required=required,
            outcome=PolicyOutcome.DENY,
            risks=risks,
            explanation="External actions are paused by the owner.",
            policy=active_policy,
        )
    if not context.material_context_complete and required >= AuthorityLevel.EXECUTE_REVERSIBLE:
        risks.append(AuthorityRisk.MATERIAL_CONTEXT_MISSING)
        return _decision(
            decision_id=decision_id,
            action=action,
            context=context,
            required=required,
            outcome=PolicyOutcome.DEFER,
            risks=risks,
            explanation="Material context is missing; execution is deferred.",
            policy=active_policy,
        )

    standing_disabled = context.anomalous_behavior_detected or context.material_model_change
    if standing_disabled:
        risks.append(AuthorityRisk.STANDING_AUTHORITY_DISABLED)
        matching: tuple[StandingAuthorization, ...] = ()
        match_risks: tuple[AuthorityRisk, ...] = ()
    else:
        matching, match_risks = _matching_authorizations(
            action=action,
            context=context,
            authorizations=authorizations,
            required=required,
            policy=active_policy,
        )
        risks.extend(match_risks)

    matching_ids = tuple(sorted((item.metadata.id for item in matching), key=str))
    if action.always_requires_confirmation or required >= AuthorityLevel.COMMIT_EXTERNAL:
        risks.append(AuthorityRisk.EXPLICIT_CONFIRMATION_REQUIRED)
        return _decision(
            decision_id=decision_id,
            action=action,
            context=context,
            required=required,
            outcome=PolicyOutcome.REQUIRE_CONFIRMATION,
            risks=risks,
            authorization_refs=matching_ids,
            explanation="This action requires explicit contemporaneous confirmation.",
            policy=active_policy,
        )
    if not matching:
        if required <= AuthorityLevel.INFORM:
            return _decision(
                decision_id=decision_id,
                action=action,
                context=context,
                required=required,
                outcome=PolicyOutcome.ALLOW,
                risks=risks,
                explanation="Informational action is allowed without standing execution authority.",
                policy=active_policy,
            )
        return _decision(
            decision_id=decision_id,
            action=action,
            context=context,
            required=required,
            outcome=PolicyOutcome.REQUIRE_CONFIRMATION,
            risks=risks,
            explanation="No active standing authorization covers this action.",
            policy=active_policy,
        )

    assessments = {assessment.authorization_id: assessment for assessment in limit_assessments}
    usable_authorizations: list[StandingAuthorization] = []
    limit_risks: list[AuthorityRisk] = []
    for authorization in matching:
        if authorization.max_frequency_or_amount is None:
            usable_authorizations.append(authorization)
            continue
        assessment = assessments.get(authorization.metadata.id)
        if assessment is None:
            limit_risks.append(AuthorityRisk.AUTHORIZATION_LIMIT_NOT_EVALUATED)
        elif assessment.within_limit:
            usable_authorizations.append(authorization)
        else:
            limit_risks.append(AuthorityRisk.AUTHORIZATION_LIMIT_EXCEEDED)

    if not usable_authorizations:
        risks.extend(limit_risks)
        return _decision(
            decision_id=decision_id,
            action=action,
            context=context,
            required=required,
            outcome=PolicyOutcome.REQUIRE_CONFIRMATION,
            risks=risks,
            authorization_refs=matching_ids,
            explanation=(
                "Standing authorization limits do not permit this action without confirmation."
            ),
            policy=active_policy,
        )

    usable_ids = tuple(sorted((item.metadata.id for item in usable_authorizations), key=str))
    return _decision(
        decision_id=decision_id,
        action=action,
        context=context,
        required=required,
        outcome=PolicyOutcome.ALLOW,
        risks=risks,
        authorization_refs=usable_ids,
        explanation="A current, scoped standing authorization permits this reversible action.",
        policy=active_policy,
    )


def _matching_authorizations(
    *,
    action: ActionRequest,
    context: AuthorityContext,
    authorizations: tuple[StandingAuthorization, ...],
    required: AuthorityLevel,
    policy: AuthorityPolicy,
) -> tuple[tuple[StandingAuthorization, ...], tuple[AuthorityRisk, ...]]:
    matching: list[StandingAuthorization] = []
    risks: list[AuthorityRisk] = []
    for authorization in authorizations:
        if authorization.metadata.tombstoned_at is not None:
            continue
        if authorization.revocation_state is not RevocationState.ACTIVE:
            continue
        if not _contains(authorization, context.now):
            continue
        if context.now - authorization.last_reviewed_at > policy.maximum_review_age:
            risks.append(AuthorityRisk.AUTHORIZATION_REVIEW_OVERDUE)
            continue
        if authorization.capability != action.capability:
            continue
        if authorization.action_class != action.action_class:
            continue
        if authorization.resource_scope == "*" and required > AuthorityLevel.RECOMMEND:
            risks.append(AuthorityRisk.AUTHORIZATION_SCOPE_TOO_BROAD)
            continue
        if not _scope_contains(authorization.resource_scope, action.resource):
            continue
        if authorization.authority_level < required:
            continue
        if not set(authorization.required_conditions).issubset(context.satisfied_conditions):
            continue
        if set(authorization.prohibited_conditions) & context.satisfied_conditions:
            continue
        matching.append(authorization)
    return tuple(matching), tuple(dict.fromkeys(risks))


def _contains(authorization: StandingAuthorization, now: datetime) -> bool:
    interval = authorization.valid_interval
    if interval.start is not None and _compare_time(now, interval.start) < 0:
        return False
    return interval.end is None or _compare_time(now, interval.end) <= 0


def _compare_time(now: datetime, boundary: date | datetime) -> int:
    current: date | datetime = now if isinstance(boundary, datetime) else now.date()
    return (current > boundary) - (current < boundary)


def _scope_contains(scope: str, resource: str) -> bool:
    if scope == "*":
        return True
    if scope.endswith("/*"):
        prefix = scope[:-2].rstrip("/")
        return resource == prefix or resource.startswith(f"{prefix}/")
    return scope == resource


def _decision(
    *,
    decision_id: UUID7,
    action: ActionRequest,
    context: AuthorityContext,
    required: AuthorityLevel,
    outcome: PolicyOutcome,
    risks: list[AuthorityRisk],
    explanation: str,
    policy: AuthorityPolicy,
    authorization_refs: tuple[UUID7, ...] = (),
) -> PolicyDecision:
    return PolicyDecision(
        id=decision_id,
        requested_action=action.requested_action,
        context_snapshot_id=context.context_snapshot_id,
        authority_required=required,
        authorization_refs=authorization_refs,
        risk_factors=tuple(dict.fromkeys(risk.value for risk in risks)),
        decision=outcome,
        explanation=explanation,
        policy_version=policy.policy_version,
    )
