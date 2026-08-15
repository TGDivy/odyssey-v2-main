"""Offline-first capture and normalized observation contracts."""

from enum import StrEnum
from typing import Any

from pydantic import AwareDatetime, Field

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
