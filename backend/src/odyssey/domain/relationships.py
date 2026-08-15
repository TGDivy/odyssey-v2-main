"""Conservative person and relationship-memory contracts."""

from pydantic import Field

from odyssey.domain.common import (
    UUID7,
    EntityMetadata,
    EpistemicState,
    ExternalRef,
    StrictModel,
    TemporalInterval,
)


class Person(StrictModel):
    metadata: EntityMetadata
    display_name: str = Field(min_length=1, max_length=500)
    contact_external_refs: tuple[ExternalRef, ...] = ()
    user_authored_notes: str | None = None
    privacy_scope: str


class RelationshipAssertion(StrictModel):
    metadata: EntityMetadata
    person_id: UUID7
    relationship_kind: str
    significance_band: str | None = None
    context_label: str | None = None
    valid_interval: TemporalInterval
    user_authored: bool
    epistemic_state: EpistemicState
    boundaries: tuple[str, ...] = ()
    do_not_infer_fields: tuple[str, ...] = ()


class MeaningfulContact(StrictModel):
    metadata: EntityMetadata
    person_ids: tuple[UUID7, ...]
    occurred_interval: TemporalInterval
    medium: str | None = None
    meaningfulness: str
    shared_experience_id: UUID7 | None = None
    notes: str | None = None
