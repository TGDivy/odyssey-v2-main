"""Deterministic canonical sync projection rebuild from immutable records."""

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from hashlib import sha256
from typing import Any
from uuid import UUID

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.sync.models import (
    CanonicalEntityRecord,
    ServerChangeRecord,
    SyncOperationRecord,
    SyncStateRecord,
)
from odyssey.sync.service import SYNC_STATE_KEY, canonical_hash

SYNC_PROJECTION_VERSION = "sync-canonical.v1"


class SyncProjectionRebuildError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class ExpectedSyncEntity:
    entity_type: str
    entity_id: UUID
    canonical_revision: int
    document: dict[str, Any]
    field_versions: dict[str, int]
    content_hash: str
    tombstoned: bool
    deletion_epoch: int | None
    updated_at: datetime
    last_operation_id: UUID
    last_device_id: UUID


@dataclass(frozen=True, slots=True)
class SyncProjectionRebuildReport:
    projection_version: str
    operation_count: int
    change_count: int
    entity_count: int
    last_cursor: int
    checksum: str


@dataclass(frozen=True, slots=True)
class SyncProjectionIntegrityReport:
    healthy: bool
    expected_entity_count: int
    actual_entity_count: int
    mismatched_entities: int
    expected_cursor: int
    actual_cursor: int
    checksum: str


class SyncProjectionRebuilder:
    async def rebuild(
        self,
        session: AsyncSession,
        *,
        rebuilt_at: datetime | None = None,
    ) -> SyncProjectionRebuildReport:
        rebuild_time = rebuilt_at or datetime.now(UTC)
        expected, operation_count, change_count, last_cursor = await self.expected(session)
        await session.execute(delete(CanonicalEntityRecord))
        for key in sorted(expected, key=lambda value: (value[0], str(value[1]))):
            entity = expected[key]
            session.add(
                CanonicalEntityRecord(
                    entity_type=entity.entity_type,
                    entity_id=entity.entity_id,
                    canonical_revision=entity.canonical_revision,
                    document=entity.document,
                    field_versions=entity.field_versions,
                    content_hash=entity.content_hash,
                    tombstoned=entity.tombstoned,
                    deletion_epoch=entity.deletion_epoch,
                    updated_at=entity.updated_at,
                    last_operation_id=entity.last_operation_id,
                    last_device_id=entity.last_device_id,
                )
            )
        state = await session.get(SyncStateRecord, SYNC_STATE_KEY)
        if state is None:
            state = SyncStateRecord(
                key=SYNC_STATE_KEY,
                last_change_id=last_cursor,
                updated_at=rebuild_time,
            )
            session.add(state)
        else:
            state.last_change_id = last_cursor
            state.updated_at = rebuild_time
        await session.flush()
        return SyncProjectionRebuildReport(
            projection_version=SYNC_PROJECTION_VERSION,
            operation_count=operation_count,
            change_count=change_count,
            entity_count=len(expected),
            last_cursor=last_cursor,
            checksum=self.checksum(expected),
        )

    async def verify(self, session: AsyncSession) -> SyncProjectionIntegrityReport:
        expected, _operation_count, _change_count, last_cursor = await self.expected(session)
        actual_records = tuple((await session.scalars(select(CanonicalEntityRecord))).all())
        actual = {
            (record.entity_type, record.entity_id): self.from_record(record)
            for record in actual_records
        }
        mismatches = len(set(expected) ^ set(actual))
        for key in set(expected) & set(actual):
            if self.entity_document(expected[key]) != self.entity_document(actual[key]):
                mismatches += 1
        state = await session.get(SyncStateRecord, SYNC_STATE_KEY)
        actual_cursor = state.last_change_id if state is not None else 0
        return SyncProjectionIntegrityReport(
            healthy=mismatches == 0 and actual_cursor == last_cursor,
            expected_entity_count=len(expected),
            actual_entity_count=len(actual),
            mismatched_entities=mismatches,
            expected_cursor=last_cursor,
            actual_cursor=actual_cursor,
            checksum=self.checksum(expected),
        )

    async def expected(
        self,
        session: AsyncSession,
    ) -> tuple[dict[tuple[str, UUID], ExpectedSyncEntity], int, int, int]:
        operations = tuple((await session.scalars(select(SyncOperationRecord))).all())
        operations_by_id = {operation.operation_id: operation for operation in operations}
        changes = tuple(
            (
                await session.scalars(
                    select(ServerChangeRecord).order_by(ServerChangeRecord.change_id)
                )
            ).all()
        )
        expected: dict[tuple[str, UUID], ExpectedSyncEntity] = {}
        for expected_change_id, change in enumerate(changes, start=1):
            if change.change_id != expected_change_id:
                raise SyncProjectionRebuildError("server change IDs are not contiguous")
            operation = operations_by_id.get(change.origin_operation_id)
            if operation is None:
                raise SyncProjectionRebuildError("server change has no immutable operation")
            if (
                operation.device_id != change.origin_device_id
                or operation.entity_type != change.entity_type
                or operation.entity_id != change.entity_id
            ):
                raise SyncProjectionRebuildError("server change origin metadata does not reconcile")
            if canonical_hash(change.payload) != change.content_hash:
                raise SyncProjectionRebuildError("server change content hash is invalid")
            key = (change.entity_type, change.entity_id)
            previous = expected.get(key)
            expected_revision = previous.canonical_revision + 1 if previous is not None else 1
            if change.canonical_revision != expected_revision:
                raise SyncProjectionRebuildError("canonical revisions are not contiguous")
            if change.tombstone:
                if change.payload or change.deletion_epoch != change.change_id:
                    raise SyncProjectionRebuildError(
                        "tombstone payload or deletion epoch is invalid"
                    )
                field_versions: dict[str, int] = {}
            elif change.deletion_epoch is not None:
                raise SyncProjectionRebuildError("live server change has a deletion epoch")
            elif previous is None or change.merge_result.startswith("conflict_resolved_"):
                field_versions = {field: change.canonical_revision for field in change.payload}
            else:
                field_versions = dict(previous.field_versions)
                field_versions.update(
                    {field: change.canonical_revision for field in operation.payload}
                )
            expected[key] = ExpectedSyncEntity(
                entity_type=change.entity_type,
                entity_id=change.entity_id,
                canonical_revision=change.canonical_revision,
                document=dict(change.payload),
                field_versions=field_versions,
                content_hash=change.content_hash,
                tombstoned=change.tombstone,
                deletion_epoch=change.deletion_epoch,
                updated_at=self.aware(change.received_at),
                last_operation_id=change.origin_operation_id,
                last_device_id=change.origin_device_id,
            )
        return expected, len(operations), len(changes), len(changes)

    @staticmethod
    def from_record(record: CanonicalEntityRecord) -> ExpectedSyncEntity:
        return ExpectedSyncEntity(
            entity_type=record.entity_type,
            entity_id=record.entity_id,
            canonical_revision=record.canonical_revision,
            document=record.document,
            field_versions=record.field_versions,
            content_hash=record.content_hash,
            tombstoned=record.tombstoned,
            deletion_epoch=record.deletion_epoch,
            updated_at=SyncProjectionRebuilder.aware(record.updated_at),
            last_operation_id=record.last_operation_id,
            last_device_id=record.last_device_id,
        )

    @staticmethod
    def entity_document(entity: ExpectedSyncEntity) -> dict[str, Any]:
        return {
            "entity_type": entity.entity_type,
            "entity_id": str(entity.entity_id),
            "canonical_revision": entity.canonical_revision,
            "document": entity.document,
            "field_versions": entity.field_versions,
            "content_hash": entity.content_hash,
            "tombstoned": entity.tombstoned,
            "deletion_epoch": entity.deletion_epoch,
            "updated_at": entity.updated_at.astimezone(UTC).isoformat(),
            "last_operation_id": str(entity.last_operation_id),
            "last_device_id": str(entity.last_device_id),
        }

    @classmethod
    def checksum(cls, entities: dict[tuple[str, UUID], ExpectedSyncEntity]) -> str:
        documents = [
            cls.entity_document(entities[key])
            for key in sorted(entities, key=lambda value: (value[0], str(value[1])))
        ]
        content = json.dumps(documents, separators=(",", ":"), sort_keys=True).encode()
        return sha256(content).hexdigest()

    @staticmethod
    def aware(value: datetime) -> datetime:
        return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
