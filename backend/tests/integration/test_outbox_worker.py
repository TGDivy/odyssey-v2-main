import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path

from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import InMemoryMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from sqlalchemy import select

from odyssey.config import Environment, Settings
from odyssey.db.base import Base
from odyssey.db.models import OutboxRecord
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.jobs.outbox import OutboxDispatcher, OutboxJob, OutboxStatus, process_outbox_batch
from odyssey.telemetry.runtime import TelemetryRuntime
from odyssey.worker import run as run_worker


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


def test_worker_exports_retry_spans_and_queue_metrics(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'outbox-telemetry.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        now = datetime.now(UTC)
        record = outbox_record(topic="synthetic-unknown", now=now - timedelta(hours=4))
        async with database.sessions() as session, session.begin():
            session.add(record)

        resource = Resource.create({"service.name": "odyssey-worker-test"})
        span_exporter = InMemorySpanExporter()
        tracer_provider = TracerProvider(resource=resource, shutdown_on_exit=False)
        tracer_provider.add_span_processor(SimpleSpanProcessor(span_exporter))
        metric_reader = InMemoryMetricReader()
        meter_provider = MeterProvider(
            metric_readers=[metric_reader],
            resource=resource,
            shutdown_on_exit=False,
        )
        telemetry = TelemetryRuntime(
            tracer_provider=tracer_provider,
            meter_provider=meter_provider,
            service_name="odyssey-worker-test",
            exporter="memory",
            enabled=True,
        )

        await run_worker(
            once=True,
            settings=Settings(env=Environment.TEST, worker_backlog_alert_seconds=60),
            database=database,
            telemetry=telemetry,
        )

        spans = {span.name: span for span in span_exporter.get_finished_spans()}
        assert set(spans) == {"outbox process batch", "outbox deliver"}
        assert spans["outbox deliver"].parent is not None
        assert (
            spans["outbox deliver"].parent.span_id == spans["outbox process batch"].context.span_id
        )
        assert spans["outbox deliver"].status.is_ok is False
        assert spans["outbox deliver"].events == ()

        metrics = metric_reader.get_metrics_data()
        assert metrics is not None
        exported_metrics = {
            metric.name: metric
            for resource_metrics in metrics.resource_metrics
            for scope_metrics in resource_metrics.scope_metrics
            for metric in scope_metrics.metrics
        }
        retry_points = [
            point
            for point in exported_metrics["odyssey.outbox.jobs"].data.data_points
            if point.attributes == {"outcome": "retry"}
        ]
        queue_points = [
            point
            for point in exported_metrics["odyssey.outbox.queue.depth"].data.data_points
            if point.attributes == {"state": "retry"}
        ]
        oldest_points = exported_metrics["odyssey.outbox.queue.oldest_age"].data.data_points
        assert retry_points[0].value == 1
        assert queue_points[0].value == 1
        assert oldest_points[0].value >= 4 * 60 * 60

        async with database.sessions() as session:
            stored = await session.get(OutboxRecord, record.id)
        assert stored is not None
        assert stored.status == OutboxStatus.RETRY
        await database.dispose()

    asyncio.run(scenario())
