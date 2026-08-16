"""Immutable domain-event envelope and initial event registry."""

from dataclasses import dataclass
from typing import Any
from uuid import UUID

from pydantic import AwareDatetime, Field

from odyssey.domain.common import UUID7, ActorRef, Provenance, StrictModel


class DomainEvent(StrictModel):
    event_id: UUID7
    event_type: str = Field(min_length=1, max_length=200)
    event_schema_version: int = Field(ge=1)
    aggregate_type: str = Field(min_length=1, max_length=100)
    aggregate_id: UUID7
    occurred_at: AwareDatetime
    recorded_at: AwareDatetime
    actor: ActorRef
    correlation_id: UUID
    causation_id: UUID7 | None = None
    payload: dict[str, Any]
    provenance: Provenance


@dataclass(frozen=True, slots=True)
class EventDefinition:
    event_type: str
    aggregate_type: str
    required_payload_fields: tuple[str, ...]
    optional_payload_fields: tuple[str, ...] = ()
    purpose: str = ""


EVENT_DEFINITIONS: tuple[EventDefinition, ...] = (
    EventDefinition(
        "capture.recorded.v1", "capture", ("capture_id",), purpose="Durable raw capture"
    ),
    EventDefinition(
        "capture.interpreted.v1",
        "capture",
        (
            "capture_id",
            "interpretation_version_id",
            "interpreter",
            "interpreter_version",
            "status",
        ),
        purpose="Versioned source-linked capture interpretation",
    ),
    EventDefinition(
        "capture.interpretation_reviewed.v1",
        "capture",
        (
            "capture_id",
            "interpretation_version_id",
            "reviewed_interpretation_version_id",
            "disposition",
        ),
        purpose="Append-only owner review or correction of an interpretation",
    ),
    EventDefinition(
        "food_preset.created.v1",
        "food_preset",
        ("food_preset_id",),
        purpose="Owner-created reusable food or drink preset",
    ),
    EventDefinition(
        "food_preset.revised.v1",
        "food_preset",
        ("food_preset_id", "change"),
        purpose="Optimistic food preset revision or archive",
    ),
    EventDefinition(
        "food.consumed.v1",
        "food_occurrence",
        ("food_occurrence_id", "food_preset_id"),
        purpose="Durable food or drink occurrence snapshot",
    ),
    EventDefinition(
        "food.consumption_corrected.v1",
        "food_occurrence",
        ("food_occurrence_id", "food_preset_id", "change"),
        purpose="Optimistic food occurrence correction or void",
    ),
    EventDefinition(
        "observation.normalized.v1",
        "observation",
        ("observation_id", "source_record_id"),
        purpose="Normalized source-linked observation",
    ),
    EventDefinition(
        "assertion.created.v1",
        "assertion",
        ("assertion_id", "subject_id", "assertion_type"),
        purpose="Typed temporal assertion",
    ),
    EventDefinition(
        "assertion.superseded.v1",
        "assertion",
        ("assertion_id", "superseded_by_assertion_id"),
        purpose="Non-destructive assertion correction",
    ),
    EventDefinition(
        "charter.revised.v1",
        "charter",
        ("charter_version_id",),
        ("supersedes_version_id",),
        "Accepted Charter revision",
    ),
    EventDefinition(
        "life_stage.revised.v1",
        "life_stage",
        ("life_stage_version_id",),
        ("supersedes_version_id",),
        "Accepted descriptive life-stage revision",
    ),
    EventDefinition(
        "season.revised.v1",
        "season",
        ("season_version_id", "season_id", "new_status"),
        ("supersedes_version_id", "previous_status"),
        "Immutable season version or state revision",
    ),
    EventDefinition("season.activated.v1", "season", ("season_id",), purpose="Season activation"),
    EventDefinition(
        "season.transitioned.v1",
        "season",
        ("from_season_id", "to_season_id"),
        purpose="Explicit season transition",
    ),
    EventDefinition(
        "decision.detected.v1", "decision", ("decision_id",), purpose="Decision candidate creation"
    ),
    EventDefinition(
        "decision.recommendation_prepared.v1",
        "decision",
        ("decision_id", "recommendation_id"),
        purpose="Structured recommendation preparation",
    ),
    EventDefinition(
        "decision.choice_recorded.v1",
        "decision",
        ("decision_id", "choice_id"),
        purpose="Explicit or authorized choice",
    ),
    EventDefinition(
        "action.status_changed.v1",
        "action",
        ("action_id", "previous_status", "new_status"),
        purpose="Action lifecycle transition",
    ),
    EventDefinition(
        "outcome.observed.v1",
        "outcome",
        ("outcome_id",),
        ("action_id", "decision_id"),
        "Source-linked outcome observation",
    ),
    EventDefinition(
        "intent.opportunity_detected.v1",
        "intent",
        ("intent_id", "opportunity_id", "context_snapshot_id"),
        purpose="Bounded intervention opportunity",
    ),
    EventDefinition(
        "intervention.suppressed.v1",
        "intervention",
        ("opportunity_id", "reason_code"),
        purpose="Auditable silence decision",
    ),
    EventDefinition(
        "intervention.delivered.v1",
        "intervention",
        ("intervention_id", "opportunity_id", "surface"),
        purpose="Intervention delivery receipt",
    ),
    EventDefinition(
        "intervention.responded.v1",
        "intervention",
        ("intervention_id", "response"),
        purpose="User response or correction",
    ),
    EventDefinition(
        "evidence.claim_appraised.v1",
        "evidence_claim",
        ("claim_id", "appraisal_id"),
        purpose="Evidence quality appraisal",
    ),
    EventDefinition(
        "hypothesis.proposed.v1",
        "hypothesis",
        ("hypothesis_id",),
        purpose="Exploratory personal hypothesis",
    ),
    EventDefinition(
        "experiment.assignment_created.v1",
        "experiment",
        ("experiment_id", "assignment_id", "condition"),
        purpose="Preregistered N-of-1 assignment",
    ),
    EventDefinition(
        "learning.accepted.v1",
        "learning",
        ("learning_id", "source_hypothesis_id"),
        purpose="Owner-accepted personal learning",
    ),
    EventDefinition(
        "episode.proposed.v1", "episode", ("episode_id",), purpose="Source-linked archive proposal"
    ),
    EventDefinition(
        "chapter.accepted.v1",
        "chapter",
        ("chapter_version_id",),
        purpose="Owner-accepted archive chapter",
    ),
    EventDefinition(
        "permission.revoked.v1",
        "standing_authorization",
        ("authorization_id", "reason_code"),
        purpose="Immediate authority revocation",
    ),
    EventDefinition(
        "product_change.proposed.v1",
        "product_change",
        ("proposal_id",),
        purpose="Governed product adaptation proposal",
    ),
)


def payload_property_schema(field_name: str) -> dict[str, str]:
    if field_name.endswith("_id"):
        return {"type": "string", "format": "uuid"}
    return {"type": "string"}


def event_json_schema(definition: EventDefinition) -> dict[str, Any]:
    schema = DomainEvent.model_json_schema(mode="validation")
    schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    schema["$id"] = f"https://schemas.odyssey.local/events/v1/{definition.event_type}.schema.json"
    schema["title"] = definition.event_type
    properties = schema["properties"]
    properties["event_type"] = {"const": definition.event_type}
    properties["event_schema_version"] = {"const": 1}
    properties["aggregate_type"] = {"const": definition.aggregate_type}
    payload_fields = definition.required_payload_fields + definition.optional_payload_fields
    properties["payload"] = {
        "type": "object",
        "properties": {name: payload_property_schema(name) for name in payload_fields},
        "required": list(definition.required_payload_fields),
        "additionalProperties": False,
    }
    return schema
