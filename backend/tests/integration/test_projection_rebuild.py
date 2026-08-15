import asyncio
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4

from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.db.base import Base
from odyssey.db.projections import CurrentEntityProjectionRebuilder
from odyssey.db.repositories import LedgerRepository, SourceRecordWrite
from odyssey.db.session import Database
from odyssey.domain.common import ActorRef, ActorType, Provenance, new_uuid7
from odyssey.domain.events import DomainEvent


async def append_capture(session: AsyncSession, *, content_hash: str) -> None:
    occurred_at = datetime.now(UTC)
    capture_id = new_uuid7()
    provenance = Provenance(
        id=new_uuid7(),
        source_kind="test",
        source_id=str(capture_id),
        captured_at=occurred_at,
        actor=ActorRef(actor_type=ActorType.USER, actor_id="owner"),
    )
    source = SourceRecordWrite(
        id=capture_id,
        source_kind="capture",
        occurred_at=occurred_at,
        recorded_at=occurred_at,
        temporal_precision="exact",
        content_hash=content_hash,
        sensitivity="private",
        payload={"kind": "text", "content": "synthetic"},
        provenance_id=provenance.id,
    )
    event = DomainEvent(
        event_id=new_uuid7(),
        event_type="capture.recorded.v1",
        event_schema_version=1,
        aggregate_type="capture",
        aggregate_id=capture_id,
        occurred_at=occurred_at,
        recorded_at=occurred_at,
        actor=provenance.actor,
        correlation_id=uuid4(),
        payload={"capture_id": str(capture_id)},
        provenance=provenance,
    )
    await LedgerRepository().append_source_event(session, source=source, event=event)


def test_projection_rebuild_is_deterministic_and_complete(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'projection.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with database.sessions() as session, session.begin():
            await append_capture(session, content_hash="a" * 64)
            await append_capture(session, content_hash="b" * 64)

        rebuilder = CurrentEntityProjectionRebuilder()
        async with database.sessions() as session, session.begin():
            first = await rebuilder.rebuild(session, rebuilt_at=datetime(2026, 8, 15, tzinfo=UTC))
            first_integrity = await rebuilder.verify(session)
        async with database.sessions() as session, session.begin():
            second = await rebuilder.rebuild(session, rebuilt_at=datetime(2026, 8, 16, tzinfo=UTC))
            second_integrity = await rebuilder.verify(session)

        assert first.event_count == 2
        assert first.projection_count == 2
        assert first.checksum == second.checksum
        assert first_integrity.healthy is True
        assert second_integrity.healthy is True
        await database.dispose()

    asyncio.run(scenario())
