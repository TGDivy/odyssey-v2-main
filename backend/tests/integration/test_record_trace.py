import asyncio
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

from fastapi.testclient import TestClient

from odyssey.config import Environment, Settings
from odyssey.db.base import Base
from odyssey.db.projections import CurrentEntityProjectionRebuilder
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.jobs.outbox import internal_event_dispatcher, process_outbox_batch
from odyssey.main import create_app
from odyssey.operations.record_trace import (
    HttpTraceReference,
    RecordTraceQuery,
    RecordTraceService,
)

NOW = datetime(2026, 8, 15, 16, 0, tzinfo=UTC)


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


def test_payload_free_record_trace_links_capture_through_sync(tmp_path: Path) -> None:
    path = tmp_path / "record-trace.sqlite"
    database = prepare_database(path)
    app = create_app(Settings(env=Environment.TEST), database=database)
    capture_id = new_uuid7()
    event_id = new_uuid7()
    device_id = new_uuid7()
    operation_id = new_uuid7()
    private_content = "Synthetic private content must never appear in trace output"
    capture_correlation = "synthetic-record-trace-capture"
    sync_correlation = "synthetic-record-trace-sync"
    capture_body = {
        "capture_id": str(capture_id),
        "event_id": str(event_id),
        "captured_at": NOW.isoformat(),
        "kind": "text",
        "content_or_object_ref": private_content,
        "device_id": str(device_id),
        "timezone": "Europe/London",
        "invoking_surface": "record_trace_test",
    }
    push_body = {
        "device_id": str(device_id),
        "client_schema_version": 1,
        "base_cursor": "c_0",
        "operations": [
            {
                "operation_id": str(operation_id),
                "device_sequence": 1,
                "entity_type": "capture",
                "entity_id": str(capture_id),
                "mutation_type": "create",
                "base_revision": None,
                "payload": {
                    "capture_id": str(capture_id),
                    "event_id": str(event_id),
                    "kind": "text",
                    "content_or_object_ref": private_content,
                    "interpretation_status": "pending",
                },
                "created_at": NOW.isoformat(),
            }
        ],
    }

    with TestClient(app) as client:
        capture_response = client.post(
            "/v1/captures",
            json=capture_body,
            headers={
                "Idempotency-Key": str(event_id),
                "X-Correlation-ID": capture_correlation,
            },
        )
        push_response = client.post(
            "/v1/sync/push",
            json=push_body,
            headers={
                "Idempotency-Key": "synthetic-record-trace-batch",
                "X-Correlation-ID": sync_correlation,
            },
        )

    assert capture_response.status_code == 200
    assert push_response.status_code == 200

    async def build_trace() -> object:
        trace_database = Database(f"sqlite+aiosqlite:///{path}")
        try:
            async with trace_database.sessions() as session, session.begin():
                await CurrentEntityProjectionRebuilder().rebuild(session, rebuilt_at=NOW)
            await process_outbox_batch(
                trace_database,
                internal_event_dispatcher(),
                now=NOW + timedelta(days=1),
                batch_size=10,
                lease_seconds=60,
                max_attempts=3,
            )
            query = RecordTraceQuery(
                source_record_id=capture_id,
                http_traces=(
                    HttpTraceReference(
                        phase="capture_commit",
                        correlation_id=capture_correlation,
                        trace_id=capture_response.headers["X-Trace-ID"],
                        span_id=capture_response.headers["X-Span-ID"],
                    ),
                    HttpTraceReference(
                        phase="sync_push",
                        correlation_id=sync_correlation,
                        trace_id=push_response.headers["X-Trace-ID"],
                        span_id=push_response.headers["X-Span-ID"],
                    ),
                ),
            )
            async with trace_database.sessions() as session:
                return await RecordTraceService().trace(session, query, generated_at=NOW)
        finally:
            await trace_database.dispose()

    envelope = asyncio.run(build_trace())
    report = envelope.report
    serialized = json.dumps(envelope.model_dump(mode="json"), sort_keys=True)

    assert report.complete is True
    assert report.missing_links == ()
    assert len(envelope.report_sha256) == 64
    assert len(report.source_records) == 1
    assert len(report.provenance_records) == 1
    assert len(report.ledger_events) == 1
    assert len(report.outbox_records) == 2
    assert len(report.projections) == 1
    assert len(report.projection_checkpoints) == 1
    assert len(report.sync_operations) == 1
    assert len(report.server_changes) == 1
    assert len(report.canonical_entities) == 1
    assert report.source_records[0].content_hash_valid is True
    assert report.server_changes[0].content_hash_valid is True
    assert report.canonical_entities[0].content_hash_valid is True
    assert {record.status for record in report.outbox_records} == {"completed"}
    assert private_content not in serialized
    assert '"actor_id"' not in serialized
    assert '"document":' not in serialized
