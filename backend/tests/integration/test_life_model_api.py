import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError

from odyssey.api import seasons as seasons_api
from odyssey.config import Environment, Settings
from odyssey.db import Base, Database
from odyssey.db.models import LedgerEventRecord
from odyssey.domain.common import (
    ActorRef,
    ActorType,
    DataClass,
    EntityMetadata,
    TemporalInterval,
    TemporalPrecision,
    new_uuid7,
)
from odyssey.domain.life import (
    AllocationBand,
    CharterValue,
    CharterVersion,
    DirectionRole,
    LifeStageVersion,
    Season,
    SeasonCreationSource,
    SeasonPortfolioItem,
    SeasonStatus,
)
from odyssey.life.contracts import (
    AcceptanceMethod,
    CharterRevisionRequest,
    LifeStageRevisionRequest,
    SeasonRevisionRequest,
)
from odyssey.life.persistence import LifeModelVersionRecord
from odyssey.main import create_app

CREATED_AT = datetime(2026, 8, 15, 19, tzinfo=UTC)
DEVICE_ID = new_uuid7()


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


def metadata(
    *,
    version_id: object,
    revision: int,
    revised_at: datetime,
    created_at: datetime = CREATED_AT,
) -> EntityMetadata:
    return EntityMetadata(
        id=version_id,
        schema_version=1,
        created_at=created_at,
        created_by=ActorRef(actor_type=ActorType.USER, actor_id="owner"),
        last_revised_at=revised_at,
        revision=revision,
        sensitivity=DataClass.PRIVATE,
        provenance_id=new_uuid7(),
    )


def charter_request(
    *,
    charter_id: object,
    version_id: object,
    value_id: object,
    revision: int,
    accepted_at: datetime,
    event_id: object | None = None,
    expected_current_version_id: object | None = None,
    supersedes_version_id: object | None = None,
    interpretation_notes: str = "Owner-authored synthetic Charter.",
) -> dict[str, object]:
    charter = CharterVersion(
        metadata=metadata(
            version_id=version_id,
            revision=revision,
            revised_at=accepted_at,
        ),
        charter_id=charter_id,
        version_number=revision,
        effective_interval=TemporalInterval(
            start=CREATED_AT,
            timezone_id="Europe/London",
            start_precision=TemporalPrecision.EXACT,
        ),
        values=(
            CharterValue(
                id=value_id,
                title="Integrity",
                description="Keep consequential choices self-endorsed.",
                positive_expression="Act honestly and preserve agency.",
                anti_value_or_failure_mode="Performative optimization.",
            ),
        ),
        responsibilities=("Keep explicit commitments.",),
        desired_ways_of_being=("Present",),
        non_negotiable_boundaries=("No hidden external action.",),
        anti_optimization_statements=("Never optimize away meaningful relationships.",),
        interpretation_notes=interpretation_notes,
        supersedes_version_id=supersedes_version_id,
        accepted_at=accepted_at,
    )
    return CharterRevisionRequest(
        event_id=event_id or new_uuid7(),
        device_id=DEVICE_ID,
        expected_current_version_id=expected_current_version_id,
        acceptance_method=AcceptanceMethod.OWNER_AUTHORED,
        charter=charter,
    ).model_dump(mode="json")


def life_stage_request(
    *,
    stage_id: object,
    version_id: object,
    accepted_at: datetime,
) -> dict[str, object]:
    life_stage = LifeStageVersion(
        metadata=metadata(version_id=version_id, revision=1, revised_at=accepted_at),
        stage_id=stage_id,
        effective_interval=TemporalInterval(
            start=CREATED_AT,
            timezone_id="Europe/London",
            start_precision=TemporalPrecision.EXACT,
        ),
        title="Synthetic current stage",
        career_context="Established role with an active external search.",
        partnership_family_context="Owner-described context only.",
        health_capability_context="Able to train with ordinary adaptation.",
        geography_context="London",
        financial_context="Stable with explicit uncertainty.",
        uncertainties=("Future role location is unknown.",),
    )
    return LifeStageRevisionRequest(
        event_id=new_uuid7(),
        device_id=DEVICE_ID,
        acceptance_method=AcceptanceMethod.OWNER_REVIEWED_ASSISTED,
        accepted_at=accepted_at,
        life_stage=life_stage,
    ).model_dump(mode="json")


def season_request(
    *,
    season_id: object,
    version_id: object,
    charter_revision_id: object,
    direction_id: object,
    revision: int,
    status: SeasonStatus,
    accepted_at: datetime,
    created_at: datetime = CREATED_AT,
    expected_current_version_id: object | None = None,
    supersedes_season_id: object | None = None,
) -> dict[str, object]:
    season = Season(
        metadata=metadata(
            version_id=version_id,
            revision=revision,
            revised_at=accepted_at,
            created_at=created_at,
        ),
        charter_revision_id=charter_revision_id,
        title="Synthetic orientation season",
        effective_interval=TemporalInterval(
            start=created_at,
            end=created_at + timedelta(days=90),
            timezone_id="Europe/London",
            start_precision=TemporalPrecision.EXACT,
            end_precision=TemporalPrecision.EXACT,
        ),
        status=status,
        created_from=SeasonCreationSource.USER,
        rationale="Protect foundations while preparing one meaningful transition.",
        triggering_context=("Owner accepted this synthetic test context.",),
        portfolio_items=(
            SeasonPortfolioItem(
                direction_id=direction_id,
                role=DirectionRole.PRIMARY,
                allocation_band=AllocationBand.DOMINANT,
                minimum_viable_commitment="One focused block each week.",
                sacrifice_limit="Do not reduce protected sleep.",
                success_signals=("Prepared decisions are easier to make.",),
            ),
        ),
        explicit_non_goals=("Do not optimize every open hour.",),
        constraints=("Protect accepted commitments.",),
        opportunity_budgets=("One spontaneous evening each week.",),
        progress_signals=("Owner reports clearer orientation.",),
        failure_guardrails=("No guilt for legitimate exceptions.",),
        protected_experiences=("Time with close friends.",),
        known_tradeoffs=("Less time for dormant projects.",),
        good_week_description="Important preparation advances without crowding out relationships.",
        transition_triggers=("The role transition resolves.",),
        review_cadence="P2W",
        supersedes_season_id=supersedes_season_id,
    )
    return SeasonRevisionRequest(
        event_id=new_uuid7(),
        device_id=DEVICE_ID,
        season_id=season_id,
        expected_current_version_id=expected_current_version_id,
        acceptance_method=AcceptanceMethod.OWNER_AUTHORED,
        accepted_at=accepted_at,
        season=season,
    ).model_dump(mode="json")


def test_charter_revisions_are_idempotent_versioned_and_inspectable(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "charter.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    charter_id = new_uuid7()
    value_id = new_uuid7()
    first_version_id = new_uuid7()
    first_event_id = new_uuid7()
    first_request = charter_request(
        charter_id=charter_id,
        version_id=first_version_id,
        value_id=value_id,
        revision=1,
        accepted_at=CREATED_AT,
        event_id=first_event_id,
    )

    with TestClient(app) as client:
        first = client.post("/v1/seasons/charter/revisions", json=first_request)
        retry = client.post("/v1/seasons/charter/revisions", json=first_request)
        assert first.status_code == 200
        assert first.json()["created"] is True
        assert first.json()["version"]["acceptance_sequence"] == 1
        assert retry.status_code == 200
        assert retry.json()["created"] is False
        assert retry.json()["ledger_sequence"] == first.json()["ledger_sequence"]
        assert retry.json()["version"]["acceptance_sequence"] == 1

        second_version_id = new_uuid7()
        second_request = charter_request(
            charter_id=charter_id,
            version_id=second_version_id,
            value_id=value_id,
            revision=2,
            accepted_at=CREATED_AT + timedelta(minutes=5),
            expected_current_version_id=first_version_id,
            supersedes_version_id=first_version_id,
            interpretation_notes="Owner clarified the same Charter without rewriting version one.",
        )
        second = client.post("/v1/seasons/charter/revisions", json=second_request)
        assert second.status_code == 200
        assert second.json()["version"]["version_number"] == 2
        assert second.json()["version"]["acceptance_sequence"] == 2
        assert second.json()["version"]["supersedes_version_id"] == str(first_version_id)

        orientation = client.get("/v1/seasons/orientation")
        history = client.get("/v1/seasons/history", params={"kind": "charter"})

    assert orientation.status_code == 200
    assert orientation.json()["charter"]["version_id"] == str(second_version_id)
    assert orientation.json()["charter"]["acceptance_sequence"] == 2
    assert [item["version_number"] for item in history.json()["versions"]] == [2, 1]
    assert [item["acceptance_sequence"] for item in history.json()["versions"]] == [2, 1]


def test_charter_revision_rejects_stale_current_and_event_reuse(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "charter-conflict.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    charter_id = new_uuid7()
    value_id = new_uuid7()
    first_version_id = new_uuid7()
    first_event_id = new_uuid7()
    first_request = charter_request(
        charter_id=charter_id,
        version_id=first_version_id,
        value_id=value_id,
        revision=1,
        accepted_at=CREATED_AT,
        event_id=first_event_id,
    )

    with TestClient(app) as client:
        assert client.post("/v1/seasons/charter/revisions", json=first_request).status_code == 200
        stale = charter_request(
            charter_id=charter_id,
            version_id=new_uuid7(),
            value_id=value_id,
            revision=2,
            accepted_at=CREATED_AT + timedelta(minutes=1),
            expected_current_version_id=new_uuid7(),
            supersedes_version_id=first_version_id,
        )
        stale_response = client.post("/v1/seasons/charter/revisions", json=stale)
        reused_event = charter_request(
            charter_id=charter_id,
            version_id=new_uuid7(),
            value_id=value_id,
            revision=2,
            accepted_at=CREATED_AT + timedelta(minutes=1),
            event_id=first_event_id,
            expected_current_version_id=first_version_id,
            supersedes_version_id=first_version_id,
        )
        reused_response = client.post("/v1/seasons/charter/revisions", json=reused_event)
        changed_method = dict(first_request)
        changed_method["acceptance_method"] = "owner_reviewed_assisted"
        changed_method_response = client.post("/v1/seasons/charter/revisions", json=changed_method)
        reused_version = charter_request(
            charter_id=charter_id,
            version_id=first_version_id,
            value_id=value_id,
            revision=2,
            accepted_at=CREATED_AT + timedelta(minutes=1),
            expected_current_version_id=first_version_id,
            supersedes_version_id=first_version_id,
        )
        reused_version_response = client.post("/v1/seasons/charter/revisions", json=reused_version)

    assert stale_response.status_code == 409
    assert stale_response.json()["error"]["code"] == "LIFE_MODEL_CURRENT_VERSION_CONFLICT"
    assert reused_response.status_code == 409
    assert reused_response.json()["error"]["code"] == "LIFE_MODEL_EVENT_ID_REUSED"
    assert changed_method_response.status_code == 409
    assert changed_method_response.json()["error"]["code"] == "LIFE_MODEL_EVENT_ID_REUSED"
    assert reused_version_response.status_code == 409
    assert reused_version_response.json()["error"]["code"] == "LIFE_MODEL_IDENTIFIER_REUSED"


def test_charter_revision_rejects_an_event_id_owned_by_another_domain(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "cross-domain-event.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    event_id = new_uuid7()

    with TestClient(app) as client:
        capture = client.post(
            "/v1/captures",
            headers={"Idempotency-Key": str(event_id)},
            json={
                "capture_id": str(new_uuid7()),
                "event_id": str(event_id),
                "captured_at": CREATED_AT.isoformat(),
                "kind": "text",
                "content_or_object_ref": "Synthetic cross-domain event collision.",
                "device_id": str(DEVICE_ID),
                "timezone": "Europe/London",
                "invoking_surface": "integration_test",
            },
        )
        revision = client.post(
            "/v1/seasons/charter/revisions",
            json=charter_request(
                charter_id=new_uuid7(),
                version_id=new_uuid7(),
                value_id=new_uuid7(),
                revision=1,
                accepted_at=CREATED_AT,
                event_id=event_id,
            ),
        )

    assert capture.status_code == 200
    assert revision.status_code == 409
    assert revision.json()["error"]["code"] == "LIFE_MODEL_EVENT_ID_REUSED"


def test_concurrent_acceptance_integrity_collision_is_a_reviewable_conflict(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    database = prepare_database(tmp_path / "concurrent-acceptance.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)

    async def reject_append(_session: object, **_kwargs: object) -> None:
        raise IntegrityError("synthetic insert", {}, Exception("unique acceptance sequence"))

    monkeypatch.setattr(
        seasons_api.service,
        "repository",
        SimpleNamespace(append_source_event=reject_append),
    )

    with TestClient(app) as client:
        response = client.post(
            "/v1/seasons/charter/revisions",
            json=charter_request(
                charter_id=new_uuid7(),
                version_id=new_uuid7(),
                value_id=new_uuid7(),
                revision=1,
                accepted_at=CREATED_AT,
            ),
        )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "LIFE_MODEL_CONCURRENT_ACCEPTANCE"


def test_accepted_orientation_is_available_to_context_assembly(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "orientation-context.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    charter_id = new_uuid7()
    charter_version_id = new_uuid7()
    stage_id = new_uuid7()
    stage_version_id = new_uuid7()
    season_id = new_uuid7()
    season_version_id = new_uuid7()
    direction_id = new_uuid7()

    with TestClient(app) as client:
        assert (
            client.post(
                "/v1/seasons/charter/revisions",
                json=charter_request(
                    charter_id=charter_id,
                    version_id=charter_version_id,
                    value_id=new_uuid7(),
                    revision=1,
                    accepted_at=CREATED_AT,
                ),
            ).status_code
            == 200
        )
        assert (
            client.post(
                "/v1/seasons/life-stage/revisions",
                json=life_stage_request(
                    stage_id=stage_id,
                    version_id=stage_version_id,
                    accepted_at=CREATED_AT + timedelta(minutes=1),
                ),
            ).status_code
            == 200
        )
        season_response = client.post(
            "/v1/seasons/revisions",
            json=season_request(
                season_id=season_id,
                version_id=season_version_id,
                charter_revision_id=charter_version_id,
                direction_id=direction_id,
                revision=1,
                status=SeasonStatus.ACTIVE,
                accepted_at=CREATED_AT + timedelta(minutes=2),
            ),
        )
        context = client.post(
            "/v1/context/assemble",
            json={
                "as_of": (CREATED_AT + timedelta(hours=1)).isoformat(),
                "horizon": "P7D",
                "purpose": "orientation-test",
                "requested_domains": ["season"],
            },
        )

    assert season_response.status_code == 200
    assert season_response.json()["version"]["status"] == "active"
    assert context.status_code == 200
    season_domain = context.json()["snapshot"]["domains"][0]
    assert season_domain["status"] == "fresh"
    assert {fact["entity_type"] for fact in season_domain["facts"]} == {
        "charter_version",
        "life_stage",
        "season_version",
    }
    assert {fact["entity_id"] for fact in season_domain["facts"]} == {
        str(charter_version_id),
        str(stage_version_id),
        str(season_version_id),
    }


def test_season_state_machine_is_versioned_and_terminal(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "season-state.sqlite")
    app = create_app(Settings(env=Environment.TEST), database=database)
    charter_id = new_uuid7()
    charter_version_id = new_uuid7()
    season_id = new_uuid7()
    direction_id = new_uuid7()
    active_version_id = new_uuid7()

    with TestClient(app) as client:
        assert (
            client.post(
                "/v1/seasons/charter/revisions",
                json=charter_request(
                    charter_id=charter_id,
                    version_id=charter_version_id,
                    value_id=new_uuid7(),
                    revision=1,
                    accepted_at=CREATED_AT,
                ),
            ).status_code
            == 200
        )
        active = client.post(
            "/v1/seasons/revisions",
            json=season_request(
                season_id=season_id,
                version_id=active_version_id,
                charter_revision_id=charter_version_id,
                direction_id=direction_id,
                revision=1,
                status=SeasonStatus.ACTIVE,
                accepted_at=CREATED_AT + timedelta(minutes=1),
            ),
        )
        premature_successor = client.post(
            "/v1/seasons/revisions",
            json=season_request(
                season_id=new_uuid7(),
                version_id=new_uuid7(),
                charter_revision_id=charter_version_id,
                direction_id=new_uuid7(),
                revision=1,
                status=SeasonStatus.DRAFT,
                accepted_at=CREATED_AT + timedelta(seconds=90),
                created_at=CREATED_AT + timedelta(seconds=90),
                expected_current_version_id=active_version_id,
                supersedes_season_id=season_id,
            ),
        )
        transitioning_version_id = new_uuid7()
        transitioning = client.post(
            "/v1/seasons/revisions",
            json=season_request(
                season_id=season_id,
                version_id=transitioning_version_id,
                charter_revision_id=charter_version_id,
                direction_id=direction_id,
                revision=2,
                status=SeasonStatus.TRANSITIONING,
                accepted_at=CREATED_AT + timedelta(minutes=2),
                expected_current_version_id=active_version_id,
            ),
        )
        complete_version_id = new_uuid7()
        complete = client.post(
            "/v1/seasons/revisions",
            json=season_request(
                season_id=season_id,
                version_id=complete_version_id,
                charter_revision_id=charter_version_id,
                direction_id=direction_id,
                revision=3,
                status=SeasonStatus.COMPLETE,
                accepted_at=CREATED_AT + timedelta(minutes=3),
                expected_current_version_id=transitioning_version_id,
            ),
        )
        illegal = client.post(
            "/v1/seasons/revisions",
            json=season_request(
                season_id=season_id,
                version_id=new_uuid7(),
                charter_revision_id=charter_version_id,
                direction_id=direction_id,
                revision=4,
                status=SeasonStatus.ACTIVE,
                accepted_at=CREATED_AT + timedelta(minutes=4),
                expected_current_version_id=complete_version_id,
            ),
        )
        successor_id = new_uuid7()
        successor = client.post(
            "/v1/seasons/revisions",
            json=season_request(
                season_id=successor_id,
                version_id=new_uuid7(),
                charter_revision_id=charter_version_id,
                direction_id=new_uuid7(),
                revision=1,
                status=SeasonStatus.DRAFT,
                accepted_at=CREATED_AT + timedelta(minutes=5),
                created_at=CREATED_AT + timedelta(minutes=5),
                expected_current_version_id=complete_version_id,
                supersedes_season_id=season_id,
            ),
        )

    assert active.status_code == 200
    assert active.json()["version"]["acceptance_sequence"] == 1
    assert premature_successor.status_code == 400
    assert premature_successor.json()["error"]["code"] == "SEASON_SUCCESSOR_PREMATURE"
    assert transitioning.status_code == 200
    assert transitioning.json()["version"]["acceptance_sequence"] == 2
    assert complete.status_code == 200
    assert complete.json()["version"]["acceptance_sequence"] == 3
    assert illegal.status_code == 400
    assert illegal.json()["error"]["code"] == "SEASON_TRANSITION_INVALID"
    assert successor.status_code == 200
    assert successor.json()["version"]["acceptance_sequence"] == 4

    async def verify_history() -> None:
        async with database.sessions() as session:
            count = int(
                await session.scalar(select(func.count()).select_from(LifeModelVersionRecord)) or 0
            )
            assert count == 5
            event_types = set((await session.scalars(select(LedgerEventRecord.event_type))).all())
            assert "season.activated.v1" in event_types
            assert "season.revised.v1" in event_types
            assert "season.transitioned.v1" in event_types

    asyncio.run(verify_history())
