"""Transactional sync engine with domain-specific merge and replay semantics."""

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from hashlib import sha256
from typing import Any, Literal
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.db.models import OutboxRecord
from odyssey.domain.common import new_uuid7
from odyssey.sync.contracts import (
    AcceptedOperation,
    RejectedOperation,
    SyncChange,
    SyncConflictSummary,
    SyncMutationType,
    SyncOperationInput,
    SyncPullResponse,
    SyncPushRequest,
    SyncPushResponse,
    canonical_operation_document,
    format_cursor,
    parse_cursor,
)
from odyssey.sync.models import (
    CanonicalEntityRecord,
    ServerChangeRecord,
    SyncBatchReceiptRecord,
    SyncConflictRecord,
    SyncDeviceRecord,
    SyncOperationRecord,
    SyncStateRecord,
)

CURRENT_SYNC_SCHEMA_VERSION = 1
SYNC_STATE_KEY = "global"

APPEND_ONLY_ENTITY_TYPES = {
    "capture",
    "external_observation",
    "health_observation",
    "observation",
    "training_action",
}
NORMATIVE_ENTITY_TYPES = {
    "charter",
    "charter_version",
    "direction",
    "life_stage",
    "season",
    "season_version",
}
EDITABLE_NOTE_ENTITY_TYPES = {"journal_entry", "note"}
FOOD_PRESET_ENTITY_TYPES = {"food_preset"}
PERMISSION_ENTITY_TYPES = {"permission", "standing_authorization"}
DECISION_CHOICE_ENTITY_TYPES = {"choice", "decision_choice"}
EXTERNAL_MIRROR_ENTITY_TYPES = {"external_mirror"}

PERMISSION_RESTRICTION = {
    "authorized": 0,
    "limited": 1,
    "restricted": 2,
    "denied": 3,
    "revoked": 4,
}


class SyncError(RuntimeError):
    code = "SYNC_ERROR"
    retryable = False


class BatchIdempotencyConflictError(SyncError):
    code = "SYNC_BATCH_IDEMPOTENCY_REUSED"


class OperationIdempotencyConflictError(SyncError):
    code = "SYNC_OPERATION_IDEMPOTENCY_REUSED"


class CursorAheadError(SyncError):
    code = "SYNC_CURSOR_AHEAD"


class ClientSchemaTooOldError(SyncError):
    code = "SYNC_CLIENT_SCHEMA_TOO_OLD"


class ClientSchemaTooNewError(SyncError):
    code = "SYNC_CLIENT_SCHEMA_TOO_NEW"


@dataclass(frozen=True, slots=True)
class MergeDecision:
    outcome: Literal["accepted", "conflict", "rejected", "noop"]
    document: dict[str, Any]
    field_versions: dict[str, int]
    canonical_revision: int | None
    merge_result: str
    code: str | None = None
    message: str | None = None
    conflicting_fields: tuple[str, ...] = ()


def canonical_hash(value: dict[str, Any]) -> str:
    content = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
    return sha256(content).hexdigest()


def request_hash(request: SyncPushRequest) -> str:
    document = request.model_dump(mode="json")
    document["operations"] = [
        canonical_operation_document(operation) for operation in request.operations
    ]
    return canonical_hash(document)


def operation_hash(operation: SyncOperationInput) -> str:
    return canonical_hash(canonical_operation_document(operation))


def operation_idempotency_key(operation: SyncOperationInput) -> str:
    return operation.idempotency_key or str(operation.operation_id)


def utc_instant(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def changed_fields(base: dict[str, Any], value: dict[str, Any]) -> set[str]:
    keys = set(base) | set(value)
    return {key for key in keys if base.get(key) != value.get(key)}


def field_versions_for_create(document: dict[str, Any], revision: int) -> dict[str, int]:
    return {key: revision for key in document}


def field_versions_for_update(
    current: dict[str, int], payload: dict[str, Any], revision: int
) -> dict[str, int]:
    versions = dict(current)
    versions.update({key: revision for key in payload})
    return versions


def most_restrictive_permission(current: str | None, incoming: str | None) -> str | None:
    if current is None:
        return incoming
    if incoming is None:
        return current
    current_rank = PERMISSION_RESTRICTION.get(current, len(PERMISSION_RESTRICTION))
    incoming_rank = PERMISSION_RESTRICTION.get(incoming, len(PERMISSION_RESTRICTION))
    return current if current_rank >= incoming_rank else incoming


class SyncService:
    def __init__(
        self,
        *,
        minimum_client_schema_version: int = 1,
        current_schema_version: int = CURRENT_SYNC_SCHEMA_VERSION,
    ) -> None:
        self.minimum_client_schema_version = minimum_client_schema_version
        self.current_schema_version = current_schema_version

    async def push(
        self,
        session: AsyncSession,
        *,
        request: SyncPushRequest,
        batch_idempotency_key: str,
        server_time: datetime | None = None,
    ) -> SyncPushResponse:
        received_at = server_time or datetime.now(UTC)
        batch_hash = request_hash(request)
        receipt = await session.get(
            SyncBatchReceiptRecord,
            (request.device_id, batch_idempotency_key),
        )
        if receipt is not None:
            if receipt.request_hash != batch_hash:
                raise BatchIdempotencyConflictError(
                    "batch idempotency key was reused with different content"
                )
            return SyncPushResponse.model_validate(receipt.response)

        self.validate_schema(request.client_schema_version)
        device = await self.lock_device(session, request, received_at)
        state = await self.lock_state(session, received_at)
        base_cursor = parse_cursor(request.base_cursor)
        if base_cursor > state.last_change_id:
            raise CursorAheadError("client cursor is ahead of the server change log")
        await session.flush()

        accepted: list[AcceptedOperation] = []
        rejected: list[RejectedOperation] = []
        conflicts: list[SyncConflictSummary] = []
        for operation in request.operations:
            existing = await session.get(SyncOperationRecord, operation.operation_id)
            if existing is not None:
                if (
                    existing.device_id != request.device_id
                    or existing.request_hash != operation_hash(operation)
                ):
                    rejected.append(
                        RejectedOperation(
                            operation_id=operation.operation_id,
                            code="OPERATION_ID_REUSED",
                            message="The operation ID was already used for different content.",
                            retryable=False,
                        )
                    )
                else:
                    self.restore_result(existing.result, accepted, rejected, conflicts)
                continue

            idempotent_operation = await session.scalar(
                select(SyncOperationRecord.operation_id).where(
                    SyncOperationRecord.device_id == request.device_id,
                    SyncOperationRecord.idempotency_key == operation_idempotency_key(operation),
                )
            )
            if idempotent_operation is not None:
                raise OperationIdempotencyConflictError(
                    "operation idempotency key was reused with a different operation ID"
                )

            expected_sequence = device.last_device_sequence + 1
            if operation.device_sequence != expected_sequence:
                rejected.append(
                    RejectedOperation(
                        operation_id=operation.operation_id,
                        code="DEVICE_SEQUENCE_GAP",
                        message=f"Expected device sequence {expected_sequence}.",
                        retryable=True,
                    )
                )
                break

            decision = await self.merge(session, operation)
            result = await self.persist_operation_result(
                session,
                request=request,
                operation=operation,
                decision=decision,
                state=state,
                received_at=received_at,
            )
            if isinstance(result, AcceptedOperation):
                accepted.append(result)
            elif isinstance(result, RejectedOperation):
                rejected.append(result)
            else:
                conflicts.append(result)
            device.last_device_sequence = operation.device_sequence
            operation_skew = int((received_at - operation.created_at).total_seconds())
            if device.clock_skew_seconds is None or abs(operation_skew) > abs(
                device.clock_skew_seconds
            ):
                device.clock_skew_seconds = operation_skew

        device.client_schema_version = request.client_schema_version
        device.last_push_at = received_at
        state.updated_at = received_at
        response = SyncPushResponse(
            accepted=tuple(accepted),
            rejected=tuple(rejected),
            conflicts=tuple(conflicts),
            next_cursor=format_cursor(state.last_change_id),
            server_time=received_at,
            server_schema_version=self.current_schema_version,
            minimum_client_schema_version=self.minimum_client_schema_version,
        )
        session.add(
            SyncBatchReceiptRecord(
                device_id=request.device_id,
                idempotency_key=batch_idempotency_key,
                request_hash=batch_hash,
                response=response.model_dump(mode="json"),
                created_at=received_at,
            )
        )
        await session.flush()
        return response

    async def pull(
        self,
        session: AsyncSession,
        *,
        cursor: str,
        limit: int,
        server_time: datetime | None = None,
        device_id: UUID | None = None,
    ) -> SyncPullResponse:
        if limit < 1 or limit > 500:
            raise ValueError("sync pull limit must be between 1 and 500")
        requested_cursor = parse_cursor(cursor)
        state = await self.lock_state(session, server_time or datetime.now(UTC))
        if requested_cursor > state.last_change_id:
            raise CursorAheadError("client cursor is ahead of the server change log")
        rows = list(
            (
                await session.scalars(
                    select(ServerChangeRecord)
                    .where(ServerChangeRecord.change_id > requested_cursor)
                    .order_by(ServerChangeRecord.change_id.asc())
                    .limit(limit + 1)
                )
            ).all()
        )
        has_more = len(rows) > limit
        page = rows[:limit]
        next_change_id = page[-1].change_id if page else requested_cursor
        now = server_time or datetime.now(UTC)
        if device_id is not None:
            device = await session.get(SyncDeviceRecord, device_id)
            if device is not None:
                device.last_pull_at = now
                device.last_server_cursor = next_change_id
        return SyncPullResponse(
            changes=tuple(self.change_contract(row) for row in page),
            next_cursor=format_cursor(next_change_id),
            has_more=has_more,
            server_time=now,
            server_schema_version=self.current_schema_version,
            minimum_client_schema_version=self.minimum_client_schema_version,
        )

    def validate_schema(self, client_schema_version: int) -> None:
        if client_schema_version < self.minimum_client_schema_version:
            raise ClientSchemaTooOldError("client schema is below the supported minimum")
        if client_schema_version > self.current_schema_version:
            raise ClientSchemaTooNewError("client schema is newer than this server")

    async def lock_device(
        self,
        session: AsyncSession,
        request: SyncPushRequest,
        received_at: datetime,
    ) -> SyncDeviceRecord:
        device = await session.scalar(
            select(SyncDeviceRecord)
            .where(SyncDeviceRecord.id == request.device_id)
            .with_for_update()
        )
        if device is None:
            device = SyncDeviceRecord(
                id=request.device_id,
                last_device_sequence=0,
                last_server_cursor=0,
                client_schema_version=request.client_schema_version,
                registered_at=received_at,
            )
            session.add(device)
        return device

    async def lock_state(self, session: AsyncSession, received_at: datetime) -> SyncStateRecord:
        state = await session.scalar(
            select(SyncStateRecord).where(SyncStateRecord.key == SYNC_STATE_KEY).with_for_update()
        )
        if state is None:
            state = SyncStateRecord(
                key=SYNC_STATE_KEY,
                last_change_id=0,
                updated_at=received_at,
            )
            session.add(state)
        return state

    async def merge(self, session: AsyncSession, operation: SyncOperationInput) -> MergeDecision:
        current = await session.get(
            CanonicalEntityRecord,
            (operation.entity_type, operation.entity_id),
        )
        if operation.mutation_type is SyncMutationType.DELETE:
            if current is None:
                return MergeDecision(
                    outcome="accepted",
                    document={},
                    field_versions={},
                    canonical_revision=1,
                    merge_result="tombstone_created_for_absent_entity",
                )
            if current.tombstoned:
                return MergeDecision(
                    outcome="noop",
                    document=current.document,
                    field_versions=current.field_versions,
                    canonical_revision=current.canonical_revision,
                    merge_result="tombstone_already_current",
                )
            return MergeDecision(
                outcome="accepted",
                document={},
                field_versions={},
                canonical_revision=current.canonical_revision + 1,
                merge_result=(
                    "tombstone_wins_over_stale_edit"
                    if operation.base_revision != current.canonical_revision
                    else "tombstone_applied"
                ),
            )

        if current is not None and current.tombstoned:
            return MergeDecision(
                outcome="conflict",
                document=current.document,
                field_versions=current.field_versions,
                canonical_revision=current.canonical_revision,
                merge_result="tombstone_prevents_resurrection",
                code="ENTITY_TOMBSTONED",
                message="A deleted entity cannot be resurrected by a stale operation.",
            )

        if operation.mutation_type is SyncMutationType.CREATE:
            if current is None:
                return MergeDecision(
                    outcome="accepted",
                    document=dict(operation.payload),
                    field_versions=field_versions_for_create(operation.payload, 1),
                    canonical_revision=1,
                    merge_result="created",
                )
            if canonical_hash(current.document) == canonical_hash(operation.payload):
                return MergeDecision(
                    outcome="noop",
                    document=current.document,
                    field_versions=current.field_versions,
                    canonical_revision=current.canonical_revision,
                    merge_result="duplicate_content_union",
                )
            return MergeDecision(
                outcome="conflict",
                document=current.document,
                field_versions=current.field_versions,
                canonical_revision=current.canonical_revision,
                merge_result="create_conflict_preserved",
                code="ENTITY_ALREADY_EXISTS",
                message="The entity already has different canonical content.",
                conflicting_fields=tuple(
                    sorted(changed_fields(current.document, operation.payload))
                ),
            )

        if current is None:
            return MergeDecision(
                outcome="rejected",
                document={},
                field_versions={},
                canonical_revision=None,
                merge_result="entity_missing",
                code="ENTITY_NOT_FOUND",
                message="The entity does not exist on the server.",
            )
        if operation.entity_type in APPEND_ONLY_ENTITY_TYPES:
            return MergeDecision(
                outcome="rejected",
                document=current.document,
                field_versions=current.field_versions,
                canonical_revision=current.canonical_revision,
                merge_result="append_only_update_rejected",
                code="APPEND_ONLY_ENTITY",
                message="Append-only observations cannot be updated.",
            )

        next_revision = current.canonical_revision + 1
        if operation.base_revision == current.canonical_revision:
            document = current.document | dict(operation.payload)
            return MergeDecision(
                outcome="accepted",
                document=document,
                field_versions=field_versions_for_update(
                    current.field_versions, operation.payload, next_revision
                ),
                canonical_revision=next_revision,
                merge_result="optimistic_update",
            )

        if operation.entity_type in PERMISSION_ENTITY_TYPES:
            document = current.document | dict(operation.payload)
            restrictive = most_restrictive_permission(
                str(current.document.get("status")) if "status" in current.document else None,
                str(operation.payload.get("status")) if "status" in operation.payload else None,
            )
            if restrictive is not None:
                document["status"] = restrictive
            return MergeDecision(
                outcome="accepted",
                document=document,
                field_versions=field_versions_for_update(
                    current.field_versions, operation.payload, next_revision
                ),
                canonical_revision=next_revision,
                merge_result="most_restrictive_permission_wins",
            )

        if operation.entity_type in DECISION_CHOICE_ENTITY_TYPES:
            document = current.document | dict(operation.payload)
            return MergeDecision(
                outcome="accepted",
                document=document,
                field_versions=field_versions_for_update(
                    current.field_versions, operation.payload, next_revision
                ),
                canonical_revision=next_revision,
                merge_result="explicit_choice_revision",
            )

        if operation.entity_type in EXTERNAL_MIRROR_ENTITY_TYPES:
            current_source_revision = str(current.document.get("source_revision", ""))
            incoming_source_revision = str(operation.payload.get("source_revision", ""))
            if incoming_source_revision > current_source_revision:
                document = current.document | dict(operation.payload)
                return MergeDecision(
                    outcome="accepted",
                    document=document,
                    field_versions=field_versions_for_update(
                        current.field_versions, operation.payload, next_revision
                    ),
                    canonical_revision=next_revision,
                    merge_result="newer_external_source_revision",
                )
            return MergeDecision(
                outcome="noop",
                document=current.document,
                field_versions=current.field_versions,
                canonical_revision=current.canonical_revision,
                merge_result="stale_external_source_revision_ignored",
            )

        if operation.entity_type in FOOD_PRESET_ENTITY_TYPES:
            base_document = await self.document_at_revision(
                session,
                entity_type=operation.entity_type,
                entity_id=operation.entity_id,
                revision=operation.base_revision,
            )
            if base_document is not None:
                current_changes = changed_fields(base_document, current.document)
                incoming_changes = changed_fields(
                    base_document,
                    base_document | dict(operation.payload),
                )
                overlap = current_changes & incoming_changes
                if not overlap:
                    document = current.document | dict(operation.payload)
                    return MergeDecision(
                        outcome="accepted",
                        document=document,
                        field_versions=field_versions_for_update(
                            current.field_versions, operation.payload, next_revision
                        ),
                        canonical_revision=next_revision,
                        merge_result="disjoint_field_merge",
                    )
                conflicting_fields = tuple(sorted(overlap))
            else:
                conflicting_fields = tuple(sorted(operation.payload))
            return self.preserved_conflict(
                current,
                code="OVERLAPPING_FIELD_EDITS",
                message="Food preset edits overlap and require review.",
                fields=conflicting_fields,
            )

        if operation.entity_type in NORMATIVE_ENTITY_TYPES:
            return self.preserved_conflict(
                current,
                code="NORMATIVE_REVISION_CONFLICT",
                message="Normative text changed concurrently and requires review.",
                fields=tuple(sorted(operation.payload)),
            )
        if operation.entity_type in EDITABLE_NOTE_ENTITY_TYPES:
            return self.preserved_conflict(
                current,
                code="EDITABLE_NOTE_CONFLICT",
                message="Both note revisions were preserved for review.",
                fields=tuple(sorted(operation.payload)),
            )
        return self.preserved_conflict(
            current,
            code="BASE_REVISION_CONFLICT",
            message="The canonical entity changed after the operation base revision.",
            fields=tuple(sorted(operation.payload)),
        )

    @staticmethod
    def preserved_conflict(
        current: CanonicalEntityRecord,
        *,
        code: str,
        message: str,
        fields: tuple[str, ...],
    ) -> MergeDecision:
        return MergeDecision(
            outcome="conflict",
            document=current.document,
            field_versions=current.field_versions,
            canonical_revision=current.canonical_revision,
            merge_result="concurrent_revisions_preserved",
            code=code,
            message=message,
            conflicting_fields=fields,
        )

    async def persist_operation_result(
        self,
        session: AsyncSession,
        *,
        request: SyncPushRequest,
        operation: SyncOperationInput,
        decision: MergeDecision,
        state: SyncStateRecord,
        received_at: datetime,
    ) -> AcceptedOperation | RejectedOperation | SyncConflictSummary:
        if decision.outcome in {"accepted", "noop"}:
            result = await self.prepare_accepted(
                session,
                operation=operation,
                decision=decision,
                state=state,
            )
            result_document = {"kind": "accepted", "value": result.model_dump(mode="json")}
            operation_record = self.operation_record(
                request,
                operation,
                received_at,
                status="accepted",
                canonical_revision=result.canonical_revision,
                server_change_id=result.server_change_id,
                result=result_document,
            )
            session.add(operation_record)
            await session.flush()
            if decision.outcome == "accepted":
                await self.apply_accepted_change(
                    session,
                    request=request,
                    operation=operation,
                    decision=decision,
                    change_id=result.server_change_id,
                    received_at=received_at,
                )
            return result

        if decision.outcome == "rejected":
            rejected = RejectedOperation(
                operation_id=operation.operation_id,
                code=decision.code or "SYNC_OPERATION_REJECTED",
                message=decision.message or "The operation was rejected.",
                retryable=False,
            )
            session.add(
                self.operation_record(
                    request,
                    operation,
                    received_at,
                    status="rejected",
                    canonical_revision=decision.canonical_revision,
                    result={"kind": "rejected", "value": rejected.model_dump(mode="json")},
                )
            )
            return rejected

        conflict_id = new_uuid7()
        conflict = SyncConflictSummary(
            conflict_id=conflict_id,
            operation_id=operation.operation_id,
            entity_type=operation.entity_type,
            entity_id=operation.entity_id,
            code=decision.code or "SYNC_CONFLICT_REQUIRES_REVIEW",
            current_revision=decision.canonical_revision,
            conflicting_fields=decision.conflicting_fields,
        )
        operation_record = self.operation_record(
            request,
            operation,
            received_at,
            status="conflict",
            canonical_revision=decision.canonical_revision,
            conflict_id=conflict_id,
            result={"kind": "conflict", "value": conflict.model_dump(mode="json")},
        )
        session.add(operation_record)
        await session.flush()
        session.add(
            SyncConflictRecord(
                id=conflict_id,
                operation_id=operation.operation_id,
                device_id=request.device_id,
                entity_type=operation.entity_type,
                entity_id=operation.entity_id,
                conflict_code=conflict.code,
                base_revision=operation.base_revision,
                current_revision=decision.canonical_revision,
                current_document=decision.document,
                incoming_document=dict(operation.payload),
                conflicting_fields=list(decision.conflicting_fields),
                status="pending",
                created_at=received_at,
            )
        )
        return conflict

    async def prepare_accepted(
        self,
        session: AsyncSession,
        *,
        operation: SyncOperationInput,
        decision: MergeDecision,
        state: SyncStateRecord,
    ) -> AcceptedOperation:
        if decision.canonical_revision is None:
            raise RuntimeError("accepted operation requires a canonical revision")
        if decision.outcome == "noop":
            latest = await self.latest_change(
                session,
                entity_type=operation.entity_type,
                entity_id=operation.entity_id,
            )
            if latest is None:
                raise RuntimeError("canonical entity has no server change")
            return AcceptedOperation(
                operation_id=operation.operation_id,
                canonical_revision=decision.canonical_revision,
                server_change_id=latest.change_id,
                merge_result=decision.merge_result,
            )

        state.last_change_id += 1
        change_id = state.last_change_id
        return AcceptedOperation(
            operation_id=operation.operation_id,
            canonical_revision=decision.canonical_revision,
            server_change_id=change_id,
            merge_result=decision.merge_result,
        )

    @staticmethod
    async def apply_accepted_change(
        session: AsyncSession,
        *,
        request: SyncPushRequest,
        operation: SyncOperationInput,
        decision: MergeDecision,
        change_id: int,
        received_at: datetime,
    ) -> None:
        if decision.canonical_revision is None:
            raise RuntimeError("accepted operation requires a canonical revision")
        current = await session.get(
            CanonicalEntityRecord,
            (operation.entity_type, operation.entity_id),
        )
        tombstone = operation.mutation_type is SyncMutationType.DELETE
        deletion_epoch = change_id if tombstone else None
        content_hash = canonical_hash(decision.document)
        if current is None:
            current = CanonicalEntityRecord(
                entity_type=operation.entity_type,
                entity_id=operation.entity_id,
                canonical_revision=decision.canonical_revision,
                document=decision.document,
                field_versions=decision.field_versions,
                content_hash=content_hash,
                tombstoned=tombstone,
                deletion_epoch=deletion_epoch,
                updated_at=received_at,
                last_operation_id=operation.operation_id,
                last_device_id=request.device_id,
            )
            session.add(current)
        else:
            current.canonical_revision = decision.canonical_revision
            current.document = decision.document
            current.field_versions = decision.field_versions
            current.content_hash = content_hash
            current.tombstoned = tombstone
            current.deletion_epoch = deletion_epoch
            current.updated_at = received_at
            current.last_operation_id = operation.operation_id
            current.last_device_id = request.device_id
        session.add(
            ServerChangeRecord(
                change_id=change_id,
                entity_type=operation.entity_type,
                entity_id=operation.entity_id,
                canonical_revision=decision.canonical_revision,
                mutation_type=operation.mutation_type.value,
                payload=decision.document,
                content_hash=content_hash,
                tombstone=tombstone,
                deletion_epoch=deletion_epoch,
                merge_result=decision.merge_result,
                origin_operation_id=operation.operation_id,
                origin_device_id=request.device_id,
                received_at=received_at,
            )
        )
        session.add(
            OutboxRecord(
                id=new_uuid7(),
                topic="sync-canonical-change",
                aggregate_id=operation.entity_id,
                payload={
                    "change_id": change_id,
                    "entity_type": operation.entity_type,
                    "entity_id": str(operation.entity_id),
                    "canonical_revision": decision.canonical_revision,
                    "tombstone": tombstone,
                },
                idempotency_key=f"sync-change:{change_id}",
                status="pending",
                attempts=0,
                available_at=received_at,
                created_at=received_at,
            )
        )

    @staticmethod
    def operation_record(
        request: SyncPushRequest,
        operation: SyncOperationInput,
        received_at: datetime,
        *,
        status: str,
        canonical_revision: int | None,
        result: dict[str, Any],
        server_change_id: int | None = None,
        conflict_id: UUID | None = None,
    ) -> SyncOperationRecord:
        return SyncOperationRecord(
            operation_id=operation.operation_id,
            device_id=request.device_id,
            device_sequence=operation.device_sequence,
            entity_type=operation.entity_type,
            entity_id=operation.entity_id,
            mutation_type=operation.mutation_type.value,
            base_revision=operation.base_revision,
            payload=dict(operation.payload),
            created_at=operation.created_at,
            received_at=received_at,
            idempotency_key=operation_idempotency_key(operation),
            sensitivity_class=operation.sensitivity_class.value,
            request_hash=operation_hash(operation),
            status=status,
            canonical_revision=canonical_revision,
            server_change_id=server_change_id,
            conflict_id=conflict_id,
            result=result,
        )

    @staticmethod
    def restore_result(
        result: dict[str, Any],
        accepted: list[AcceptedOperation],
        rejected: list[RejectedOperation],
        conflicts: list[SyncConflictSummary],
    ) -> None:
        kind = result["kind"]
        if kind == "accepted":
            accepted.append(AcceptedOperation.model_validate(result["value"]))
        elif kind == "rejected":
            rejected.append(RejectedOperation.model_validate(result["value"]))
        elif kind == "conflict":
            conflicts.append(SyncConflictSummary.model_validate(result["value"]))
        else:
            raise RuntimeError(f"unknown persisted sync result kind: {kind}")

    @staticmethod
    def change_contract(record: ServerChangeRecord) -> SyncChange:
        return SyncChange(
            change_id=record.change_id,
            canonical_revision=record.canonical_revision,
            entity_type=record.entity_type,
            entity_id=record.entity_id,
            mutation_type=SyncMutationType(record.mutation_type),
            payload=record.payload,
            tombstone=record.tombstone,
            deletion_epoch=record.deletion_epoch,
            merge_result=record.merge_result,
            origin_device_id=record.origin_device_id,
            origin_operation_id=record.origin_operation_id,
            server_received_at=utc_instant(record.received_at),
        )

    @staticmethod
    async def latest_change(
        session: AsyncSession,
        *,
        entity_type: str,
        entity_id: UUID,
    ) -> ServerChangeRecord | None:
        result = await session.scalars(
            select(ServerChangeRecord)
            .where(
                ServerChangeRecord.entity_type == entity_type,
                ServerChangeRecord.entity_id == entity_id,
            )
            .order_by(ServerChangeRecord.change_id.desc())
            .limit(1)
        )
        return result.first()

    @staticmethod
    async def document_at_revision(
        session: AsyncSession,
        *,
        entity_type: str,
        entity_id: UUID,
        revision: int | None,
    ) -> dict[str, Any] | None:
        if revision is None:
            return None
        return await session.scalar(
            select(ServerChangeRecord.payload)
            .where(
                ServerChangeRecord.entity_type == entity_type,
                ServerChangeRecord.entity_id == entity_id,
                ServerChangeRecord.canonical_revision == revision,
                ServerChangeRecord.tombstone.is_(False),
            )
            .order_by(ServerChangeRecord.change_id.desc())
            .limit(1)
        )
