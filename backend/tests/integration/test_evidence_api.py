import asyncio
from datetime import UTC, datetime
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from odyssey.config import Environment, Settings
from odyssey.db.base import Base
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.evidence.query_persistence import EvidenceQueryRecord
from odyssey.main import create_app


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


def seed_evidence(client: TestClient, *, approve_personal_scope: bool) -> None:
    now = datetime.now(UTC)
    source_id = new_uuid7()
    supporting_claim_id = new_uuid7()
    counter_claim_id = new_uuid7()
    operations: list[dict[str, object]] = []

    def add(entity_type: str, entity_id: object, payload: dict[str, object]) -> None:
        operations.append(
            {
                "operation_id": str(new_uuid7()),
                "device_sequence": len(operations) + 1,
                "entity_type": entity_type,
                "entity_id": str(entity_id),
                "mutation_type": "create",
                "base_revision": None,
                "payload": payload,
                "created_at": now.isoformat(),
            }
        )

    add(
        "evidence_source",
        source_id,
        {
            "title": "Synthetic caffeine and sleep review",
            "source_type": "systematic_review",
            "version_or_retraction_state": "current",
        },
    )
    for claim_id, relation, text in (
        (
            supporting_claim_id,
            "supporting",
            "Late caffeine is associated with longer sleep onset latency.",
        ),
        (
            counter_claim_id,
            "counterevidence",
            "Some adults show little sleep change after late caffeine.",
        ),
    ):
        add(
            "evidence_claim",
            claim_id,
            {
                "source_id": str(source_id),
                "claim_text_normalized": text,
                "relation": relation,
                "exact_support_span_refs": [f"synthetic:{claim_id}"],
                "limitations": ["Synthetic fixture; not clinical advice."],
                "domain_tags": ["sleep", "caffeine"],
            },
        )
        add(
            "claim_appraisal",
            new_uuid7(),
            {
                "claim_id": str(claim_id),
                "overall_confidence": "high",
                "applicability_to_user": "Population evidence; personal effect remains uncertain.",
            },
        )
    add(
        "personal_observation",
        new_uuid7(),
        {
            "summary": "Late caffeine preceded longer sleep onset in several observations.",
            "observed_at": now.isoformat(),
            "domain_tags": ["sleep", "caffeine"],
            "source_refs": [],
        },
    )
    add(
        "experiment_result",
        new_uuid7(),
        {
            "interpretation": "A caffeine cutoff experiment was inconclusive for sleep onset.",
            "effect_estimate": "small",
            "interval_or_uncertainty": "wide interval",
            "replication_state": "not_replicated",
            "domain_tags": ["sleep", "caffeine"],
        },
    )
    if approve_personal_scope:
        add(
            "evidence_scope_approval",
            new_uuid7(),
            {
                "scope": "approved_sleep_and_caffeine",
                "status": "approved",
                "domains": ["sleep", "caffeine"],
            },
        )
    response = client.post(
        "/v1/sync/push",
        json={
            "device_id": str(new_uuid7()),
            "client_schema_version": 1,
            "base_cursor": "c_0",
            "operations": operations,
        },
        headers={"Idempotency-Key": str(new_uuid7())},
    )
    assert response.status_code == 200


def query_body() -> dict[str, object]:
    return {
        "question": "How does late caffeine affect sleep?",
        "population_context": {"adult": True},
        "personal_context_scope": "approved_sleep_and_caffeine",
        "source_policy": {
            "minimum_quality": "moderate",
            "include_emerging": True,
            "require_counterevidence": True,
        },
    }


def test_evidence_query_separates_scientific_personal_and_counterevidence(
    tmp_path: Path,
) -> None:
    database = prepare_database(tmp_path / "evidence.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        seed_evidence(client, approve_personal_scope=True)
        response = client.post("/v1/evidence/query", json=query_body())

    assert response.status_code == 200
    body = response.json()
    assert len(body["scientific_claims"]) == 1
    assert len(body["counterevidence_claims"]) == 1
    assert len(body["personal_observations"]) == 1
    assert len(body["personal_experiments"]) == 1
    assert body["personal_scope_status"] == "approved"
    assert body["counterevidence_status"] == "included"
    assert body["scientific_claims"][0]["exact_support_span_refs"]
    assert body["applicability_summary"]
    assert body["retrieval_version"] == "evidence-retrieval-1.0"

    async def verify_query_replay() -> None:
        async with database.sessions() as session:
            count = int(
                await session.scalar(select(func.count()).select_from(EvidenceQueryRecord)) or 0
            )
            assert count == 1

    asyncio.run(verify_query_replay())


def test_unapproved_personal_scope_excludes_personal_records(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "evidence-scope.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        seed_evidence(client, approve_personal_scope=False)
        response = client.post("/v1/evidence/query", json=query_body())

    assert response.status_code == 200
    body = response.json()
    assert body["personal_scope_status"] == "not_approved"
    assert body["personal_observations"] == []
    assert body["personal_experiments"] == []
    assert "PERSONAL_SCOPE_NOT_APPROVED" in {
        item["code"] for item in body["uncertainties"]
    }


def test_missing_counterevidence_is_uncertainty_not_no_effect_claim(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "evidence-empty.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    with TestClient(app) as client:
        response = client.post("/v1/evidence/query", json=query_body())

    assert response.status_code == 200
    body = response.json()
    assert body["scientific_claims"] == []
    assert body["counterevidence_status"] == "searched_none_found"
    assert {item["code"] for item in body["uncertainties"]} >= {
        "NO_SCIENTIFIC_MATCH",
        "COUNTEREVIDENCE_NOT_FOUND",
    }
