"""Vendor-neutral, payload-safe OpenTelemetry runtime instrumentation."""

from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from typing import Any

from opentelemetry import context as otel_context
from opentelemetry.context import Context
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.metrics import Meter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import (
    ConsoleMetricExporter,
    PeriodicExportingMetricReader,
)
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import (
    BatchSpanProcessor,
    ConsoleSpanExporter,
    SimpleSpanProcessor,
)
from opentelemetry.sdk.trace.sampling import ALWAYS_OFF, ParentBased, TraceIdRatioBased
from opentelemetry.trace import Span, SpanKind, Status, StatusCode, Tracer
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.trace.span import format_span_id, format_trace_id

from odyssey.config import Settings, TelemetryExporter

INSTRUMENTATION_NAME = "odyssey.telemetry"
INSTRUMENTATION_VERSION = "1"


class TelemetryRuntime:
    """Owns isolated SDK providers so tests and processes do not mutate globals."""

    def __init__(
        self,
        *,
        tracer_provider: TracerProvider,
        meter_provider: MeterProvider,
        service_name: str,
        exporter: str,
        enabled: bool,
    ) -> None:
        self.tracer_provider = tracer_provider
        self.meter_provider = meter_provider
        self.service_name = service_name
        self.exporter = exporter
        self.enabled = enabled
        self.tracer: Tracer = tracer_provider.get_tracer(
            INSTRUMENTATION_NAME, INSTRUMENTATION_VERSION
        )
        self.meter: Meter = meter_provider.get_meter(INSTRUMENTATION_NAME, INSTRUMENTATION_VERSION)
        self.propagator = TraceContextTextMapPropagator()
        self._shutdown = False
        self._http_requests = self.meter.create_counter(
            "odyssey.http.server.requests",
            unit="{request}",
            description="Completed HTTP server requests.",
        )
        self._http_errors = self.meter.create_counter(
            "odyssey.http.server.errors",
            unit="{error}",
            description="HTTP server responses with error status.",
        )
        self._http_duration = self.meter.create_histogram(
            "odyssey.http.server.duration",
            unit="s",
            description="HTTP server request duration.",
        )
        self._outbox_jobs = self.meter.create_counter(
            "odyssey.outbox.jobs",
            unit="{job}",
            description="Outbox delivery outcomes.",
        )
        self._outbox_batch_duration = self.meter.create_histogram(
            "odyssey.outbox.batch.duration",
            unit="s",
            description="Transactional outbox batch duration.",
        )
        self._outbox_queue_depth = self.meter.create_gauge(
            "odyssey.outbox.queue.depth",
            unit="{job}",
            description="Current outbox records by actionable state.",
        )
        self._outbox_oldest_age = self.meter.create_gauge(
            "odyssey.outbox.queue.oldest_age",
            unit="s",
            description="Age of the oldest actionable outbox record.",
        )

    @contextmanager
    def span(
        self,
        name: str,
        *,
        context: Context | None = None,
        kind: SpanKind = SpanKind.INTERNAL,
        attributes: Mapping[str, Any] | None = None,
    ) -> Iterator[Span]:
        with self.tracer.start_as_current_span(
            name,
            context=context,
            kind=kind,
            attributes=attributes,
            record_exception=False,
            set_status_on_exception=False,
        ) as span:
            yield span

    def extract_context(self, headers: Mapping[str, str]) -> Context:
        return self.propagator.extract(carrier=headers)

    def inject_context(self) -> dict[str, str]:
        carrier: dict[str, str] = {}
        self.propagator.inject(carrier=carrier, context=otel_context.get_current())
        return carrier

    @staticmethod
    def span_ids(span: Span) -> tuple[str, str]:
        span_context = span.get_span_context()
        return format_trace_id(span_context.trace_id), format_span_id(span_context.span_id)

    @staticmethod
    def mark_error(span: Span, error_type: str) -> None:
        span.set_attribute("error.type", error_type)
        span.set_status(Status(StatusCode.ERROR))

    def record_http_request(
        self,
        *,
        method: str,
        route: str,
        status_code: int,
        duration_seconds: float,
    ) -> None:
        attributes: dict[str, str | int] = {
            "http.request.method": method,
            "http.route": route,
            "http.response.status_code": status_code,
        }
        self._http_requests.add(1, attributes)
        self._http_duration.record(duration_seconds, attributes)
        if status_code >= 400:
            self._http_errors.add(1, attributes)

    def record_outbox_batch(
        self,
        *,
        completed: int,
        retried: int,
        dead_lettered: int,
        duration_seconds: float,
        queue_depths: Mapping[str, int],
        oldest_age_seconds: float,
    ) -> None:
        for outcome, count in (
            ("completed", completed),
            ("retry", retried),
            ("dead_letter", dead_lettered),
        ):
            if count:
                self._outbox_jobs.add(count, {"outcome": outcome})
        self._outbox_batch_duration.record(duration_seconds)
        for state in ("pending", "processing", "retry", "dead_letter"):
            self._outbox_queue_depth.set(queue_depths.get(state, 0), {"state": state})
        self._outbox_oldest_age.set(oldest_age_seconds)

    def safe_diagnostics(self) -> dict[str, str | bool]:
        return {
            "service_name": self.service_name,
            "enabled": self.enabled,
            "exporter": self.exporter,
            "traces": True,
            "metrics": True,
            "structured_logs": True,
            "propagation": "w3c_trace_context",
            "payload_capture": False,
        }

    def force_flush(self, timeout_millis: int = 10_000) -> bool:
        traces_flushed = self.tracer_provider.force_flush(timeout_millis)
        metrics_flushed = self.meter_provider.force_flush(timeout_millis)
        return traces_flushed and metrics_flushed

    def shutdown(self) -> None:
        if self._shutdown:
            return
        self._shutdown = True
        self.tracer_provider.shutdown()
        self.meter_provider.shutdown()


def create_telemetry_runtime(
    settings: Settings,
    *,
    service_name: str,
    service_version: str,
) -> TelemetryRuntime:
    resource = Resource.create(
        {
            "service.name": service_name,
            "service.version": service_version,
            "deployment.environment.name": settings.env.value,
            "vcs.ref.head.revision": settings.commit_sha,
        }
    )
    enabled = settings.telemetry_exporter is not TelemetryExporter.NONE
    sampler = (
        ParentBased(TraceIdRatioBased(settings.telemetry_sample_ratio)) if enabled else ALWAYS_OFF
    )
    tracer_provider = TracerProvider(
        sampler=sampler,
        resource=resource,
        shutdown_on_exit=False,
    )
    metric_readers: list[PeriodicExportingMetricReader] = []
    if settings.telemetry_exporter is TelemetryExporter.CONSOLE:
        tracer_provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
        metric_readers.append(
            PeriodicExportingMetricReader(
                ConsoleMetricExporter(),
                export_interval_millis=settings.telemetry_export_interval_seconds * 1000,
                export_timeout_millis=settings.telemetry_export_timeout_seconds * 1000,
            )
        )
    elif settings.telemetry_exporter is TelemetryExporter.OTLP_HTTP:
        endpoint = settings.telemetry_otlp_endpoint.rstrip("/")
        headers = settings.telemetry_headers()
        tracer_provider.add_span_processor(
            BatchSpanProcessor(
                OTLPSpanExporter(
                    endpoint=f"{endpoint}/v1/traces",
                    headers=headers,
                    timeout=settings.telemetry_export_timeout_seconds,
                )
            )
        )
        metric_readers.append(
            PeriodicExportingMetricReader(
                OTLPMetricExporter(
                    endpoint=f"{endpoint}/v1/metrics",
                    headers=headers,
                    timeout=settings.telemetry_export_timeout_seconds,
                ),
                export_interval_millis=settings.telemetry_export_interval_seconds * 1000,
                export_timeout_millis=settings.telemetry_export_timeout_seconds * 1000,
            )
        )
    meter_provider = MeterProvider(
        metric_readers=metric_readers,
        resource=resource,
        shutdown_on_exit=False,
    )
    return TelemetryRuntime(
        tracer_provider=tracer_provider,
        meter_provider=meter_provider,
        service_name=service_name,
        exporter=settings.telemetry_exporter.value,
        enabled=enabled,
    )
