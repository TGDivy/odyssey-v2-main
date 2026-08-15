# Technical observability

Odyssey uses the OpenTelemetry API and SDK directly. The API and worker own
isolated tracer and meter providers, so the domain model does not depend on a
monitoring vendor and tests can use in-memory exporters without changing global
process state. Product telemetry and AI/model-run records remain separate
governed data streams even when they share a trace or correlation identifier.

## Privacy boundary

Technical telemetry may contain only operational dimensions and opaque record
identifiers needed to locate data after owner authentication. Current spans
contain route templates, methods, status codes, durations, outbox IDs, bounded
topics, attempts, and outcomes. They never contain:

- request paths with substituted values, query strings, request/response bodies,
  authorization headers, cookies, or attachment upload tokens;
- source, event, operation, or model payloads;
- SQL statements or database connection URLs;
- exception messages or automatic exception events;
- OTLP credentials or exporter header values.

Incoming `X-Correlation-ID` values are accepted only when they match the
bounded safe identifier grammar. W3C `traceparent` and `tracestate` are parsed
only for propagation. Responses return `traceparent`, `X-Trace-ID`,
`X-Span-ID`, and `X-Correlation-ID` so an operator can connect a reported error
to payload-free logs and traces. A trace ID is a locator, not authorization to
resolve personal records.

## Exporters

`ODYSSEY_TELEMETRY_EXPORTER` selects one of three modes:

| Value | Behavior | Intended use |
| --- | --- | --- |
| `none` | providers stay no-op and no telemetry leaves the process | unit tests and explicit disablement |
| `console` | spans and periodic metric snapshots are written to stdout | credential-free Compose development |
| `otlp_http` | OTLP protobuf is sent over HTTP to a configured collector | staging and production |

For OTLP HTTP, set the collector base URL without `/v1/traces` or
`/v1/metrics`; Odyssey appends those signal paths.

```bash
export ODYSSEY_TELEMETRY_EXPORTER=otlp_http
export ODYSSEY_TELEMETRY_OTLP_ENDPOINT='https://collector.example'
export ODYSSEY_TELEMETRY_OTLP_HEADERS='authorization=Bearer%20REPLACE_AT_DEPLOYMENT'
export ODYSSEY_TELEMETRY_SAMPLE_RATIO=1.0
export ODYSSEY_TELEMETRY_EXPORT_INTERVAL_SECONDS=60
export ODYSSEY_TELEMETRY_EXPORT_TIMEOUT_SECONDS=10
```

Header names and values use comma-separated, percent-encoded `name=value`
pairs. Inject real values from the deployment secret store; never place them in
`.env`, Compose files, CI output, shell history, or Terraform state. The safe
diagnostics endpoint reports only exporter capability and whether an endpoint
is configured.

Structured application logs continue as one-line JSON on stdout with the same
correlation and trace IDs. The deployment platform forwards stdout to the
selected log backend. Odyssey does not use an opaque analytics SDK or capture
logs through an experimental provider-specific API.

## Current signals

HTTP server spans are named with the matched route template, for example
`POST /v1/sync/push`. Durable worker batches use `outbox process batch`; each
claimed record is a child `outbox deliver` consumer span. Idle polls do not
create traces.

| Metric | Type | Dimensions |
| --- | --- | --- |
| `odyssey.http.server.requests` | counter | method, route template, status code |
| `odyssey.http.server.errors` | counter | method, route template, status code |
| `odyssey.http.server.duration` | histogram, seconds | method, route template, status code |
| `odyssey.outbox.jobs` | counter | bounded outcome: completed, retry, dead letter |
| `odyssey.outbox.batch.duration` | histogram, seconds | none |
| `odyssey.outbox.queue.depth` | gauge | bounded state: pending, processing, retry, dead letter |
| `odyssey.outbox.queue.oldest_age` | gauge, seconds | none |

Resource attributes identify `service.name`, package version, deployment
environment, and commit SHA. They contain no owner, device, hostname, or
personal-record values.

## Alert contract

The worker evaluates two credential-free alert policies on every queue
snapshot and logs only state transitions:

- `OUTBOX_DEAD_LETTERS_PRESENT` is critical when dead-letter depth is at least
  one;
- `OUTBOX_BACKLOG_AGE_EXCEEDED` is warning when the oldest actionable record is
  at least `ODYSSEY_WORKER_BACKLOG_ALERT_SECONDS` old (three hours by default).

Production monitoring must independently route equivalent metric conditions to
an external channel that remains available when Odyssey is unavailable. At
minimum, alert when `odyssey.outbox.queue.depth{state="dead_letter"} >= 1` or
`odyssey.outbox.queue.oldest_age` exceeds the configured threshold. Add an HTTP
availability/error-budget alert for sync route templates using request and
error counters. Alert evaluation must use sustained windows for transient HTTP
errors and must never include payload samples in notifications.

Backup age, restore verification, migrations, model schemas/cost, integration
authorization, notifications, security anomalies, data quarantine, and client
crash signals are required by the master specification but are not yet emitted;
deployment must not claim those alerts are active until their producing
subsystems exist and have deterministic tests.

## Operator checks

1. Call `GET /v1/admin/diagnostics` and confirm the expected exporter,
   `payload_capture: false`, trace propagation, metrics, and structured logs.
2. Send a request with a valid synthetic `traceparent`; confirm the response
   retains its trace ID and the collector receives the route-template span.
3. Process a synthetic outbox record; confirm a batch span, child delivery span,
   outcome counter, and current queue gauges.
4. In staging, create and then resolve a synthetic retry/dead-letter condition;
   confirm alert raise and clear messages reach the external operator channel.
5. Confirm collector access is least privilege, retention is bounded, and a
   search for fixture payload markers returns no telemetry records.

The tests in `backend/tests/unit/test_telemetry.py` and
`backend/tests/integration/test_outbox_worker.py` enforce propagation,
redaction, metric export, span hierarchy, and alert thresholds without network
credentials.
