import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID

import pytest
from pydantic import JsonValue
from sqlalchemy import func, select

from odyssey.db.base import Base
from odyssey.db.models import OutboxRecord
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.sync.contracts import SyncMutationType, SyncOperationInput, SyncPushRequest
from odyssey.sync.models import (
    CanonicalEntityRecord,
    ServerChangeRecord,
    SyncBatchReceiptRecord,
    SyncConflictRecord,
    SyncDeviceRecord,
    SyncOperationRecord,
)
from odyssey.sync.service import BatchIdempotencyConflictError, SyncService


def sync_operation(
    *,
    sequence: int,
    entity_type: str,
    entity_id: UUID,
    mutation: SyncMutationType,
    payload: dict[str, JsonValue] | None = None,
    base_revision: int | None = None,
    created_at: datetime | None = None,
) -> SyncOperationInput:
    return SyncOperationInput(
        operation_id=new_uuid7(),
        device_sequence=sequence,
        entity_type=entity_type,
        entity_id=entity_id,
        mutation_type=mutation,
        base_revision=base_revision,
        payload=payload or {},
        created_at=created_at or datetime.now(UTC),
        idempotency_key=f"operation-{new_uuid7()}",
    )


def push_request(device_id: UUID, cursor: str, *operations: SyncOperationInput) -> SyncPushRequest:
    return SyncPushRequest(
        device_id=device_id,
        client_schema_version=1,
        base_cursor=cursor,
        operations=operations,
    )


def test_two_devices_converge_and_tombstones_prevent_resurrection(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'sync.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        service = SyncService()
        iphone = new_uuid7()
        mac = new_uuid7()
        season = new_uuid7()
        now = datetime(2026, 8, 15, 12, tzinfo=UTC)

        create = sync_operation(
            sequence=1,
            entity_type="season",
            entity_id=season,
            mutation=SyncMutationType.CREATE,
            payload={"title": "Foundation", "end_date": "2026-11-30"},
            created_at=now,
        )
        create_request = push_request(iphone, "c_0", create)
        async with database.sessions() as session, session.begin():
            created = await service.push(
                session,
                request=create_request,
                batch_idempotency_key="iphone-create",
                server_time=now,
            )
        assert created.next_cursor == "c_1"
        assert created.accepted[0].canonical_revision == 1

        async with database.sessions() as session, session.begin():
            replay = await service.push(
                session,
                request=create_request,
                batch_idempotency_key="iphone-create",
                server_time=now + timedelta(minutes=1),
            )
        assert replay == created

        async with database.sessions() as session, session.begin():
            operation_replay = await service.push(
                session,
                request=create_request,
                batch_idempotency_key="iphone-create-new-batch",
                server_time=now + timedelta(minutes=2),
            )
        assert operation_replay.accepted[0] == created.accepted[0]
        assert operation_replay.next_cursor == "c_1"

        mac_update = sync_operation(
            sequence=1,
            entity_type="season",
            entity_id=season,
            mutation=SyncMutationType.UPDATE,
            payload={"end_date": "2026-12-15"},
            base_revision=1,
            created_at=now - timedelta(days=3),
        )
        async with database.sessions() as session, session.begin():
            updated = await service.push(
                session,
                request=push_request(mac, "c_1", mac_update),
                batch_idempotency_key="mac-update",
                server_time=now + timedelta(seconds=1),
            )
        assert updated.accepted[0].canonical_revision == 2

        stale_iphone = sync_operation(
            sequence=2,
            entity_type="season",
            entity_id=season,
            mutation=SyncMutationType.UPDATE,
            payload={"end_date": "2026-12-01"},
            base_revision=1,
            created_at=now,
        )
        async with database.sessions() as session, session.begin():
            conflicted = await service.push(
                session,
                request=push_request(iphone, "c_1", stale_iphone),
                batch_idempotency_key="iphone-stale",
                server_time=now + timedelta(seconds=2),
            )
        assert conflicted.conflicts[0].code == "NORMATIVE_REVISION_CONFLICT"
        assert conflicted.next_cursor == "c_2"

        delete = sync_operation(
            sequence=2,
            entity_type="season",
            entity_id=season,
            mutation=SyncMutationType.DELETE,
            base_revision=2,
            created_at=now,
        )
        async with database.sessions() as session, session.begin():
            deleted = await service.push(
                session,
                request=push_request(mac, "c_2", delete),
                batch_idempotency_key="mac-delete",
                server_time=now + timedelta(seconds=3),
            )
        assert deleted.accepted[0].canonical_revision == 3
        assert deleted.next_cursor == "c_3"

        stale_after_delete = sync_operation(
            sequence=3,
            entity_type="season",
            entity_id=season,
            mutation=SyncMutationType.UPDATE,
            payload={"title": "Resurrected"},
            base_revision=1,
            created_at=now,
        )
        async with database.sessions() as session, session.begin():
            resurrection = await service.push(
                session,
                request=push_request(iphone, "c_2", stale_after_delete),
                batch_idempotency_key="iphone-resurrection",
                server_time=now + timedelta(seconds=4),
            )
        assert resurrection.conflicts[0].code == "ENTITY_TOMBSTONED"

        async with database.sessions() as session, session.begin():
            first_page = await service.pull(session, cursor="c_0", limit=2, device_id=iphone)
            second_page = await service.pull(
                session, cursor=first_page.next_cursor, limit=2, device_id=iphone
            )
        assert [change.change_id for change in first_page.changes] == [1, 2]
        assert first_page.has_more is True
        assert [change.change_id for change in second_page.changes] == [3]
        assert second_page.changes[0].tombstone is True
        assert second_page.changes[0].deletion_epoch == 3

        async with database.sessions() as session:
            canonical = await session.get(CanonicalEntityRecord, ("season", season))
            assert canonical is not None and canonical.tombstoned is True
            change_count = int(
                await session.scalar(select(func.count()).select_from(ServerChangeRecord)) or 0
            )
            operation_count = int(
                await session.scalar(select(func.count()).select_from(SyncOperationRecord)) or 0
            )
            conflict_count = int(
                await session.scalar(select(func.count()).select_from(SyncConflictRecord)) or 0
            )
            receipt_count = int(
                await session.scalar(select(func.count()).select_from(SyncBatchReceiptRecord)) or 0
            )
            outbox_count = int(
                await session.scalar(select(func.count()).select_from(OutboxRecord)) or 0
            )
            mac_record = await session.get(SyncDeviceRecord, mac)
        assert change_count == 3
        assert operation_count == 5
        assert conflict_count == 2
        assert receipt_count == 6
        assert outbox_count == 3
        assert mac_record is not None
        assert abs(mac_record.clock_skew_seconds or 0) >= 3 * 24 * 60 * 60
        await database.dispose()

    asyncio.run(scenario())


def test_domain_merge_policies_preserve_meaning(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'merge.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        service = SyncService()
        iphone = new_uuid7()
        mac = new_uuid7()
        preset = new_uuid7()
        permission = new_uuid7()
        observation = new_uuid7()

        operations = [
            sync_operation(
                sequence=1,
                entity_type="food_preset",
                entity_id=preset,
                mutation=SyncMutationType.CREATE,
                payload={"name": "Porridge", "calories": 420, "servings": 1},
            ),
            sync_operation(
                sequence=2,
                entity_type="permission",
                entity_id=permission,
                mutation=SyncMutationType.CREATE,
                payload={"status": "authorized"},
            ),
            sync_operation(
                sequence=3,
                entity_type="observation",
                entity_id=observation,
                mutation=SyncMutationType.CREATE,
                payload={"value": 7.5},
            ),
        ]
        async with database.sessions() as session, session.begin():
            seeded = await service.push(
                session,
                request=push_request(iphone, "c_0", *operations),
                batch_idempotency_key="seed-policies",
            )
        assert seeded.next_cursor == "c_3"

        mac_operations = [
            sync_operation(
                sequence=1,
                entity_type="food_preset",
                entity_id=preset,
                mutation=SyncMutationType.UPDATE,
                payload={"calories": 430},
                base_revision=1,
            ),
            sync_operation(
                sequence=2,
                entity_type="permission",
                entity_id=permission,
                mutation=SyncMutationType.UPDATE,
                payload={"status": "denied"},
                base_revision=1,
            ),
        ]
        async with database.sessions() as session, session.begin():
            mac_result = await service.push(
                session,
                request=push_request(mac, "c_3", *mac_operations),
                batch_idempotency_key="mac-policy-edits",
            )
        assert mac_result.next_cursor == "c_5"

        stale_disjoint_food = sync_operation(
            sequence=4,
            entity_type="food_preset",
            entity_id=preset,
            mutation=SyncMutationType.UPDATE,
            payload={"servings": 2},
            base_revision=1,
        )
        stale_permission = sync_operation(
            sequence=5,
            entity_type="permission",
            entity_id=permission,
            mutation=SyncMutationType.UPDATE,
            payload={"status": "authorized"},
            base_revision=1,
        )
        append_only_update = sync_operation(
            sequence=6,
            entity_type="observation",
            entity_id=observation,
            mutation=SyncMutationType.UPDATE,
            payload={"value": 8.0},
            base_revision=1,
        )
        async with database.sessions() as session, session.begin():
            iphone_result = await service.push(
                session,
                request=push_request(
                    iphone,
                    "c_3",
                    stale_disjoint_food,
                    stale_permission,
                    append_only_update,
                ),
                batch_idempotency_key="iphone-stale-policy-edits",
            )
        assert [value.merge_result for value in iphone_result.accepted] == [
            "disjoint_field_merge",
            "most_restrictive_permission_wins",
        ]
        assert iphone_result.rejected[0].code == "APPEND_ONLY_ENTITY"
        assert iphone_result.next_cursor == "c_7"

        async with database.sessions() as session:
            food = await session.get(CanonicalEntityRecord, ("food_preset", preset))
            permission_record = await session.get(CanonicalEntityRecord, ("permission", permission))
        assert food is not None
        assert food.document == {"name": "Porridge", "calories": 430, "servings": 2}
        assert permission_record is not None
        assert permission_record.document["status"] == "denied"
        await database.dispose()

    asyncio.run(scenario())


def test_batch_idempotency_key_rejects_different_content(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'batch-key.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        service = SyncService()
        device = new_uuid7()
        first = sync_operation(
            sequence=1,
            entity_type="observation",
            entity_id=new_uuid7(),
            mutation=SyncMutationType.CREATE,
            payload={"value": 1},
        )
        async with database.sessions() as session, session.begin():
            await service.push(
                session,
                request=push_request(device, "c_0", first),
                batch_idempotency_key="same-key",
            )
        second = sync_operation(
            sequence=2,
            entity_type="observation",
            entity_id=new_uuid7(),
            mutation=SyncMutationType.CREATE,
            payload={"value": 2},
        )
        with pytest.raises(BatchIdempotencyConflictError):
            async with database.sessions() as session, session.begin():
                await service.push(
                    session,
                    request=push_request(device, "c_1", second),
                    batch_idempotency_key="same-key",
                )
        await database.dispose()

    asyncio.run(scenario())


def test_transaction_rollback_allows_lossless_retry(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'rollback.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        service = SyncService()
        device = new_uuid7()
        entity = new_uuid7()
        operation = sync_operation(
            sequence=1,
            entity_type="observation",
            entity_id=entity,
            mutation=SyncMutationType.CREATE,
            payload={"value": 42},
        )
        request = push_request(device, "c_0", operation)

        try:
            async with database.sessions() as session, session.begin():
                await service.push(
                    session,
                    request=request,
                    batch_idempotency_key="response-lost",
                )
                raise ConnectionError("synthetic response loss before commit")
        except ConnectionError:
            pass

        async with database.sessions() as session, session.begin():
            response = await service.push(
                session,
                request=request,
                batch_idempotency_key="response-lost",
            )
        assert response.next_cursor == "c_1"
        async with database.sessions() as session:
            changes = int(
                await session.scalar(select(func.count()).select_from(ServerChangeRecord)) or 0
            )
        assert changes == 1
        await database.dispose()

    asyncio.run(scenario())
