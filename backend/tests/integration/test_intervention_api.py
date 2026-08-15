import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from odyssey.config import Environment, Settings
from odyssey.db.base import Base
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.intent.persistence import InterventionEvaluationRecord
from odyssey.main import create_app


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


def seed_opportunity(
    client: TestClient,
    *,
    expires_at: datetime,
    expected_benefit: float = 0.8,
    expected_cost: float = 0.2,
    include_pause: bool = False,
) -> object:
    now = datetime.now(UTC)
    device_id = new_uuid7()
    intent_id = new_uuid7()
    opportunity_id = new_uuid7()
    operations: list[dict[str, object]] = [
        {
            "operation_id": str(new_uuid7()),
            "device_sequence": 1,
            "entity_type": "intent",
            "entity_id": str(intent_id),
            "mutation_type": "create",
            "base_revision": None,
            "payload": {"status": "active", "statement": "Prepare calmly"},
            "created_at": now.isoformat(),
        },
        {
            "operation_id": str(new_uuid7()),
            "device_sequence": 2,
            "entity_type": "intervention_opportunity",
            "entity_id": str(opportunity_id),
            "mutation_type": "create",
            "base_revision": None,
            "payload": {
                "intent_id": str(intent_id),
                "expires_at": expires_at.isoformat(),
                "semantic_key": "prepare-interview",
                "context_confidence": 0.9,
                "expected_benefit": expected_benefit,
                "expected_interruption_cost": expected_cost,
                "urgency": "normal",
                "channels": [
                    {
                        "kind": "widget",
                        "expected_effectiveness": 0.7,
                        "interruptiveness": 0.05,
                        "ambient": True,
                    },
                    {
                        "kind": "local_notification",
                        "expected_effectiveness": 0.8,
                        "interruptiveness": 0.8,
                    },
                ],
            },
            "created_at": now.isoformat(),
        },
    ]
    if include_pause:
        operations.append(
            {
                "operation_id": str(new_uuid7()),
                "device_sequence": 3,
                "entity_type": "proactive_control",
                "entity_id": str(new_uuid7()),
                "mutation_type": "create",
                "base_revision": None,
                "payload": {"paused": True},
                "created_at": now.isoformat(),
            }
        )
    push = client.post(
        "/v1/sync/push",
        json={
            "device_id": str(device_id),
            "client_schema_version": 1,
            "base_cursor": "c_0",
            "operations": operations,
        },
        headers={"Idempotency-Key": str(new_uuid7())},
    )
    assert push.status_code == 200
    return opportunity_id


def request_body(opportunity_id: object) -> dict[str, object]:
    return {
        "opportunity_id": str(opportunity_id),
        "delivery_capabilities": {
            "local_notification": True,
            "live_activity": False,
            "watch_reachable": False,
            "widget_snapshot": True,
            "in_app": True,
        },
        "client_state": {
            "foreground": False,
            "focus_redaction": "private",
            "recently_handled": False,
        },
    }


def test_intervention_evaluation_uses_ambient_surface_and_appends_audit(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "intervention.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        opportunity_id = seed_opportunity(
            client,
            expires_at=datetime.now(UTC) + timedelta(hours=1),
            expected_benefit=0.3,
            expected_cost=0.25,
        )
        response = client.post(
            "/v1/intents/opportunities/evaluate",
            json=request_body(opportunity_id),
        )

    assert response.status_code == 200
    assert response.json()["policy"] == "ambient"
    assert response.json()["surface"] == "widget_snapshot"
    assert response.json()["reason_codes"] == ["INTERRUPTION_NOT_JUSTIFIED"]

    async def verify_audit() -> None:
        async with database.sessions() as session:
            count = int(
                await session.scalar(
                    select(func.count()).select_from(InterventionEvaluationRecord)
                )
                or 0
            )
            assert count == 1

    asyncio.run(verify_audit())


def test_global_pause_and_expiry_are_hard_suppressions(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "intervention-hard-gates.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        paused_id = seed_opportunity(
            client,
            expires_at=datetime.now(UTC) + timedelta(hours=1),
            include_pause=True,
        )
        paused = client.post(
            "/v1/intents/opportunities/evaluate",
            json=request_body(paused_id),
        )

    assert paused.status_code == 200
    assert paused.json()["policy"] == "suppress"
    assert paused.json()["reason_codes"] == ["GLOBAL_PAUSE"]


def test_missing_or_malformed_opportunity_fails_closed(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "intervention-missing.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        missing = client.post(
            "/v1/intents/opportunities/evaluate",
            json=request_body(new_uuid7()),
        )

    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "INTERVENTION_OPPORTUNITY_NOT_FOUND"
