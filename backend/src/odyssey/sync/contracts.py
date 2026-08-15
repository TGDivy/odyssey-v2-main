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


class SchemaCompatibility(StrEnum):
    COMPATIBLE = "compatible"
    CLIENT_UPGRADE_REQUIRED = "client_upgrade_required"
    SERVER_UPGRADE_REQUIRED = "server_upgrade_required"


class SyncDeviceDiagnosticsInput(StrictModel):
    client_schema_version: int = Field(ge=1)
    device_cursor: str
    operations_queued: int = Field(ge=0)
    oldest_unsynced_operation_at: AwareDatetime | None = None
    attachment_backlog: int = Field(ge=0)

    @model_validator(mode="after")
    def validate_diagnostics(self) -> "SyncDeviceDiagnosticsInput":
        parse_cursor(self.device_cursor)
        if self.operations_queued == 0 and self.oldest_unsynced_operation_at is not None:
            raise ValueError("an empty queue cannot have an oldest unsynced operation")
        if self.operations_queued > 0 and self.oldest_unsynced_operation_at is None:
            raise ValueError("a nonempty queue must report its oldest unsynced operation")
        return self


class SyncDeviceDiagnostics(StrictModel):
    device_id: UUID7
    client_schema_version: int = Field(ge=1)
    schema_compatibility: SchemaCompatibility
    last_successful_push_at: AwareDatetime | None
    last_successful_pull_at: AwareDatetime | None
    operations_queued: int = Field(ge=0)
    oldest_unsynced_operation_at: AwareDatetime | None
    attachment_backlog: int = Field(ge=0)
    last_device_sequence: int = Field(ge=0)
    device_cursor: str
    server_cursor: str
    clock_skew_seconds: int | None
    diagnostics_reported_at: AwareDatetime | None
    diagnostics_stale: bool


class SyncRepairOptions(StrictModel):
    projection_rebuild_available: bool
    projection_rebuild_command: str
    integrity_check_command: str


class SyncDiagnosticsResponse(StrictModel):
    server_time: AwareDatetime
    server_cursor: str
    server_schema_version: int = Field(ge=1)
    minimum_client_schema_version: int = Field(ge=1)
    pending_conflicts: int = Field(ge=0)
    pending_attachment_uploads: int = Field(ge=0)
    pending_outbox_jobs: int = Field(ge=0)
    sync_push_enabled: bool
    sync_pull_enabled: bool
    devices: tuple[SyncDeviceDiagnostics, ...]
    repair: SyncRepairOptions


class ConflictResolutionStrategy(StrEnum):
    KEEP_CURRENT = "keep_current"
    ACCEPT_INCOMING = "accept_incoming"
    MERGE = "merge"


class SyncConflictStatusFilter(StrEnum):
    PENDING = "pending"
    RESOLVED = "resolved"
    ALL = "all"


class SyncConflictDetail(StrictModel):
    conflict_id: UUID7
    operation_id: UUID7
    originating_device_id: UUID7
    entity_type: str
    entity_id: UUID7
    code: str
    base_revision: int | None
    current_revision: int | None
    current_document: dict[str, JsonValue]
    incoming_document: dict[str, JsonValue]
    conflicting_fields: tuple[str, ...]
    status: str
    created_at: AwareDatetime
    resolved_at: AwareDatetime | None
    explanation: str
    allowed_strategies: tuple[ConflictResolutionStrategy, ...]


class SyncConflictListResponse(StrictModel):
    conflicts: tuple[SyncConflictDetail, ...]
    pending_count: int = Field(ge=0)
    server_time: AwareDatetime


class SyncConflictResolutionRequest(StrictModel):
    operation_id: UUID7
    device_id: UUID7
    device_sequence: int = Field(ge=1)
    client_schema_version: int = Field(ge=1)
    expected_current_revision: int = Field(ge=1)
    strategy: ConflictResolutionStrategy
    merged_document: dict[str, JsonValue] | None = None
    created_at: AwareDatetime
    idempotency_key: str | None = Field(default=None, min_length=1, max_length=500)
    sensitivity_class: DataClass = DataClass.PRIVATE

    @model_validator(mode="after")
    def validate_resolution(self) -> "SyncConflictResolutionRequest":
        if self.strategy is ConflictResolutionStrategy.MERGE and self.merged_document is None:
            raise ValueError("merge conflict resolution requires a merged document")
        if (
            self.strategy is not ConflictResolutionStrategy.MERGE
            and self.merged_document is not None
        ):
            raise ValueError("only merge conflict resolution accepts a merged document")
        return self


class SyncConflictResolutionResponse(StrictModel):
    resolution_id: UUID7
    conflict_id: UUID7
    status: str
    strategy: ConflictResolutionStrategy
    accepted_operation: AcceptedOperation
    next_cursor: str
    server_time: AwareDatetime
    server_schema_version: int = Field(ge=1)


def parse_cursor(value: str) -> int:
    if not CURSOR_PATTERN.fullmatch(value):
        raise ValueError("cursor must use c_<nonnegative integer>")
    return int(value[2:])


def format_cursor(value: int) -> str:
    if value < 0:
        raise ValueError("cursor cannot be negative")
    return f"c_{value}"


def canonical_operation_document(operation: SyncOperationInput) -> dict[str, Any]:
    document = operation.model_dump(mode="json")
    document["idempotency_key"] = operation.idempotency_key or str(operation.operation_id)
    return document
