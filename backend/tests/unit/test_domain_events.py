from datetime import UTC, datetime, timedelta
from uuid import uuid4

from odyssey.domain.common import ActorRef, ActorType, Provenance, new_uuid7
from odyssey.domain.events import EVENT_DEFINITIONS, DomainEvent, event_json_schema


def provenance(now: datetime) -> Provenance:
    return Provenance(
        id=new_uuid7(),
        source_kind="synthetic_fixture",
        source_id="event-test",
        captured_at=now,
        actor=ActorRef(actor_type=ActorType.SYSTEM, actor_id="tests"),
    )


def test_initial_event_registry_is_unique_and_versioned() -> None:
    event_types = [definition.event_type for definition in EVENT_DEFINITIONS]

    assert len(event_types) == 26
    assert len(set(event_types)) == len(event_types)
    assert all(event_type.endswith(".v1") for event_type in event_types)


def test_event_schema_closes_payload_and_pins_type() -> None:
    definition = EVENT_DEFINITIONS[0]
    schema = event_json_schema(definition)

    assert schema["properties"]["event_type"] == {"const": "capture.recorded.v1"}
    assert schema["properties"]["payload"]["additionalProperties"] is False
    assert schema["properties"]["payload"]["required"] == ["capture_id"]


def test_domain_event_preserves_device_clock_skew() -> None:
    now = datetime.now(UTC)
    event = DomainEvent(
        event_id=new_uuid7(),
        event_type="capture.recorded.v1",
        event_schema_version=1,
        aggregate_type="capture",
        aggregate_id=new_uuid7(),
        occurred_at=now,
        recorded_at=now - timedelta(seconds=1),
        actor=ActorRef(actor_type=ActorType.USER, actor_id="owner"),
        correlation_id=uuid4(),
        payload={"capture_id": str(new_uuid7())},
        provenance=provenance(now),
    )

    assert event.recorded_at < event.occurred_at
