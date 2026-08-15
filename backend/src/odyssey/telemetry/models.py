"""Governed product telemetry and product-change contracts."""

from enum import StrEnum
from typing import Any

from pydantic import AwareDatetime

from odyssey.domain.common import UUID7, EntityMetadata, StrictModel


class ProductEvent(StrictModel):
    event_id: UUID7
    occurred_at: AwareDatetime
    received_at: AwareDatetime
    session_id: UUID7 | None = None
    device_id: UUID7
    app_build: str
    surface: str
    event_name: str
    object_type: str | None = None
    object_id_pseudonymous: str | None = None
    context_version: str
    feature_flag_assignments: dict[str, str]
    properties_typed: dict[str, Any]
    causal_parent_event_id: UUID7 | None = None
    local_only_flag: bool = False


class ProductChangeStatus(StrEnum):
    PROPOSED = "proposed"
    APPROVED = "approved"
    RUNNING = "running"
    REJECTED = "rejected"
    ADOPTED = "adopted"
    REVERTED = "reverted"


class ProductChangeProposal(StrictModel):
    metadata: EntityMetadata
    observed_pattern: str
    supporting_product_event_query: str
    sample_summary: str
    counterexamples: tuple[str, ...] = ()
    alternative_explanations: tuple[str, ...]
    proposed_change: str
    affected_invariants: tuple[str, ...] = ()
    expected_benefit: str
    possible_harms: tuple[str, ...]
    experiment_plan: str
    rollback: str
    status: ProductChangeStatus
