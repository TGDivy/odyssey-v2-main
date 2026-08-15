"""Worker process entry point."""

import asyncio
import signal
from contextlib import suppress

import structlog

from odyssey.config import get_settings
from odyssey.logging import configure_logging


async def run(*, once: bool = False) -> None:
    settings = get_settings()
    configure_logging(settings.log_level)
    logger = structlog.get_logger(__name__)
    logger.info(
        "worker_ready",
        environment=settings.env.value,
        queue_mode="in_process",
        accepted_job_types=[],
    )
    if once:
        return
    stop_event = asyncio.Event()
    event_loop = asyncio.get_running_loop()
    for shutdown_signal in (signal.SIGINT, signal.SIGTERM):
        with suppress(NotImplementedError):
            event_loop.add_signal_handler(shutdown_signal, stop_event.set)
    try:
        await stop_event.wait()
    finally:
        logger.info("worker_stopped")


def main() -> None:
    asyncio.run(run())
