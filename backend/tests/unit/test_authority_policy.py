from datetime import UTC, datetime, timedelta
from uuid import uuid4

from odyssey.auth.models import (
    AuthorityLevel,
    PolicyOutcome,
    RevocationState,
    StandingAuthorization,
)
from odyssey.auth.policy import (
    ActionRequest,
    AuthorityContext,
    AuthorityRisk,
    AuthorizationLimitAssessment,
    CostOfError,
    authorize_action,
    required_authority,
)
from odyssey.decision.models import Externality, Reversibility
from odyssey.domain.common import (
    ActorRef,
    ActorType,
    ConfidenceBand,
    DataClass,
    EntityMetadata,
    TemporalInterval,
    TemporalPrecision,
    new_uuid7,
)

NOW = datetime(2026, 8, 15, 12, tzinfo=UTC)


def metadata() -> EntityMetadata:
    return EntityMetadata(
        id=new_uuid7(),
        schema_version=1,
        created_at=NOW - timedelta(days=30),
        created_by=ActorRef(actor_type=ActorType.USER, actor_id="owner"),
        last_revised_at=NOW - timedelta(days=1),
        revision=1,
        sensitivity=DataClass.PRIVATE,
        provenance_id=uuid4(),
    )


def action(**overrides: object) -> ActionRequest:
    values: dict[str, object] = {
        "requested_action": "Create a private tentative preparation block.",
        "capability": "calendar",
        "action_class": "create_tentative_block",
        "resource": "calendar/odyssey",
        "base_authority": AuthorityLevel.EXECUTE_REVERSIBLE,
        "reversibility": Reversibility.REVERSIBLE,
        "externality": Externality.PRIVATE,
        "sensitivity": DataClass.PRIVATE,
        "recommendation_confidence": ConfidenceBand.HIGH,
    }
    values.update(overrides)
    return ActionRequest.model_validate(values)


def context(**overrides: object) -> AuthorityContext:
    values: dict[str, object] = {
        "context_snapshot_id": new_uuid7(),
        "now": NOW,
    }
    values.update(overrides)
    return AuthorityContext.model_validate(values)


def authorization(**overrides: object) -> StandingAuthorization:
    values: dict[str, object] = {
        "metadata": metadata(),
        "capability": "calendar",
        "action_class": "create_tentative_block",
        "resource_scope": "calendar/odyssey",
        "valid_interval": TemporalInterval(
            start=NOW - timedelta(days=30),
            end=NOW + timedelta(days=30),
            start_precision=TemporalPrecision.EXACT,
            end_precision=TemporalPrecision.EXACT,
        ),
        "authority_level": AuthorityLevel.EXECUTE_REVERSIBLE,
        "revocation_state": RevocationState.ACTIVE,
        "last_reviewed_at": NOW - timedelta(days=10),
    }
    values.update(overrides)
    return StandingAuthorization.model_validate(values)


def decide(
    requested_action: ActionRequest,
    authority_context: AuthorityContext,
    *authorizations: StandingAuthorization,
    limit_assessments: tuple[AuthorizationLimitAssessment, ...] = (),
):
    return authorize_action(
        decision_id=new_uuid7(),
        action=requested_action,
        context=authority_context,
        authorizations=authorizations,
        limit_assessments=limit_assessments,
    )


def test_private_reversible_action_with_narrow_grant_is_allowed_and_auditable() -> None:
    grant = authorization(
        resource_scope="calendar/*",
        required_conditions=("season_active",),
    )
    result = decide(
        action(),
        context(satisfied_conditions=frozenset({"season_active"})),
        grant,
    )

    assert result.decision is PolicyOutcome.ALLOW
    assert result.authority_required is AuthorityLevel.EXECUTE_REVERSIBLE
    assert result.authorization_refs == (grant.metadata.id,)
    assert result.policy_version == "authority-policy-1.0"


def test_external_action_requires_confirmation_even_with_matching_grant() -> None:
    requested_action = action(
        requested_action="Move an accepted meeting.",
        action_class="move_accepted_meeting",
        resource="calendar/team",
        externality=Externality.AFFECTS_KNOWN_PEOPLE,
        affects_other_person=True,
    )
    grant = authorization(
        action_class="move_accepted_meeting",
        resource_scope="calendar/team",
        authority_level=AuthorityLevel.COMMIT_EXTERNAL,
    )
    result = decide(requested_action, context(), grant)

    assert result.decision is PolicyOutcome.REQUIRE_CONFIRMATION
    assert result.authority_required is AuthorityLevel.COMMIT_EXTERNAL
    assert AuthorityRisk.EXPLICIT_CONFIRMATION_REQUIRED in result.risk_factors
    assert grant.metadata.id in result.authorization_refs


def test_informational_action_does_not_require_standing_execution_authority() -> None:
    result = decide(
        action(
            requested_action="Show that the interview is in 48 hours.",
            capability="context",
            action_class="show_fact",
            resource="decision/interview",
            base_authority=AuthorityLevel.INFORM,
        ),
        context(),
    )

    assert result.decision is PolicyOutcome.ALLOW
    assert result.authorization_refs == ()


def test_missing_execution_context_defers_before_authority_matching() -> None:
    result = decide(action(), context(material_context_complete=False), authorization())

    assert result.decision is PolicyOutcome.DEFER
    assert AuthorityRisk.MATERIAL_CONTEXT_MISSING in result.risk_factors


def test_global_pause_denies_external_execution() -> None:
    result = decide(
        action(externality=Externality.AFFECTS_KNOWN_PEOPLE),
        context(global_external_actions_paused=True),
    )

    assert result.decision is PolicyOutcome.DENY
    assert AuthorityRisk.EXTERNAL_ACTIONS_PAUSED in result.risk_factors


def test_material_model_change_disables_standing_authority() -> None:
    result = decide(action(), context(material_model_change=True), authorization())

    assert result.decision is PolicyOutcome.REQUIRE_CONFIRMATION
    assert AuthorityRisk.STANDING_AUTHORITY_DISABLED in result.risk_factors
    assert result.authorization_refs == ()


def test_broad_execution_grant_is_rejected() -> None:
    result = decide(action(), context(), authorization(resource_scope="*"))

    assert result.decision is PolicyOutcome.REQUIRE_CONFIRMATION
    assert AuthorityRisk.AUTHORIZATION_SCOPE_TOO_BROAD in result.risk_factors


def test_expired_revoked_or_prohibited_grants_do_not_match() -> None:
    expired = authorization(
        valid_interval=TemporalInterval(
            start=NOW - timedelta(days=3),
            end=NOW - timedelta(days=1),
            start_precision=TemporalPrecision.EXACT,
            end_precision=TemporalPrecision.EXACT,
        )
    )
    revoked = authorization(revocation_state=RevocationState.REVOKED)
    prohibited = authorization(prohibited_conditions=("driving",))
    result = decide(
        action(),
        context(satisfied_conditions=frozenset({"driving"})),
        expired,
        revoked,
        prohibited,
    )

    assert result.decision is PolicyOutcome.REQUIRE_CONFIRMATION
    assert result.authorization_refs == ()


def test_authorization_limit_must_be_explicitly_assessed() -> None:
    grant = authorization(max_frequency_or_amount="90 minutes per day")

    unknown = decide(action(), context(), grant)
    exceeded = decide(
        action(),
        context(),
        grant,
        limit_assessments=(
            AuthorizationLimitAssessment(
                authorization_id=grant.metadata.id,
                within_limit=False,
            ),
        ),
    )
    allowed = decide(
        action(),
        context(),
        grant,
        limit_assessments=(
            AuthorizationLimitAssessment(
                authorization_id=grant.metadata.id,
                within_limit=True,
            ),
        ),
    )

    assert AuthorityRisk.AUTHORIZATION_LIMIT_NOT_EVALUATED in unknown.risk_factors
    assert AuthorityRisk.AUTHORIZATION_LIMIT_EXCEEDED in exceeded.risk_factors
    assert allowed.decision is PolicyOutcome.ALLOW


def test_high_risk_dimensions_raise_execution_to_external_commit() -> None:
    required, risks = required_authority(
        action(
            reversibility=Reversibility.IRREVERSIBLE,
            sensitivity=DataClass.HIGHLY_SENSITIVE,
            financial_or_contractual_cost=1,
            recommendation_confidence=ConfidenceBand.LOW,
            cost_of_error=CostOfError.SEVERE,
        )
    )

    assert required is AuthorityLevel.COMMIT_EXTERNAL
    assert set(risks) >= {
        AuthorityRisk.COSTLY_OR_IRREVERSIBLE,
        AuthorityRisk.MATERIAL_COST,
        AuthorityRisk.HIGH_SENSITIVITY,
        AuthorityRisk.LOW_RECOMMENDATION_CONFIDENCE,
        AuthorityRisk.HIGH_COST_OF_ERROR,
    }
