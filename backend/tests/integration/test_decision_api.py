import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from odyssey.config import Environment, Settings
from odyssey.context.persistence import ContextSnapshotRecord
from odyssey.db.base import Base
from odyssey.db.session import Database
from odyssey.decision.persistence import DecisionPreparationRecord
from odyssey.domain.common import new_uuid7
from odyssey.main import create_app

NOW = datetime(2026, 8, 15, 12, tzinfo=UTC)


def prepare_database(path: Path) -> tuple[Database, object]:
    database = Database(f"sqlite+aiosqlite:///{path}")
    snapshot_id = new_uuid7()

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with database.sessions() as session, session.begin():
            session.add(
                ContextSnapshotRecord(
                    id=snapshot_id,
                    owner_id="owner",
                    as_of=NOW,
                    built_at=NOW,
                    horizon="P3D",
                    purpose="decision",
                    builder_version="test-builder",
                    content_hash="a" * 64,
                    document={
                        "snapshot": {
                            "domains": [
                                {"domain": "season", "status": "fresh"},
                                {"domain": "calendar", "status": "fresh"},
                            ]
                        }
                    },
                )
            )

    asyncio.run(create_schema())
    return database, snapshot_id


def base_request(snapshot_id: object) -> dict[str, object]:
    return {
        "question": "Should I complete the interval workout tomorrow morning?",
        "context_snapshot_id": str(snapshot_id),
        "known_options": [],
        "desired_depth": "interactive",
        "max_latency_ms": 8000,
        "stakes": "high",
    }


def test_decision_preparation_requests_options_without_guessing(tmp_path: Path) -> None:
    database, snapshot_id = prepare_database(tmp_path / "decision-info.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        response = client.post("/v1/decisions/prepare", json=base_request(snapshot_id))

    assert response.status_code == 200
    assert response.json()["status"] == "information_required"
    assert response.json()["missing_information"] == ["known_options"]
    assert response.json()["model_used"] is False
    assert response.json()["information_request"]


def test_decision_preparation_derives_consequences_and_strength_caps(tmp_path: Path) -> None:
    database, snapshot_id = prepare_database(tmp_path / "decision-structured.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    request = base_request(snapshot_id)
    request["known_options"] = [
        {
            "label": "Complete the workout",
            "description": "Keep the planned interval session.",
            "direct_effects": [
                {
                    "affected_state": "training_load",
                    "direction": "beneficial",
                    "magnitude": "medium",
                    "probability": 0.8,
                    "uncertainty": 0.2,
                    "effect_at": (NOW + timedelta(hours=24)).isoformat(),
                    "causal_status": "associational",
                    "evidence_refs": [str(new_uuid7())],
                    "input_keys": ["training"],
                    "method_version": "synthetic-rule-1",
                }
            ],
            "evidence": {
                "population_confidence": "moderate",
                "applicability": "indirect",
                "personal_causal_evidence": "none",
                "evidence_freshness": "acceptable",
                "personal_data_freshness": "acceptable",
            },
        }
    ]
    with TestClient(app) as client:
        response = client.post("/v1/decisions/prepare", json=request)

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "structured_options"
    assert body["recommendation_status"] == "options_prepared_for_owner_choice"
    assert body["options"][0]["consequences"]["consequences"][0]["horizon"] == "tomorrow"
    strength = body["options"][0]["recommendation_strength"]
    assert strength["maximum_strength"] == "weak"
    assert strength["presentation"] == "present_options_or_seek_information"
    assert body["model_used"] is False

    async def verify_persistence() -> None:
        async with database.sessions() as session:
            count = int(
                await session.scalar(select(func.count()).select_from(DecisionPreparationRecord))
                or 0
            )
            assert count == 1

    asyncio.run(verify_persistence())


def test_decision_preparation_returns_insufficient_evidence_for_bare_option(
    tmp_path: Path,
) -> None:
    database, snapshot_id = prepare_database(tmp_path / "decision-insufficient.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    request = base_request(snapshot_id)
    request["known_options"] = [
        {"label": "Wait", "description": "Wait for more information."}
    ]
    with TestClient(app) as client:
        response = client.post("/v1/decisions/prepare", json=request)

    assert response.status_code == 200
    assert response.json()["status"] == "insufficient_evidence"
    assert len(response.json()["missing_information"]) == 2


def test_decision_preparation_requires_owned_context_snapshot(tmp_path: Path) -> None:
    database, _ = prepare_database(tmp_path / "decision-missing.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        response = client.post("/v1/decisions/prepare", json=base_request(new_uuid7()))

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "CONTEXT_SNAPSHOT_NOT_FOUND"
