"""Owner export API contracts."""

from enum import StrEnum

from pydantic import AwareDatetime, Field, model_validator

from odyssey.domain.common import UUID7, StrictModel


class ExportScope(StrEnum):
    ALL_ODYSSEY_OWNED_DATA = "all_odyssey_owned_data"


class ExportFormat(StrEnum):
    JSONL = "jsonl"
    CSV = "csv"
    MARKDOWN = "markdown"


class ExportEncryptionMode(StrEnum):
    OWNER_CONTROLLED = "owner_passphrase"


class ExportEncryptionRequest(StrictModel):
    mode: ExportEncryptionMode


class ExportCreateRequest(StrictModel):
    scope: ExportScope
    formats: tuple[ExportFormat, ...] = Field(min_length=1, max_length=3)
    include_raw_sources: bool
    include_model_traces: bool
    encryption: ExportEncryptionRequest

    @model_validator(mode="after")
    def validate_formats(self) -> "ExportCreateRequest":
        if len(set(self.formats)) != len(self.formats):
            raise ValueError("export formats must be unique")
        return self


class ExportJobStatus(StrEnum):
    QUEUED = "queued"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"


class ExportJobResponse(StrictModel):
    job_id: UUID7
    status: ExportJobStatus
    phase: str
    status_url: str
    download_url: str | None = None
    created_at: AwareDatetime
    updated_at: AwareDatetime
    completed_at: AwareDatetime | None = None
    attempts: int = Field(ge=0)
    artifact_sha256: str | None = Field(default=None, min_length=64, max_length=64)
    artifact_bytes: int | None = Field(default=None, ge=0)
    manifest_sha256: str | None = Field(default=None, min_length=64, max_length=64)
    signing_public_key: str | None = None
    last_error_code: str | None = None
    export_format_version: str = "odyssey-owner-export-v1"
