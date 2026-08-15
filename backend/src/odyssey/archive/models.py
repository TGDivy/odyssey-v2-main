"""Source-linked episode and chapter contracts."""

from enum import StrEnum

from pydantic import AwareDatetime

from odyssey.domain.common import UUID7, EntityMetadata, StrictModel, TemporalInterval


class EpisodeStatus(StrEnum):
    CANDIDATE = "candidate"
    ACCEPTED = "accepted"
    EDITED = "edited"
    REJECTED = "rejected"


class Episode(StrictModel):
    metadata: EntityMetadata
    title_candidate: str
    temporal_interval: TemporalInterval
    place_ids: tuple[UUID7, ...] = ()
    person_ids: tuple[UUID7, ...] = ()
    member_event_ids: tuple[UUID7, ...]
    media_refs: tuple[str, ...] = ()
    source_linked_summary: str | None = None
    significance_assertions: tuple[UUID7, ...] = ()
    status: EpisodeStatus


class SourceAnnotation(StrictModel):
    sentence_index: int
    source_record_ids: tuple[UUID7, ...]


class ChapterVersion(StrictModel):
    metadata: EntityMetadata
    chapter_id: UUID7
    title: str
    temporal_interval: TemporalInterval
    episode_ids: tuple[UUID7, ...]
    themes: tuple[str, ...] = ()
    narrative: str
    source_annotations: tuple[SourceAnnotation, ...]
    alternative_interpretations: tuple[str, ...] = ()
    accepted_at: AwareDatetime | None = None
