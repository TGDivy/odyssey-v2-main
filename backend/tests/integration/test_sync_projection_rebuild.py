import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path

from sqlalchemy import delete

from odyssey.db.base import Base
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.sync.contracts import (
    SyncMutationType,
    SyncOperationInput,
    SyncPushRequest,
)
from odyssey.sync.models import CanonicalEntityRecord, SyncStateRecord
from odyssey.sync.rebuild import SyncProjectionRebuilder
from odyssey.sync.service import SYNC_STATE_KEY, SyncService


def test_sync_projection_rebuild_repairs_corruption_deterministically(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'sync-rebuild.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        service = SyncService()
        rebuilder = SyncProjectionRebuilder()
        device_id = new_uuid7()
        season_id = new_uuid7()
        note_id = new_uuid7()
        now = datetime(2026, 8, 15, 12, tzinfo=UTC)
        create_season = SyncOperationInput(
            operation_id=new_uuid7(),
            device_sequence=1,
            entity_type="season",
            entity_id=season_id,
            mutation_type=SyncMutationType.CREATE,
            payload={"title": "Foundation", "end_date": "2026-11-30"},
            created_at=now,
        )
        create_note = SyncOperationInput(
            operation_id=new_uuid7(),
            device_sequence=2,
            entity_type="note",
            entity_id=note_id,
            mutation_type=SyncMutationType.CREATE,
            payload={"text": "temporary"},
            created_at=now,
        )
        async with database.sessions() as session, session.begin():
            await service.push(
                session,
                request=SyncPushRequest(
                    device_id=device_id,
                    client_schema_version=1,
                    base_cursor="c_0",
                    operations=(create_season, create_note),
                ),
                batch_idempotency_key="rebuild-create",
                server_time=now,
            )
        update_season = SyncOperationInput(
            operation_id=new_uuid7(),
            device_sequence=3,
            entity_type="season",
            entity_id=season_id,
            mutation_type=SyncMutationType.UPDATE,
            base_revision=1,
            payload={"end_date": "2026-12-15"},
            created_at=now + timedelta(minutes=1),
        )
        delete_note = SyncOperationInput(
            operation_id=new_uuid7(),
            device_sequence=4,
            entity_type="note",
            entity_id=note_id,
            mutation_type=SyncMutationType.DELETE,
            base_revision=1,
            payload={},
            created_at=now + timedelta(minutes=1),
        )
        async with database.sessions() as session, session.begin():
            await service.push(
                session,
                request=SyncPushRequest(
                    device_id=device_id,
                    client_schema_version=1,
                    base_cursor="c_2",
                    operations=(update_season, delete_note),
                ),
                batch_idempotency_key="rebuild-update-delete",
                server_time=now + timedelta(minutes=1),
            )

        async with database.sessions() as session:
            before = await rebuilder.verify(session)
        assert before.healthy is True

        async with database.sessions() as session, session.begin():
            await session.execute(delete(CanonicalEntityRecord))
            state = await session.get(SyncStateRecord, SYNC_STATE_KEY)
            assert state is not None
            state.last_change_id = 99
        async with database.sessions() as session:
            corrupted = await rebuilder.verify(session)
        assert corrupted.healthy is False
        assert corrupted.actual_entity_count == 0
        assert corrupted.actual_cursor == 99

        async with database.sessions() as session, session.begin():
            first_rebuild = await rebuilder.rebuild(
                session,
                rebuilt_at=now + timedelta(days=1),
            )
            first_integrity = await rebuilder.verify(session)
        async with database.sessions() as session, session.begin():
            second_rebuild = await rebuilder.rebuild(
                session,
                rebuilt_at=now + timedelta(days=2),
            )
            second_integrity = await rebuilder.verify(session)
            season = await session.get(CanonicalEntityRecord, ("season", season_id))
            note = await session.get(CanonicalEntityRecord, ("note", note_id))

        assert first_rebuild.operation_count == 4
        assert first_rebuild.change_count == 4
        assert first_rebuild.entity_count == 2
        assert first_rebuild.last_cursor == 4
        assert first_rebuild.checksum == second_rebuild.checksum
        assert first_integrity.healthy is True
        assert second_integrity.healthy is True
        assert season is not None
        assert season.document == {"title": "Foundation", "end_date": "2026-12-15"}
        assert season.field_versions == {"title": 1, "end_date": 2}
        assert note is not None
        assert note.tombstoned is True
        assert note.deletion_epoch == 4
        await database.dispose()

    asyncio.run(scenario())
