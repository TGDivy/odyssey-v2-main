"""Worker process entry point."""

import asyncio
import signal
from contextlib import suppress
from datetime import UTC, datetime
from time import perf_counter

import structlog

from odyssey import __version__
from odyssey.attachments.storage import AttachmentStore
from odyssey.attachments.storage_factory import create_attachment_store
from odyssey.config import Settings, get_settings
from odyssey.db.session import Database
from odyssey.exports.crypto import ExportKeyManager
from odyssey.exports.service import OWNER_EXPORT_TOPIC, OwnerExportProcessor
from odyssey.jobs.outbox import internal_event_dispatcher, process_outbox_batch
from odyssey.logging import configure_logging
from odyssey.telemetry.alerts import AlertSeverity, evaluate_outbox_alerts
from odyssey.telemetry.runtime import TelemetryRuntime, create_telemetry_runtime


async def run(
    *,
    once: bool = False,
    settings: Settings | None = None,
    database: Database | None = None,
    attachment_store: AttachmentStore | None = None,
    telemetry: TelemetryRuntime | None = None,
) -> None:
    active_settings = settings or get_settings()
    active_database = database or Database(active_settings.database_url)
    owns_database = database is None
    active_telemetry = telemetry or create_telemetry_runtime(
        active_settings,
        service_name="odyssey-worker",
        service_version=__version__,
    )
    configure_logging(active_settings.log_level)
    logger = structlog.get_logger(__name__)
    dispatcher = internal_event_dispatcher()
    if active_settings.owner_export_enabled:
        active_attachment_store = attachment_store or create_attachment_store(active_settings)
        await active_attachment_store.validate_configuration()
        export_processor = OwnerExportProcessor(
            database=active_database,
            attachment_store=active_attachment_store,
            key_manager=ExportKeyManager(active_settings.export_wrapping_key.get_secret_value()),
            maximum_bytes=active_settings.maximum_export_bytes,
            maximum_attempts=active_settings.worker_max_attempts,
        )
        dispatcher.register(OWNER_EXPORT_TOPIC, export_processor.handle)
    logger.info(
        "worker_ready",
        environment=active_settings.env.value,
        queue_mode="transactional_outbox",
        accepted_job_types=sorted(dispatcher.handlers),
        telemetry_exporter=active_telemetry.exporter,
    )
    active_alert_codes: set[str] = set()
    stop_event = asyncio.Event()
    event_loop = asyncio.get_running_loop()
    for shutdown_signal in (signal.SIGINT, signal.SIGTERM):
        with suppress(NotImplementedError):
            event_loop.add_signal_handler(shutdown_signal, stop_event.set)
    try:
        while not stop_event.is_set():
            started_at = perf_counter()
            result = await process_outbox_batch(
                active_database,
                dispatcher,
                now=datetime.now(UTC),
                batch_size=active_settings.worker_batch_size,
                lease_seconds=active_settings.worker_lease_seconds,
                max_attempts=active_settings.worker_max_attempts,
                telemetry=active_telemetry,
            )
            duration_seconds = perf_counter() - started_at
            active_telemetry.record_outbox_batch(
                completed=result.completed,
                retried=result.retried,
                dead_lettered=result.dead_lettered,
                duration_seconds=duration_seconds,
                queue_depths=result.queue.metric_depths(),
                oldest_age_seconds=result.queue.oldest_age_seconds,
            )
            if result.claimed:
                logger.info(
                    "outbox_batch_completed",
                    claimed=result.claimed,
                    completed=result.completed,
                    retried=result.retried,
                    dead_lettered=result.dead_lettered,
                    duration_ms=round(duration_seconds * 1000, 2),
                )
            alerts = evaluate_outbox_alerts(
                dead_letter_depth=result.queue.dead_letter,
                oldest_age_seconds=result.queue.oldest_age_seconds,
                backlog_alert_seconds=active_settings.worker_backlog_alert_seconds,
            )
            current_alert_codes = {alert.code for alert in alerts}
            for alert in alerts:
                if alert.code in active_alert_codes:
                    continue
                log_method = (
                    logger.error if alert.severity is AlertSeverity.CRITICAL else logger.warning
                )
                log_method(
                    "operator_alert_raised",
                    alert_code=alert.code,
                    severity=alert.severity.value,
                    observed_value=round(alert.observed_value, 3),
                    threshold=alert.threshold,
                )
            for alert_code in active_alert_codes - current_alert_codes:
                logger.info("operator_alert_cleared", alert_code=alert_code)
            active_alert_codes = current_alert_codes
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
        active_telemetry.shutdown()


def main() -> None:
    asyncio.run(run())


def main_once() -> None:
    asyncio.run(run(once=True))
