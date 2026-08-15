import json
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from pydantic import ValidationError

from odyssey.decision.models import Choice, ChoiceSource, GenerationMethod, Recommendation
from odyssey.domain.common import (
    ActorRef,
    ActorType,
    ConfidenceBand,
    DataClass,
    EntityMetadata,
    new_uuid7,
)
from odyssey.domain.relationships import Person, RelationshipAssertion
from odyssey.intent.models import Intervention, InterventionKind


def metadata() -> EntityMetadata:
    now = datetime.now(UTC)
    return EntityMetadata(
        id=new_uuid7(),
        schema_version=1,
        created_at=now,
        created_by=ActorRef(actor_type=ActorType.USER, actor_id="owner"),
        last_revised_at=now,
        revision=1,
        sensitivity=DataClass.PRIVATE,
        provenance_id=uuid4(),
    )


def test_recommendation_requires_a_subject() -> None:
    with pytest.raises(ValidationError, match="decision or intervention"):
        Recommendation(
            metadata=metadata(),
            recommended_option_or_action="Wait for better context.",
            rationale_short="Material information is missing.",
            rationale_structured=(),
            evidence_pack_id=new_uuid7(),
            confidence_band=ConfidenceBand.LOW,
            generation_method=GenerationMethod.DETERMINISTIC,
            policy_result_id=new_uuid7(),
        )


def test_choice_requires_option_or_adaptation() -> None:
    with pytest.raises(ValidationError, match="selected option or adapted action"):
        Choice(
            metadata=metadata(),
            decision_id=new_uuid7(),
            chosen_at=datetime.now(UTC),
            source=ChoiceSource.EXPLICIT_USER,
        )


def test_intervention_cannot_be_delivered_after_expiry() -> None:
    now = datetime.now(UTC)
    with pytest.raises(ValidationError, match="expired intervention"):
        Intervention(
            metadata=metadata(),
            opportunity_id=new_uuid7(),
            kind=InterventionKind.IN_APP,
            content_template_version="test-v1",
            rendered_content="Synthetic stakes.\nTake one reversible action.",
            delivered_at=now + timedelta(minutes=2),
            expiry=now,
            redaction_level="private",
        )


def test_relationship_contracts_have_no_ranking_fields() -> None:
    contract_text = json.dumps(
        {
            "person": Person.model_json_schema(),
            "relationship": RelationshipAssertion.model_json_schema(),
        }
    ).lower()

    for prohibited in ("relationship_score", '"rank"', '"roi"'):
        assert prohibited not in contract_text
