"""Worker process entry point."""

import structlog

from odyssey.config import get_settings
from odyssey.logging import configure_logging


def main() -> None:
    settings = get_settings()
    configure_logging(settings.log_level)
    structlog.get_logger(__name__).info(
        "worker_ready",
        environment=settings.env.value,
        queue_mode="in_process",
        accepted_job_types=[],
    )
