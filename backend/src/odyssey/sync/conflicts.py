"""Meaningful conflict inspection and explicit immutable resolution records."""

import json
from datetime import UTC, datetime
from hashlib import sha256
from uuid import UUID

from pydantic import JsonValue
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.domain.common import new_uuid7
from odyssey.sync.contracts import (
    AcceptedOperation,
    ConflictResolutionStrategy,
    SyncConflictDetail,
    SyncConflictListResponse,
    SyncConflictResolutionRequest,
    SyncConflictResolutionResponse,
    SyncConflictStatusFilter,
    SyncMutationType,
    SyncOperationInput,
    SyncPushRequest,
    format_cursor,
)
from odyssey.sync.models import (
    CanonicalEntityRecord,
    SyncConflictRecord,
    SyncConflictResolutionRecord,
    SyncOperationRecord,
)
from odyssey.sync.service import (
    APPEND_ONLY_ENTITY_TYPES,
    MergeDecision,
    OperationIdempotencyConflictError,
    SyncError,
    SyncService,
    field_versions_for_create,
    operation_idempotency_key,
)


class SyncConflictNotFoundError(SyncError):
    code = "SYNC_CONFLICT_NOT_FOUND"


class SyncConflictAlreadyResolvedError(SyncError):
    code = "SYNC_CONFLICT_ALREADY_RESOLVED"


class SyncConflictResolutionStaleError(SyncError):
    code = "SYNC_CONFLICT_RESOLUTION_STALE"


class SyncConflictStrategyError(SyncError):
    code = "SYNC_CONFLICT_STRATEGY_NOT_ALLOWED"


class SyncDeviceSequenceError(SyncError):
    code = "SYNC_DEVICE_SEQUENCE_MISMATCH"
    retryable = True


class SyncConflictService:
    def __init__(self, sync: SyncService) -> None:
        self.sync = sync

    async def list(
        self,
        session: AsyncSession,
        *,
        status: SyncConflictStatusFilter,
        limit: int,
        server_time: datetime,
    ) -> SyncConflictListResponse:
        statement = select(SyncConflictRecord).order_by(
            SyncConflictRecord.created_at,
            SyncConflictRecord.id,
        )
        if status is not SyncConflictStatusFilter.ALL:
            statement = statement.where(SyncConflictRecord.status == status.value)
        conflicts = tuple((await session.scalars(statement.limit(limit))).all())
        pending_count = int(
            await session.scalar(
                select(func.count())
                .select_from(SyncConflictRecord)
                .where(SyncConflictRecord.status == SyncConflictStatusFilter.PENDING.value)
            )
            or 0
        )
        return SyncConflictListResponse(
            conflicts=tuple(self.contract(conflict) for conflict in conflicts),
            pending_count=pending_count,
            server_time=server_time,
        )

    async def resolve(
        self,
        session: AsyncSession,
        *,
        conflict_id: UUID,
        request: SyncConflictResolutionRequest,
        server_time: datetime,
    ) -> SyncConflictResolutionResponse:
        request_hash = self.request_hash(request)
        existing_resolution = await session.scalar(
            select(SyncConflictResolutionRecord).where(
                SyncConflictResolutionRecord.conflict_id == conflict_id
            )
        )
        if existing_resolution is not None:
            if existing_resolution.request_hash == request_hash:
                return SyncConflictResolutionResponse.model_validate(existing_resolution.response)
            raise SyncConflictAlreadyResolvedError("conflict already has a different resolution")

        conflict = await session.scalar(
            select(SyncConflictRecord).where(SyncConflictRecord.id == conflict_id).with_for_update()
        )
        if conflict is None:
            raise SyncConflictNotFoundError("sync conflict does not exist")
        if conflict.status != SyncConflictStatusFilter.PENDING:
            raise SyncConflictAlreadyResolvedError("sync conflict is no longer pending")
        current = await session.scalar(
            select(CanonicalEntityRecord)
            .where(
                CanonicalEntityRecord.entity_type == conflict.entity_type,
                CanonicalEntityRecord.entity_id == conflict.entity_id,
            )
            .with_for_update()
        )
        if (
            current is None
            or current.canonical_revision != request.expected_current_revision
            or conflict.current_revision != request.expected_current_revision
        ):
            raise SyncConflictResolutionStaleError(
                "canonical state changed after this conflict was presented"
            )
        allowed_strategies = self.allowed_strategies(conflict)
        if request.strategy not in allowed_strategies:
            raise SyncConflictStrategyError("resolution strategy violates the entity merge policy")
        self.sync.validate_schema(request.client_schema_version)
        device_request, operation, resolved_document = self.resolution_operation(
            conflict,
            current,
            request,
        )
        device = await self.sync.lock_device(session, device_request, server_time)
        state = await self.sync.lock_state(session, server_time)
        if await session.get(SyncOperationRecord, operation.operation_id) is not None:
            raise OperationIdempotencyConflictError("resolution operation ID is already in use")
        operation_with_key = await session.scalar(
            select(SyncOperationRecord.operation_id).where(
                SyncOperationRecord.device_id == request.device_id,
                SyncOperationRecord.idempotency_key == operation_idempotency_key(operation),
            )
        )
        if operation_with_key is not None:
            raise OperationIdempotencyConflictError(
                "resolution operation idempotency key is already in use"
            )
        expected_sequence = device.last_device_sequence + 1
        if request.device_sequence != expected_sequence:
            raise SyncDeviceSequenceError(
                f"expected device sequence {expected_sequence} for conflict resolution"
            )
        next_revision = current.canonical_revision + 1
        decision = MergeDecision(
            outcome="accepted",
            document=resolved_document,
            field_versions=field_versions_for_create(resolved_document, next_revision),
            canonical_revision=next_revision,
            merge_result=f"conflict_resolved_{request.strategy.value}",
        )
        accepted = await self.sync.persist_operation_result(
            session,
            request=device_request,
            operation=operation,
            decision=decision,
            state=state,
            received_at=server_time,
        )
        if not isinstance(accepted, AcceptedOperation):
            raise RuntimeError("conflict resolution did not produce an accepted operation")
        device.last_device_sequence = request.device_sequence
        device.client_schema_version = request.client_schema_version
        device.last_push_at = server_time
        operation_skew = int((server_time - request.created_at).total_seconds())
        if device.clock_skew_seconds is None or abs(operation_skew) > abs(
            device.clock_skew_seconds
        ):
            device.clock_skew_seconds = operation_skew
        state.updated_at = server_time

        resolution_id = new_uuid7()
        response = SyncConflictResolutionResponse(
            resolution_id=resolution_id,
            conflict_id=conflict.id,
            status="resolved",
            strategy=request.strategy,
            accepted_operation=accepted,
            next_cursor=format_cursor(state.last_change_id),
            server_time=server_time,
            server_schema_version=self.sync.current_schema_version,
        )
        resolution_document = {
            "resolution_id": str(resolution_id),
            "strategy": request.strategy.value,
            "operation_id": str(operation.operation_id),
        }
        conflict.status = "resolved"
        conflict.resolved_at = server_time
        conflict.resolution = resolution_document
        session.add(
            SyncConflictResolutionRecord(
                id=resolution_id,
                conflict_id=conflict.id,
                operation_id=operation.operation_id,
                device_id=request.device_id,
                strategy=request.strategy.value,
                request_hash=request_hash,
                resolved_document=resolved_document,
                response=response.model_dump(mode="json"),
                created_at=server_time,
            )
        )
        await session.flush()
        return response

    def resolution_operation(
        self,
        conflict: SyncConflictRecord,
        current: CanonicalEntityRecord,
        request: SyncConflictResolutionRequest,
    ) -> tuple[SyncPushRequest, SyncOperationInput, dict[str, JsonValue]]:
        if current.tombstoned:
            mutation_type = SyncMutationType.DELETE
            resolved_document: dict[str, JsonValue] = {}
            payload: dict[str, JsonValue] = {}
        else:
            mutation_type = SyncMutationType.UPDATE
            if request.strategy is ConflictResolutionStrategy.KEEP_CURRENT:
                resolved_document = dict(current.document)
            elif request.strategy is ConflictResolutionStrategy.ACCEPT_INCOMING:
                resolved_document = current.document | conflict.incoming_document
            else:
                resolved_document = dict(request.merged_document or {})
            payload = resolved_document
        operation = SyncOperationInput(
            operation_id=request.operation_id,
            device_sequence=request.device_sequence,
            entity_type=conflict.entity_type,
            entity_id=conflict.entity_id,
            mutation_type=mutation_type,
            base_revision=(
                None if mutation_type is SyncMutationType.DELETE else current.canonical_revision
            ),
            payload=payload,
            created_at=request.created_at,
            idempotency_key=request.idempotency_key,
            sensitivity_class=request.sensitivity_class,
        )
        return (
            SyncPushRequest(
                device_id=request.device_id,
                client_schema_version=request.client_schema_version,
                base_cursor="c_0",
                operations=(operation,),
            ),
            operation,
            resolved_document,
        )

    @staticmethod
    def contract(conflict: SyncConflictRecord) -> SyncConflictDetail:
        return SyncConflictDetail(
            conflict_id=conflict.id,
            operation_id=conflict.operation_id,
            originating_device_id=conflict.device_id,
            entity_type=conflict.entity_type,
            entity_id=conflict.entity_id,
            code=conflict.conflict_code,
            base_revision=conflict.base_revision,
            current_revision=conflict.current_revision,
            current_document=conflict.current_document,
            incoming_document=conflict.incoming_document,
            conflicting_fields=tuple(conflict.conflicting_fields),
            status=conflict.status,
            created_at=SyncConflictService.aware(conflict.created_at),
            resolved_at=(
                SyncConflictService.aware(conflict.resolved_at)
                if conflict.resolved_at is not None
                else None
            ),
            explanation=SyncConflictService.explanation(conflict),
            allowed_strategies=SyncConflictService.allowed_strategies(conflict),
        )

    @staticmethod
    def allowed_strategies(
        conflict: SyncConflictRecord,
    ) -> tuple[ConflictResolutionStrategy, ...]:
        if (
            conflict.conflict_code == "ENTITY_TOMBSTONED"
            or conflict.entity_type in APPEND_ONLY_ENTITY_TYPES
        ):
            return (ConflictResolutionStrategy.KEEP_CURRENT,)
        return tuple(ConflictResolutionStrategy)

    @staticmethod
    def explanation(conflict: SyncConflictRecord) -> str:
        fields = ", ".join(conflict.conflicting_fields) or "its content"
        if conflict.conflict_code == "ENTITY_TOMBSTONED":
            return (
                f"This {conflict.entity_type} was deleted before the offline edit to {fields} "
                "arrived. Keep the deletion or create a separate new record."
            )
        if conflict.conflict_code == "NORMATIVE_REVISION_CONFLICT":
            return (
                f"Another device changed this {conflict.entity_type} before the edit to {fields} "
                "arrived. Keep one meaning or merge them into an explicit revision."
            )
        return (
            f"Another device's revision of this {conflict.entity_type} changed {fields}. "
            "Keep the current revision, accept the incoming edit, or merge them."
        )

    @staticmethod
    def request_hash(request: SyncConflictResolutionRequest) -> str:
        document = request.model_dump(mode="json")
        document["idempotency_key"] = request.idempotency_key or str(request.operation_id)
        content = json.dumps(document, separators=(",", ":"), sort_keys=True).encode()
        return sha256(content).hexdigest()

    @staticmethod
    def aware(value: datetime) -> datetime:
        return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
