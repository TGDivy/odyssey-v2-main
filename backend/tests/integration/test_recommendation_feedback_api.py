import asyncio
import json
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from odyssey.config import Environment, Settings
from odyssey.db.base import Base
from odyssey.db.models import AssertionRecord, LedgerEventRecord, OutboxRecord, ProvenanceRecord
from odyssey.db.session import Database
from odyssey.decision.feedback_persistence import RecommendationFeedbackRecord
from odyssey.domain.common import new_uuid7
from odyssey.main import create_app


def prepare_database(path: Path) -> tuple[Database, object, object]:
    database = Database(f"sqlite+aiosqlite:///{path}")
    recommendation_id = new_uuid7()
    assertion_id = new_uuid7()

    async def create_schema_and_assertion() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        provenance_id = uuid4()
        async with database.sessions() as session, session.begin():
            session.add(
                ProvenanceRecord(
                    id=provenance_id,
                    source_kind="test",
                    source_id="original-assertion",
                    actor_type="user",
                    actor_id="owner",
                    recorded_at=datetime.now(UTC),
                    transformation_chain=[],
                    details={},
                )
            )
            await session.flush()
            session.add(
                AssertionRecord(
                    id=assertion_id,
                    subject_id=new_uuid7(),
                    predicate="calendar_status",
                    object_value={"value": "scheduled"},
                    epistemic_status="observed",
                    confidence=0.8,
                    provenance_id=provenance_id,
                    created_at=datetime.now(UTC),
                )
            )

    asyncio.run(create_schema_and_assertion())
    return database, recommendation_id, assertion_id


def seed_recommendation(client: TestClient, recommendation_id: object) -> None:
    now = datetime.now(UTC)
    response = client.post(
        "/v1/sync/push",
        json={
            "device_id": str(new_uuid7()),
            "client_schema_version": 1,
            "base_cursor": "c_0",
            "operations": [
                {
                    "operation_id": str(new_uuid7()),
                    "device_sequence": 1,
                    "entity_type": "recommendation",
                    "entity_id": str(recommendation_id),
                    "mutation_type": "create",
                    "base_revision": None,
                    "payload": {"summary": "Synthetic recommendation"},
                    "created_at": now.isoformat(),
                }
            ],
        },
        headers={"Idempotency-Key": str(new_uuid7())},
    )
    assert response.status_code == 200


def feedback_body(assertion_id: object, replacement: str = "cancelled") -> dict[str, object]:
    return {
        "feedback_type": "wrong_context",
        "correction": {
            "assertion_id": str(assertion_id),
            "replacement": replacement,
        },
        "apply_scope": "this_event_only",
    }


def test_feedback_supersedes_assertion_atomically_and_replays(tmp_path: Path) -> None:
    database, recommendation_id, assertion_id = prepare_database(tmp_path / "feedback.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        seed_recommendation(client, recommendation_id)
        first = client.post(
            f"/v1/recommendations/{recommendation_id}/feedback",
            json=feedback_body(assertion_id),
            headers={"Idempotency-Key": "feedback-1"},
        )
        replay = client.post(
            f"/v1/recommendations/{recommendation_id}/feedback",
            json=feedback_body(assertion_id),
            headers={"Idempotency-Key": "feedback-1"},
        )

    assert first.status_code == 200
    assert replay.json() == first.json()
    assert first.json()["future_recommendations_affected"] is False
    assert [item["record_type"] for item in first.json()["records_changed"]] == [
        "recommendation_feedback",
        "assertion",
        "ledger_event",
    ]

    async def verify() -> None:
        async with database.sessions() as session:
            assertions = tuple(
                (
                    await session.scalars(
                        select(AssertionRecord).order_by(AssertionRecord.created_at)
                    )
                ).all()
            )
            assert len(assertions) == 2
            assert assertions[0].object_value == {"value": "scheduled"}
            assert assertions[1].supersedes_id == assertion_id
            assert assertions[1].object_value == {"value": "cancelled"}
            assert int(
                await session.scalar(
                    select(func.count()).select_from(RecommendationFeedbackRecord)
                )
                or 0
            ) == 1
            assert int(
                await session.scalar(select(func.count()).select_from(LedgerEventRecord)) or 0
            ) == 1
            assert int(
                await session.scalar(
                    select(func.count())
                    .select_from(OutboxRecord)
                    .where(OutboxRecord.topic == "domain-event")
                )
                or 0
            ) == 1
            correction_provenance = await session.get(
                ProvenanceRecord,
                assertions[1].provenance_id,
            )
            assert correction_provenance is not None
            assert correction_provenance.content_hash == sha256(
                json_bytes_for_correction(
                    first.json()["feedback_id"],
                    recommendation_id,
                    assertion_id,
                    assertions[1].id,
                    "cancelled",
                )
            ).hexdigest()

    asyncio.run(verify())


def json_bytes_for_correction(
    feedback_id: object,
    recommendation_id: object,
    assertion_id: object,
    replacement_id: object,
    replacement: str,
) -> bytes:
    return json.dumps(
        {
            "apply_scope": "this_event_only",
            "assertion_id": str(assertion_id),
            "feedback_id": str(feedback_id),
            "recommendation_id": str(recommendation_id),
            "replacement": replacement,
            "replacement_assertion_id": str(replacement_id),
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode()


def test_feedback_idempotency_key_cannot_change_meaning(tmp_path: Path) -> None:
    database, recommendation_id, assertion_id = prepare_database(tmp_path / "feedback-key.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        seed_recommendation(client, recommendation_id)
        first = client.post(
            f"/v1/recommendations/{recommendation_id}/feedback",
            json=feedback_body(assertion_id),
            headers={"Idempotency-Key": "same-key"},
        )
        conflict = client.post(
            f"/v1/recommendations/{recommendation_id}/feedback",
            json=feedback_body(assertion_id, "rescheduled"),
            headers={"Idempotency-Key": "same-key"},
        )

    assert first.status_code == 200
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "FEEDBACK_IDEMPOTENCY_KEY_REUSED"


def test_future_scope_fails_closed_until_retrieval_consumes_it(tmp_path: Path) -> None:
    database, recommendation_id, assertion_id = prepare_database(tmp_path / "feedback-scope.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    body = feedback_body(assertion_id)
    body["apply_scope"] = "future_recommendations"
    with TestClient(app) as client:
        seed_recommendation(client, recommendation_id)
        response = client.post(
            f"/v1/recommendations/{recommendation_id}/feedback",
            json=body,
            headers={"Idempotency-Key": "future-key"},
        )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "CORRECTION_SCOPE_NOT_IMPLEMENTED"
