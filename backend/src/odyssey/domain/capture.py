"""Offline-first capture and normalized observation contracts."""

from enum import StrEnum
from typing import Any, Self

from pydantic import AwareDatetime, Field, model_validator

from odyssey.domain.common import (
    UUID7,
    EntityMetadata,
    EpistemicState,
    StrictModel,
    TemporalInterval,
)


class CapturePayloadKind(StrEnum):
    TEXT = "text"
    AUDIO = "audio"
    IMAGE_REF = "image_ref"
    FILE_REF = "file_ref"
    STRUCTURED_QUICK_ACTION = "structured_quick_action"


class InterpretationReviewDisposition(StrEnum):
    ACCEPTED = "accepted"
    CORRECTED = "corrected"
    DISMISSED = "dismissed"


class CapturePayload(StrictModel):
    kind: CapturePayloadKind
    content_or_object_ref: str = Field(min_length=1)
    content_hash: str = Field(min_length=16, max_length=128)


class CaptureContext(StrictModel):
    device_id: UUID7
    timezone: str
    broad_location: str | None = None
    invoking_surface: str


class InterpretationVersion(StrictModel):
    id: UUID7
    interpreter: str
    interpreter_version: str
    created_at: AwareDatetime
    status: str
    proposed_fields: dict[str, Any] = Field(default_factory=dict)
    source_span_refs: tuple[str, ...] = ()
    supersedes_interpretation_version_id: UUID7 | None = None
    owner_review_disposition: InterpretationReviewDisposition | None = None
    owner_review_note: str | None = Field(default=None, min_length=1, max_length=500)

    @model_validator(mode="after")
    def validate_owner_review(self) -> Self:
        disposition = self.owner_review_disposition
        if disposition is None:
            if (
                self.supersedes_interpretation_version_id is not None
                or self.owner_review_note is not None
                or self.status == "dismissed"
            ):
                raise ValueError("owner review metadata requires a disposition")
            return self
        if (
            self.supersedes_interpretation_version_id is None
            or self.supersedes_interpretation_version_id == self.id
        ):
            raise ValueError("owner review requires distinct interpretation lineage")
        if (
            self.owner_review_note is not None
            and self.owner_review_note.strip() != self.owner_review_note
        ):
            raise ValueError("owner review note must be trimmed")
        if disposition is InterpretationReviewDisposition.DISMISSED:
            if self.status != "dismissed" or self.proposed_fields:
                raise ValueError("dismissed review cannot retain proposed fields")
        elif self.status != "interpreted":
            raise ValueError("accepted or corrected review must remain interpreted")
        elif not self.proposed_fields:
            raise ValueError("accepted or corrected review requires proposed fields")
        return self


class Capture(StrictModel):
    metadata: EntityMetadata
    captured_at: AwareDatetime
    original_payload: CapturePayload
    initial_context: CaptureContext
    interpretation_status: str
    interpretation_versions: tuple[InterpretationVersion, ...] = ()


class ObservationCorrection(StrictModel):
    id: UUID7
    corrected_at: AwareDatetime
    reason: str
    replacement_observation_id: UUID7 | None = None


class Observation(StrictModel):
    metadata: EntityMetadata
    subject_id: UUID7
    observation_type: str
    value: Any
    unit: str | None = None
    occurred_interval: TemporalInterval
    observed_at: AwareDatetime
    source_record_id: UUID7
    quality: str
    epistemic_state: EpistemicState
    corrections: tuple[ObservationCorrection, ...] = ()
