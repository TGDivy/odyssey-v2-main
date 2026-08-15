from datetime import UTC, date, datetime, timedelta
from uuid import uuid4

import pytest
from pydantic import ValidationError

from odyssey.domain.common import (
    ActorRef,
    ActorType,
    DataClass,
    EntityMetadata,
    TemporalInterval,
    TemporalPrecision,
    new_uuid7,
)
from odyssey.domain.life import (
    AllocationBand,
    DirectionRole,
    Season,
    SeasonCreationSource,
    SeasonPortfolioItem,
    SeasonStatus,
)
from odyssey.domain.schema_registry import SCHEMA_MODELS


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


def portfolio_item(role: DirectionRole) -> SeasonPortfolioItem:
    return SeasonPortfolioItem(
        direction_id=new_uuid7(),
        role=role,
        allocation_band=AllocationBand.MODERATE,
    )


def test_new_uuid_has_version_seven_and_rfc_variant() -> None:
    identifier = new_uuid7()

    assert identifier.version == 7
    assert identifier.variant == "specified in RFC 4122"


def test_entity_identifier_rejects_non_uuid7() -> None:
    with pytest.raises(ValidationError, match="UUIDv7"):
        EntityMetadata(
            id=uuid4(),
            schema_version=1,
            created_at=datetime.now(UTC),
            created_by=ActorRef(actor_type=ActorType.USER, actor_id="owner"),
            last_revised_at=datetime.now(UTC),
            revision=1,
            sensitivity=DataClass.PRIVATE,
            provenance_id=uuid4(),
        )


def test_temporal_interval_rejects_reverse_and_mixed_boundaries() -> None:
    with pytest.raises(ValidationError, match="cannot precede"):
        TemporalInterval(
            start=date(2026, 8, 16),
            end=date(2026, 8, 15),
            all_day_semantics=True,
            start_precision=TemporalPrecision.DAY,
            end_precision=TemporalPrecision.DAY,
        )

    with pytest.raises(ValidationError, match="same temporal type"):
        TemporalInterval(start=date(2026, 8, 15), end=datetime.now(UTC))


def test_temporal_interval_validates_iana_timezone() -> None:
    interval = TemporalInterval(
        start=date(2026, 8, 15),
        end=date(2026, 8, 16),
        timezone_id="Europe/London",
        all_day_semantics=True,
    )

    assert interval.timezone_id == "Europe/London"
    with pytest.raises(ValidationError, match="IANA"):
        TemporalInterval(timezone_id="Not/A_Real_Zone")


def test_season_requires_explanation_for_more_than_two_primaries() -> None:
    now = datetime.now(UTC)
    common = {
        "metadata": metadata(),
        "charter_revision_id": new_uuid7(),
        "title": "Synthetic season",
        "effective_interval": TemporalInterval(start=now, end=now + timedelta(days=90)),
        "status": SeasonStatus.DRAFT,
        "created_from": SeasonCreationSource.USER,
        "rationale": "Test the portfolio invariant.",
        "portfolio_items": tuple(portfolio_item(DirectionRole.PRIMARY) for _ in range(3)),
        "explicit_non_goals": ("Do not optimize every hour.",),
        "good_week_description": "Important work and relationships both receive attention.",
        "transition_triggers": ("Review when the launch ends.",),
        "review_cadence": "P2W",
    }

    with pytest.raises(ValidationError, match="requires an explanation"):
        Season(**common)

    season = Season(**common, primary_override_explanation="Temporary launch concentration.")
    assert len(season.portfolio_items) == 3


def test_registered_contracts_emit_json_schema() -> None:
    for name, model in SCHEMA_MODELS.items():
        schema = model.model_json_schema()
        assert schema["title"]
        assert name
