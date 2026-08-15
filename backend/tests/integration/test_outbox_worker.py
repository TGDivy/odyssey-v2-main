import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path

from sqlalchemy import select

from odyssey.db.base import Base
from odyssey.db.models import OutboxRecord
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.jobs.outbox import OutboxDispatcher, OutboxJob, OutboxStatus, process_outbox_batch


def outbox_record(*, topic: str, now: datetime) -> OutboxRecord:
    identifier = new_uuid7()
    return OutboxRecord(
        id=identifier,
        topic=topic,
        aggregate_id=new_uuid7(),
        payload={"synthetic": True},
        idempotency_key=f"synthetic:{identifier}",
        status=OutboxStatus.PENDING,
        attempts=0,
        available_at=now,
        created_at=now,
    )


def test_response_loss_retries_without_duplicate_effect(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'outbox-retry.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        now = datetime(2026, 8, 15, 12, tzinfo=UTC)
        record = outbox_record(topic="synthetic-delivery", now=now)
        async with database.sessions() as session, session.begin():
            session.add(record)

        applied_keys: set[str] = set()
        effect_count = 0

        async def response_lost_handler(job: OutboxJob) -> None:
            nonlocal effect_count
            await asyncio.sleep(0)
            if job.idempotency_key not in applied_keys:
                applied_keys.add(job.idempotency_key)
                effect_count += 1
                raise ConnectionError("synthetic response loss after effect")

        dispatcher = OutboxDispatcher({"synthetic-delivery": response_lost_handler})
        first = await process_outbox_batch(
            database,
            dispatcher,
            now=now,
            base_retry_seconds=5,
        )
        second = await process_outbox_batch(
            database,
            dispatcher,
            now=now + timedelta(seconds=5),
            base_retry_seconds=5,
        )

        assert first.retried == 1
        assert second.completed == 1
        assert effect_count == 1
        async with database.sessions() as session:
            stored = await session.get(OutboxRecord, record.id)
        assert stored is not None
        assert stored.status == OutboxStatus.COMPLETED
        assert stored.attempts == 2
        assert stored.last_error_code is None
        await database.dispose()

    asyncio.run(scenario())


def test_unknown_topic_dead_letters_and_expired_lease_is_reclaimed(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'outbox-leases.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        now = datetime(2026, 8, 15, 12, tzinfo=UTC)
        unknown = outbox_record(topic="unknown", now=now)
        expired = outbox_record(topic="known", now=now)
        expired.status = OutboxStatus.PROCESSING
        expired.attempts = 1
        expired.lease_expires_at = now - timedelta(seconds=1)
        async with database.sessions() as session, session.begin():
            session.add_all((unknown, expired))

        delivered: list[str] = []

        async def known_handler(job: OutboxJob) -> None:
            await asyncio.sleep(0)
            delivered.append(job.idempotency_key)

        dispatcher = OutboxDispatcher({"known": known_handler})
        first = await process_outbox_batch(
            database,
            dispatcher,
            now=now,
            max_attempts=2,
            base_retry_seconds=1,
        )
        second = await process_outbox_batch(
            database,
            dispatcher,
            now=now + timedelta(seconds=1),
            max_attempts=2,
            base_retry_seconds=1,
        )

        assert first.completed == 1
        assert first.retried == 1
        assert second.dead_lettered == 1
        assert delivered == [expired.idempotency_key]
        async with database.sessions() as session:
            records = {
                record.id: record for record in (await session.scalars(select(OutboxRecord))).all()
            }
        assert records[expired.id].status == OutboxStatus.COMPLETED
        assert records[expired.id].attempts == 2
        assert records[unknown.id].status == OutboxStatus.DEAD_LETTER
        assert records[unknown.id].last_error_code == "UnknownOutboxTopicError"
        await database.dispose()

    asyncio.run(scenario())
