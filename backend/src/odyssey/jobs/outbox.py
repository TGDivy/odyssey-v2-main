"""Leased, retryable delivery for the transactional outbox."""

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from typing import Any
from uuid import UUID

import structlog
from opentelemetry.trace import SpanKind
from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.db.models import OutboxRecord
from odyssey.db.session import Database
from odyssey.telemetry.runtime import TelemetryRuntime


class OutboxStatus(StrEnum):
    PENDING = "pending"
    PROCESSING = "processing"
    RETRY = "retry"
    COMPLETED = "completed"
    DEAD_LETTER = "dead_letter"


class UnknownOutboxTopicError(RuntimeError):
    pass


class OutboxLeaseLostError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class OutboxJob:
    id: UUID
    topic: str
    aggregate_id: UUID
    payload: dict[str, Any]
    idempotency_key: str
    attempt: int
    created_at: datetime


@dataclass(frozen=True, slots=True)
class OutboxBatchResult:
    claimed: int
    completed: int
    retried: int
    dead_lettered: int
    queue: "OutboxQueueSnapshot"


@dataclass(frozen=True, slots=True)
class OutboxQueueSnapshot:
    pending: int
    processing: int
    retry: int
    dead_letter: int
    oldest_age_seconds: float

    def metric_depths(self) -> dict[str, int]:
        return {
            "pending": self.pending,
            "processing": self.processing,
            "retry": self.retry,
            "dead_letter": self.dead_letter,
        }


JobHandler = Callable[[OutboxJob], Awaitable[None]]


class OutboxDispatcher:
    def __init__(self, handlers: dict[str, JobHandler] | None = None) -> None:
        self.handlers = dict(handlers or {})

    def register(self, topic: str, handler: JobHandler) -> None:
        self.handlers[topic] = handler

    async def dispatch(self, job: OutboxJob) -> None:
        handler = self.handlers.get(job.topic)
        if handler is None:
            raise UnknownOutboxTopicError(f"no outbox handler is registered for {job.topic}")
        await handler(job)


class OutboxService:
    tracked_statuses = (
        OutboxStatus.PENDING,
        OutboxStatus.PROCESSING,
        OutboxStatus.RETRY,
        OutboxStatus.DEAD_LETTER,
    )

    async def claim(
        self,
        session: AsyncSession,
        *,
        now: datetime,
        limit: int,
        lease_seconds: int,
    ) -> tuple[OutboxJob, ...]:
        if limit < 1:
            raise ValueError("outbox claim limit must be positive")
        if lease_seconds < 1:
            raise ValueError("outbox lease must be positive")
        claimable = or_(
            and_(
                OutboxRecord.status.in_((OutboxStatus.PENDING, OutboxStatus.RETRY)),
                OutboxRecord.available_at <= now,
            ),
            and_(
                OutboxRecord.status == OutboxStatus.PROCESSING,
                OutboxRecord.lease_expires_at.is_not(None),
                OutboxRecord.lease_expires_at <= now,
            ),
        )
        records = tuple(
            (
                await session.scalars(
                    select(OutboxRecord)
                    .where(claimable)
                    .order_by(OutboxRecord.available_at, OutboxRecord.created_at, OutboxRecord.id)
                    .limit(limit)
                    .with_for_update(skip_locked=True)
                )
            ).all()
        )
        lease_expires_at = now + timedelta(seconds=lease_seconds)
        jobs: list[OutboxJob] = []
        for record in records:
            record.status = OutboxStatus.PROCESSING
            record.attempts += 1
            record.lease_expires_at = lease_expires_at
            record.last_error_code = None
            jobs.append(
                OutboxJob(
                    id=record.id,
                    topic=record.topic,
                    aggregate_id=record.aggregate_id,
                    payload=dict(record.payload),
                    idempotency_key=record.idempotency_key,
                    attempt=record.attempts,
                    created_at=record.created_at,
                )
            )
        await session.flush()
        return tuple(jobs)

    async def complete(
        self,
        session: AsyncSession,
        *,
        job: OutboxJob,
        completed_at: datetime,
    ) -> None:
        record = await self.lock_job(session, job)
        record.status = OutboxStatus.COMPLETED
        record.lease_expires_at = None
        record.last_error_code = None
        record.completed_at = completed_at

    async def fail(
        self,
        session: AsyncSession,
        *,
        job: OutboxJob,
        failed_at: datetime,
        error_code: str,
        max_attempts: int,
        base_retry_seconds: int,
        maximum_retry_seconds: int,
    ) -> OutboxStatus:
        if max_attempts < 1:
            raise ValueError("maximum outbox attempts must be positive")
        if base_retry_seconds < 1 or maximum_retry_seconds < base_retry_seconds:
            raise ValueError("outbox retry bounds must be positive and ordered")
        record = await self.lock_job(session, job)
        record.lease_expires_at = None
        record.last_error_code = error_code[:100]
        if record.attempts >= max_attempts:
            record.status = OutboxStatus.DEAD_LETTER
            return OutboxStatus.DEAD_LETTER
        retry_seconds = min(
            base_retry_seconds * (2 ** max(record.attempts - 1, 0)),
            maximum_retry_seconds,
        )
        record.status = OutboxStatus.RETRY
        record.available_at = failed_at + timedelta(seconds=retry_seconds)
        return OutboxStatus.RETRY

    async def queue_snapshot(
        self,
        session: AsyncSession,
        *,
        now: datetime,
    ) -> OutboxQueueSnapshot:
        rows = (
            await session.execute(
                select(
                    OutboxRecord.status,
                    func.count(),
                    func.min(OutboxRecord.created_at),
                )
                .where(OutboxRecord.status.in_(self.tracked_statuses))
                .group_by(OutboxRecord.status)
            )
        ).all()
        depths = {status.value: 0 for status in self.tracked_statuses}
        oldest_actionable_at: datetime | None = None
        for status, count, oldest_at in rows:
            depths[str(status)] = int(count)
            if status in {
                OutboxStatus.PENDING,
                OutboxStatus.PROCESSING,
                OutboxStatus.RETRY,
            } and (oldest_actionable_at is None or oldest_at < oldest_actionable_at):
                oldest_actionable_at = oldest_at
        if oldest_actionable_at is not None and oldest_actionable_at.tzinfo is None:
            oldest_actionable_at = oldest_actionable_at.replace(tzinfo=UTC)
        oldest_age_seconds = (
            max((now - oldest_actionable_at).total_seconds(), 0.0)
            if oldest_actionable_at is not None
            else 0.0
        )
        return OutboxQueueSnapshot(
            pending=depths[OutboxStatus.PENDING],
            processing=depths[OutboxStatus.PROCESSING],
            retry=depths[OutboxStatus.RETRY],
            dead_letter=depths[OutboxStatus.DEAD_LETTER],
            oldest_age_seconds=oldest_age_seconds,
        )

    @staticmethod
    async def lock_job(session: AsyncSession, job: OutboxJob) -> OutboxRecord:
        record = await session.scalar(
            select(OutboxRecord).where(OutboxRecord.id == job.id).with_for_update()
        )
        if (
            record is None
            or record.status != OutboxStatus.PROCESSING
            or record.attempts != job.attempt
        ):
            raise OutboxLeaseLostError(f"outbox lease was lost for {job.id}")
        return record


async def process_outbox_batch(
    database: Database,
    dispatcher: OutboxDispatcher,
    *,
    now: datetime,
    batch_size: int = 50,
    lease_seconds: int = 60,
    max_attempts: int = 8,
    base_retry_seconds: int = 5,
    maximum_retry_seconds: int = 900,
    telemetry: TelemetryRuntime | None = None,
) -> OutboxBatchResult:
    service = OutboxService()
    async with database.sessions() as session, session.begin():
        jobs = await service.claim(
            session,
            now=now,
            limit=batch_size,
            lease_seconds=lease_seconds,
        )

    completed = 0
    retried = 0
    dead_lettered = 0
    logger = structlog.get_logger(__name__)

    async def deliver(job: OutboxJob) -> tuple[OutboxStatus, str | None]:
        try:
            await dispatcher.dispatch(job)
        except Exception as error:
            error_code = type(error).__name__
            async with database.sessions() as session, session.begin():
                status = await service.fail(
                    session,
                    job=job,
                    failed_at=now,
                    error_code=error_code,
                    max_attempts=max_attempts,
                    base_retry_seconds=base_retry_seconds,
                    maximum_retry_seconds=maximum_retry_seconds,
                )
            logger.warning(
                "outbox_delivery_failed",
                outbox_id=str(job.id),
                topic=job.topic,
                attempt=job.attempt,
                error_code=error_code,
                terminal=status is OutboxStatus.DEAD_LETTER,
            )
            return status, error_code
        async with database.sessions() as session, session.begin():
            await service.complete(session, job=job, completed_at=now)
        return OutboxStatus.COMPLETED, None

    async def deliver_jobs() -> None:
        nonlocal completed, retried, dead_lettered
        for job in jobs:
            if telemetry is None:
                status, _error_code = await deliver(job)
            else:
                with telemetry.span(
                    "outbox deliver",
                    kind=SpanKind.CONSUMER,
                    attributes={
                        "messaging.destination.name": job.topic,
                        "messaging.message.id": str(job.id),
                        "messaging.operation.type": "process",
                        "odyssey.outbox.attempt": job.attempt,
                    },
                ) as span:
                    status, error_code = await deliver(job)
                    span.set_attribute("odyssey.outbox.outcome", status.value)
                    if error_code is not None:
                        telemetry.mark_error(span, error_code)
            if status is OutboxStatus.COMPLETED:
                completed += 1
            elif status is OutboxStatus.DEAD_LETTER:
                dead_lettered += 1
            else:
                retried += 1

    if telemetry is not None and jobs:
        with telemetry.span(
            "outbox process batch",
            kind=SpanKind.CONSUMER,
            attributes={"odyssey.outbox.claimed": len(jobs)},
        ) as batch_span:
            try:
                await deliver_jobs()
            except Exception as error:
                telemetry.mark_error(batch_span, type(error).__name__)
                raise
            batch_span.set_attribute("odyssey.outbox.completed", completed)
            batch_span.set_attribute("odyssey.outbox.retried", retried)
            batch_span.set_attribute("odyssey.outbox.dead_lettered", dead_lettered)
    else:
        await deliver_jobs()

    async with database.sessions() as session:
        queue = await service.queue_snapshot(session, now=now)
    return OutboxBatchResult(
        claimed=len(jobs),
        completed=completed,
        retried=retried,
        dead_lettered=dead_lettered,
        queue=queue,
    )


async def acknowledge_internal_event(job: OutboxJob) -> None:
    await asyncio.sleep(0)
    structlog.get_logger(__name__).info(
        "outbox_event_acknowledged",
        outbox_id=str(job.id),
        topic=job.topic,
        aggregate_id=str(job.aggregate_id),
        attempt=job.attempt,
    )


def internal_event_dispatcher() -> OutboxDispatcher:
    handler_topics = (
        "domain-event",
        "imported-domain-event",
        "sync-canonical-change",
        "attachment-committed",
    )
    return OutboxDispatcher({topic: acknowledge_internal_event for topic in handler_topics})
