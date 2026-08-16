"""Governed product telemetry contract tests."""

from datetime import UTC, datetime
from uuid import UUID

import pytest
from pydantic import ValidationError

from odyssey.telemetry.models import ProductEvent, ProductEventName
from odyssey.telemetry.registry import PRODUCT_TELEMETRY_REGISTRY


def uuid7(value: str) -> UUID:
    return UUID(value)


def valid_event(**overrides: object) -> dict[str, object]:
    values: dict[str, object] = {
        "event_id": uuid7("018f22d2-8a80-7000-8000-000000000001"),
        "occurred_at": datetime(2026, 8, 16, 12, tzinfo=UTC),
        "received_at": datetime(2026, 8, 16, 12, tzinfo=UTC),
        "device_id": uuid7("018f22d2-8a80-7000-8000-000000000002"),
        "app_build": "1.0.0+1",
        "surface": "iphone_now",
        "event_name": ProductEventName.TOMORROW_MAP_AVAILABILITY_EVALUATED,
        "context_version": "native-now-context-1",
        "properties_typed": {
            "calendar_state": "fresh",
            "intentionally_absent": False,
            "transition_count": 2,
            "pressure_present": True,
            "protected_open_present": False,
        },
    }
    values.update(overrides)
    return values


def test_registry_has_unique_question_owned_events() -> None:
    assert len(PRODUCT_TELEMETRY_REGISTRY.questions) == 2
    assert len(PRODUCT_TELEMETRY_REGISTRY.events) == len(ProductEventName)
    assert all(event.local_only_by_default for event in PRODUCT_TELEMETRY_REGISTRY.events)
    assert all(event.retention_days == 30 for event in PRODUCT_TELEMETRY_REGISTRY.events)


def test_product_event_accepts_only_registered_typed_properties() -> None:
    event = ProductEvent.model_validate(valid_event())

    assert event.local_only_flag is True
    assert event.properties_typed["transition_count"] == 2

    with pytest.raises(ValidationError, match="unknown telemetry properties"):
        ProductEvent.model_validate(
            valid_event(
                properties_typed={
                    **valid_event()["properties_typed"],  # type: ignore[dict-item]
                    "calendar_title": "private",
                }
            )
        )

    with pytest.raises(ValidationError, match="transition_count must be an integer"):
        ProductEvent.model_validate(
            valid_event(
                properties_typed={
                    **valid_event()["properties_typed"],  # type: ignore[dict-item]
                    "transition_count": True,
                }
            )
        )


def test_product_event_rejects_clock_and_unbounded_dimensions() -> None:
    with pytest.raises(ValidationError, match="received_at cannot precede"):
        ProductEvent.model_validate(
            valid_event(received_at=datetime(2026, 8, 16, 11, 59, tzinfo=UTC))
        )

    with pytest.raises(ValidationError, match="bounded tokens"):
        ProductEvent.model_validate(valid_event(feature_flag_assignments={"flag": "private value"}))
