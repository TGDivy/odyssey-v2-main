"""Worker process entry point."""

import asyncio
import signal
from contextlib import suppress
from datetime import UTC, datetime

import structlog

from odyssey.config import Settings, get_settings
from odyssey.db.session import Database
from odyssey.jobs.outbox import internal_event_dispatcher, process_outbox_batch
from odyssey.logging import configure_logging


async def run(
    *,
    once: bool = False,
    settings: Settings | None = None,
    database: Database | None = None,
) -> None:
    active_settings = settings or get_settings()
    active_database = database or Database(active_settings.database_url)
    owns_database = database is None
    configure_logging(active_settings.log_level)
    logger = structlog.get_logger(__name__)
    dispatcher = internal_event_dispatcher()
    logger.info(
        "worker_ready",
        environment=active_settings.env.value,
        queue_mode="transactional_outbox",
        accepted_job_types=sorted(dispatcher.handlers),
    )
    stop_event = asyncio.Event()
    event_loop = asyncio.get_running_loop()
    for shutdown_signal in (signal.SIGINT, signal.SIGTERM):
        with suppress(NotImplementedError):
            event_loop.add_signal_handler(shutdown_signal, stop_event.set)
    try:
        while not stop_event.is_set():
            result = await process_outbox_batch(
                active_database,
                dispatcher,
                now=datetime.now(UTC),
                batch_size=active_settings.worker_batch_size,
                lease_seconds=active_settings.worker_lease_seconds,
                max_attempts=active_settings.worker_max_attempts,
            )
            if once:
                return
            if result.claimed == 0:
                with suppress(TimeoutError):
                    await asyncio.wait_for(
                        stop_event.wait(),
                        timeout=active_settings.worker_poll_seconds,
                    )
    finally:
        if owns_database:
            await active_database.dispose()
        logger.info("worker_stopped")


def main() -> None:
    asyncio.run(run())
