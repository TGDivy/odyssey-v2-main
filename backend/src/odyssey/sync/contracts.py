"""Closed HTTP contracts for resumable, idempotent owner-device sync."""

import json
import re
from enum import StrEnum
from typing import Any

from pydantic import AwareDatetime, Field, JsonValue, model_validator

from odyssey.domain.common import UUID7, DataClass, StrictModel

CURSOR_PATTERN = re.compile(r"^c_(0|[1-9][0-9]*)$")
MAX_OPERATION_PAYLOAD_BYTES = 256 * 1024


class SyncMutationType(StrEnum):
    CREATE = "create"
    UPDATE = "update"
    DELETE = "delete"


class SyncOperationInput(StrictModel):
    operation_id: UUID7
    device_sequence: int = Field(ge=1)
    entity_type: str = Field(min_length=1, max_length=100)
    entity_id: UUID7
    mutation_type: SyncMutationType
    base_revision: int | None = Field(default=None, ge=1)
    payload: dict[str, JsonValue] = Field(default_factory=dict)
    created_at: AwareDatetime
    idempotency_key: str | None = Field(default=None, min_length=1, max_length=500)
    sensitivity_class: DataClass = DataClass.PRIVATE

    @model_validator(mode="after")
    def validate_operation(self) -> "SyncOperationInput":
        payload_size = len(json.dumps(self.payload, separators=(",", ":"), sort_keys=True).encode())
        if payload_size > MAX_OPERATION_PAYLOAD_BYTES:
            raise ValueError("operation payload exceeds the 256 KiB limit")
        if self.mutation_type is SyncMutationType.CREATE and self.base_revision is not None:
            raise ValueError("create operations cannot declare a base revision")
        if self.mutation_type is SyncMutationType.DELETE and self.payload:
            raise ValueError("delete operations must use an empty payload")
        return self


class SyncPushRequest(StrictModel):
    device_id: UUID7
    client_schema_version: int = Field(ge=1)
    base_cursor: str
    operations: tuple[SyncOperationInput, ...] = Field(min_length=1, max_length=500)

    @model_validator(mode="after")
    def validate_batch(self) -> "SyncPushRequest":
        parse_cursor(self.base_cursor)
        sequences = [operation.device_sequence for operation in self.operations]
        if sequences != sorted(sequences) or len(sequences) != len(set(sequences)):
            raise ValueError("operations must have unique ascending device sequences")
        return self


class AcceptedOperation(StrictModel):
    operation_id: UUID7
    canonical_revision: int = Field(ge=1)
    server_change_id: int = Field(ge=1)
    merge_result: str


class RejectedOperation(StrictModel):
    operation_id: UUID7
    code: str
    message: str
    retryable: bool


class SyncConflictSummary(StrictModel):
    conflict_id: UUID7
    operation_id: UUID7
    entity_type: str
    entity_id: UUID7
    code: str
    current_revision: int | None
    conflicting_fields: tuple[str, ...] = ()


class SyncPushResponse(StrictModel):
    accepted: tuple[AcceptedOperation, ...] = ()
    rejected: tuple[RejectedOperation, ...] = ()
    conflicts: tuple[SyncConflictSummary, ...] = ()
    next_cursor: str
    server_time: AwareDatetime
    server_schema_version: int = Field(ge=1)
    minimum_client_schema_version: int = Field(ge=1)


class SyncChange(StrictModel):
    change_id: int = Field(ge=1)
    canonical_revision: int = Field(ge=1)
    entity_type: str
    entity_id: UUID7
    mutation_type: SyncMutationType
    payload: dict[str, JsonValue]
    tombstone: bool
    deletion_epoch: int | None = Field(default=None, ge=1)
    merge_result: str
    origin_device_id: UUID7
    origin_operation_id: UUID7
    server_received_at: AwareDatetime


class SyncPullResponse(StrictModel):
    changes: tuple[SyncChange, ...]
    next_cursor: str
    has_more: bool
    server_time: AwareDatetime
    server_schema_version: int = Field(ge=1)
    minimum_client_schema_version: int = Field(ge=1)


def parse_cursor(value: str) -> int:
    if not CURSOR_PATTERN.fullmatch(value):
        raise ValueError("cursor must use c_<nonnegative integer>")
    return int(value[2:])


def format_cursor(value: int) -> str:
    if value < 0:
        raise ValueError("cursor cannot be negative")
    return f"c_{value}"


def canonical_operation_document(operation: SyncOperationInput) -> dict[str, Any]:
    return operation.model_dump(mode="json")
