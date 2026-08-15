from collections.abc import Iterator
from contextlib import contextmanager

import pytest
from fastapi.testclient import TestClient
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import InMemoryMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from pydantic import ValidationError

from odyssey.config import Environment, Settings, TelemetryExporter
from odyssey.main import create_app
from odyssey.telemetry.runtime import TelemetryRuntime


@contextmanager
def telemetry_fixture() -> Iterator[
    tuple[TelemetryRuntime, InMemorySpanExporter, InMemoryMetricReader]
]:
    resource = Resource.create({"service.name": "odyssey-api-test"})
    span_exporter = InMemorySpanExporter()
    tracer_provider = TracerProvider(resource=resource, shutdown_on_exit=False)
    tracer_provider.add_span_processor(SimpleSpanProcessor(span_exporter))
    metric_reader = InMemoryMetricReader()
    meter_provider = MeterProvider(
        metric_readers=[metric_reader],
        resource=resource,
        shutdown_on_exit=False,
    )
    runtime = TelemetryRuntime(
        tracer_provider=tracer_provider,
        meter_provider=meter_provider,
        service_name="odyssey-api-test",
        exporter="memory",
        enabled=True,
    )
    try:
        yield runtime, span_exporter, metric_reader
    finally:
        runtime.shutdown()


def test_http_trace_propagation_and_metrics_are_payload_safe() -> None:
    trace_id = "11111111111111111111111111111111"
    parent_span_id = "2222222222222222"
    with telemetry_fixture() as (telemetry, span_exporter, metric_reader):
        app = create_app(Settings(env=Environment.TEST), telemetry=telemetry)
        with TestClient(app) as client:
            response = client.get(
                "/health/live?private=must-not-appear",
                headers={"traceparent": f"00-{trace_id}-{parent_span_id}-01"},
            )
            metrics = metric_reader.get_metrics_data()

        spans = span_exporter.get_finished_spans()

    assert response.status_code == 200
    assert response.headers["X-Trace-ID"] == trace_id
    assert response.headers["traceparent"].split("-")[1] == trace_id
    assert len(spans) == 1
    span = spans[0]
    assert span.name == "GET /health/live"
    assert span.parent is not None
    assert f"{span.parent.span_id:016x}" == parent_span_id
    assert span.attributes is not None
    assert span.attributes["http.route"] == "/health/live"
    assert "must-not-appear" not in repr(span.attributes)
    assert metrics is not None
    metric_names = {
        metric.name
        for resource_metrics in metrics.resource_metrics
        for scope_metrics in resource_metrics.scope_metrics
        for metric in scope_metrics.metrics
    }
    assert {
        "odyssey.http.server.requests",
        "odyssey.http.server.duration",
    }.issubset(metric_names)


def test_failed_request_trace_does_not_capture_exception_message() -> None:
    with telemetry_fixture() as (telemetry, span_exporter, _metric_reader):
        app = create_app(Settings(env=Environment.TEST), telemetry=telemetry)

        @app.get("/test/private-failure")
        async def private_failure() -> None:
            raise RuntimeError("private provider response")

        with TestClient(app, raise_server_exceptions=False) as client:
            response = client.get("/test/private-failure")

        spans = span_exporter.get_finished_spans()

    assert response.status_code == 500
    assert len(spans) == 1
    assert spans[0].status.is_ok is False
    assert spans[0].events == ()
    assert "private provider response" not in repr(spans[0])


def test_otlp_settings_validate_endpoint_and_keep_headers_secret() -> None:
    with pytest.raises(ValidationError, match="OTLP HTTP telemetry"):
        Settings(
            env=Environment.TEST,
            telemetry_exporter=TelemetryExporter.OTLP_HTTP,
            telemetry_otlp_endpoint="not-a-url",
        )

    settings = Settings(
        env=Environment.TEST,
        telemetry_exporter=TelemetryExporter.OTLP_HTTP,
        telemetry_otlp_endpoint="https://collector.example",
        telemetry_otlp_headers="authorization=Bearer%20synthetic-secret",
    )

    assert settings.telemetry_headers() == {"authorization": "Bearer synthetic-secret"}
    assert "synthetic-secret" not in repr(settings.safe_diagnostics())
