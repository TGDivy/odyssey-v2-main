"""Immutable and reproducible situation context snapshots."""

from typing import Any

from pydantic import AwareDatetime

from odyssey.domain.common import UUID7, StrictModel


class HealthContext(StrictModel):
    sleep_summary: dict[str, Any] | None = None
    readiness_features: dict[str, Any] | None = None
    symptoms_or_constraints: tuple[str, ...] = ()
    freshness: str


class DataQualityIndicator(StrictModel):
    domain: str
    status: str
    reason_codes: tuple[str, ...] = ()
    latest_source_at: AwareDatetime | None = None


class ContextSnapshot(StrictModel):
    id: UUID7
    as_of: AwareDatetime
    built_at: AwareDatetime
    location_context: dict[str, Any] | None = None
    calendar_window: tuple[dict[str, Any], ...] = ()
    health_state: HealthContext
    active_season_version_id: UUID7
    active_commitments: tuple[UUID7, ...] = ()
    current_intents: tuple[UUID7, ...] = ()
    unresolved_decisions: tuple[UUID7, ...] = ()
    planned_training: dict[str, Any] | None = None
    social_or_relationship_commitments: tuple[UUID7, ...] = ()
    travel_state: dict[str, Any] | None = None
    weather_context: dict[str, Any] | None = None
    recent_intervention_burden: dict[str, Any]
    data_quality: tuple[DataQualityIndicator, ...] = ()
    missing_material_context: tuple[str, ...] = ()
    source_fact_ids: tuple[UUID7, ...]
    builder_version: str
