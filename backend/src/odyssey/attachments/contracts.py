"""Strict attachment upload and object-manifest contracts."""

import re
from enum import StrEnum

from pydantic import AwareDatetime, Field, JsonValue, model_validator

from odyssey.domain.common import UUID7, DataClass, StrictModel

SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class AttachmentEncryptionMode(StrEnum):
    NONE = "none"
    CLIENT_SIDE = "client_side"


class AttachmentStatus(StrEnum):
    PENDING_UPLOAD = "pending_upload"
    AVAILABLE = "available"
    DELETED = "deleted"


class AttachmentUploadStatus(StrEnum):
    UPLOADING = "uploading"
    COMPLETED = "completed"
    EXPIRED = "expired"


class AttachmentUploadRequest(StrictModel):
    attachment_id: UUID7
    content_sha256: str = Field(pattern=SHA256_PATTERN.pattern)
    byte_size: int = Field(ge=1)
    media_type: str = Field(min_length=1, max_length=200)
    sensitivity_class: DataClass = DataClass.PRIVATE
    encryption_mode: AttachmentEncryptionMode = AttachmentEncryptionMode.NONE
    encryption_metadata: dict[str, JsonValue] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_encryption_metadata(self) -> "AttachmentUploadRequest":
        if self.encryption_mode is AttachmentEncryptionMode.NONE and self.encryption_metadata:
            raise ValueError("unencrypted attachments cannot declare encryption metadata")
        if self.encryption_mode is AttachmentEncryptionMode.CLIENT_SIDE:
            algorithm = self.encryption_metadata.get("algorithm")
            if not isinstance(algorithm, str) or not algorithm:
                raise ValueError("client-side encryption must declare an algorithm")
            forbidden_fields = {"key", "plaintext_key", "secret"} & self.encryption_metadata.keys()
            if forbidden_fields:
                raise ValueError("encryption metadata cannot contain key material")
        return self


class AttachmentUploadResponse(StrictModel):
    attachment_id: UUID7
    status: AttachmentStatus
    content_sha256: str
    byte_size: int = Field(ge=1)
    upload_id: UUID7 | None = None
    chunk_size: int | None = Field(default=None, ge=1)
    expected_chunks: int | None = Field(default=None, ge=1)
    signed_chunk_url_template: str | None = None
    upload_expires_at: AwareDatetime | None = None
    deduplicated: bool = False


class AttachmentChunkResponse(StrictModel):
    upload_id: UUID7
    chunk_index: int = Field(ge=0)
    byte_size: int = Field(ge=1)
    chunk_sha256: str
    created: bool


class AttachmentCompleteResponse(StrictModel):
    attachment_id: UUID7
    status: AttachmentStatus
    content_sha256: str
    byte_size: int = Field(ge=1)
    object_ref: str
    committed_at: AwareDatetime


class AttachmentStatusResponse(StrictModel):
    attachment_id: UUID7
    status: AttachmentStatus
    content_sha256: str
    byte_size: int = Field(ge=1)
    media_type: str
    sensitivity_class: DataClass
    encryption_mode: AttachmentEncryptionMode
    encryption_metadata: dict[str, JsonValue]
    object_ref: str | None
    created_at: AwareDatetime
    committed_at: AwareDatetime | None
