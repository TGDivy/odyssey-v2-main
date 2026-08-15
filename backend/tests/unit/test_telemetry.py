from collections.abc import Iterator
from contextlib import contextmanager

import pytest
from fastapi.testclient import TestClient
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import (
    InMemoryMetricReader,
    MetricExporter,
    MetricExportResult,
)
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from pydantic import ValidationError

from odyssey.config import AuthMode, Environment, Settings, TelemetryExporter
from odyssey.main import create_app
from odyssey.telemetry import runtime as runtime_module
from odyssey.telemetry.alerts import AlertSeverity, evaluate_outbox_alerts
from odyssey.telemetry.runtime import TelemetryRuntime, create_telemetry_runtime


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


def test_auth_denial_metric_has_only_bounded_route_and_status() -> None:
    with telemetry_fixture() as (telemetry, _span_exporter, metric_reader):
        app = create_app(
            Settings(env=Environment.TEST, auth_mode=AuthMode.SIGN_IN_WITH_APPLE),
            telemetry=telemetry,
        )
        with TestClient(app) as client:
            response = client.get("/v1/admin/diagnostics")
            metrics = metric_reader.get_metrics_data()

    assert response.status_code == 401
    assert metrics is not None
    denial_points = [
        point
        for resource_metrics in metrics.resource_metrics
        for scope_metrics in resource_metrics.scope_metrics
        for metric in scope_metrics.metrics
        if metric.name == "odyssey.auth.denials"
        for point in metric.data.data_points
    ]
    assert len(denial_points) == 1
    assert denial_points[0].attributes == {
        "http.route": "/v1/admin/diagnostics",
        "http.response.status_code": 401,
    }


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


def test_outbox_operator_alert_policy_is_threshold_based() -> None:
    alerts = evaluate_outbox_alerts(
        dead_letter_depth=2,
        oldest_age_seconds=10_800,
        backlog_alert_seconds=10_800,
    )

    assert [(alert.code, alert.severity) for alert in alerts] == [
        ("OUTBOX_DEAD_LETTERS_PRESENT", AlertSeverity.CRITICAL),
        ("OUTBOX_BACKLOG_AGE_EXCEEDED", AlertSeverity.WARNING),
    ]
    assert (
        evaluate_outbox_alerts(
            dead_letter_depth=0,
            oldest_age_seconds=10_799,
            backlog_alert_seconds=10_800,
        )
        == ()
    )


def test_otlp_runtime_configures_signal_endpoints_without_network(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    exporter_arguments: dict[str, dict[str, object]] = {}

    class MemoryMetricExporter(MetricExporter):
        def export(
            self,
            _metrics_data: object,
            timeout_millis: float = 10_000,
            **_kwargs: object,
        ) -> MetricExportResult:
            return MetricExportResult.SUCCESS

        def force_flush(self, timeout_millis: float = 10_000) -> bool:
            return True

        def shutdown(self, timeout_millis: float = 30_000, **_kwargs: object) -> None:
            return None

    def span_exporter(**kwargs: object) -> InMemorySpanExporter:
        exporter_arguments["traces"] = kwargs
        return InMemorySpanExporter()

    def metric_exporter(**kwargs: object) -> MemoryMetricExporter:
        exporter_arguments["metrics"] = kwargs
        return MemoryMetricExporter()

    monkeypatch.setattr(runtime_module, "OTLPSpanExporter", span_exporter)
    monkeypatch.setattr(runtime_module, "OTLPMetricExporter", metric_exporter)
    settings = Settings(
        env=Environment.TEST,
        telemetry_exporter=TelemetryExporter.OTLP_HTTP,
        telemetry_otlp_endpoint="https://collector.example/base/",
        telemetry_otlp_headers="authorization=Bearer%20synthetic-secret",
        telemetry_export_timeout_seconds=7,
    )

    telemetry = create_telemetry_runtime(
        settings,
        service_name="odyssey-api-test",
        service_version="test",
    )
    telemetry.shutdown()

    assert exporter_arguments == {
        "traces": {
            "endpoint": "https://collector.example/base/v1/traces",
            "headers": {"authorization": "Bearer synthetic-secret"},
            "timeout": 7,
        },
        "metrics": {
            "endpoint": "https://collector.example/base/v1/metrics",
            "headers": {"authorization": "Bearer synthetic-secret"},
            "timeout": 7,
        },
    }
