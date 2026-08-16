"""Signed database-backed feature configuration API regressions."""

import asyncio
import base64
from datetime import UTC, datetime, timedelta
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from odyssey.config import Environment, Settings
from odyssey.db import Base, Database
from odyssey.domain.common import new_uuid7
from odyssey.main import create_app
from odyssey.telemetry.feature_flags import (
    FeatureConfigurationSigner,
    verified_feature_payload,
)
from odyssey.telemetry.models import FeatureConfigurationEnvelope
from odyssey.telemetry.persistence import FeatureConfigurationRecord

PRIVATE_KEY_BASE64 = base64.b64encode(bytes(range(1, 33))).decode()
AUDIENCE = "com.example.odyssey.app"


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


def configuration_body(configuration_id: object, *, expected_version: int = 0) -> dict[str, object]:
    return {
        "configuration_id": str(configuration_id),
        "expected_current_version": expected_version,
        "audience": AUDIENCE,
        "expires_at": (datetime.now(UTC) + timedelta(days=7)).isoformat(),
        "flags": [
            {
                "key": "intervention.proactive_notifications",
                "variant": "enabled",
                "rollout_basis_points": 10_000,
                "assignment_salt": "synthetic-api-1",
            }
        ],
        "reason": "Synthetic owner-approved bounded rollout.",
    }


def test_owner_publishes_idempotent_signed_configuration_and_reads_current(
    tmp_path: Path,
) -> None:
    database = prepare_database(tmp_path / "feature-config.sqlite")
    signer = FeatureConfigurationSigner(
        key_id="synthetic-key-1",
        private_key_base64=PRIVATE_KEY_BASE64,
    )
    app = create_app(
        Settings(env=Environment.TEST),
        database=database,
        feature_configuration_signer=signer,
    )
    configuration_id = new_uuid7()
    body = configuration_body(configuration_id)

    with TestClient(app) as client:
        unavailable = client.get(
            "/v1/product/feature-configuration",
            params={"audience": AUDIENCE},
        )
        first = client.post("/v1/product/feature-configurations", json=body)
        retry = client.post("/v1/product/feature-configurations", json=body)
        current = client.get(
            "/v1/product/feature-configuration",
            params={"audience": AUDIENCE},
        )

    assert unavailable.status_code == 404
    assert first.status_code == 200
    assert first.json()["created"] is True
    assert first.json()["version"] == 1
    assert retry.status_code == 200
    assert retry.json()["created"] is False
    assert retry.json()["envelope"] == first.json()["envelope"]
    assert current.status_code == 200
    assert current.json() == first.json()["envelope"]

    envelope = FeatureConfigurationEnvelope.model_validate(current.json())
    payload = verified_feature_payload(
        envelope,
        public_key_base64=signer.public_key_base64,
        expected_key_id="synthetic-key-1",
    )
    assert payload.configuration_id == configuration_id
    assert payload.version == 1
    assert payload.environment == "test"
    assert payload.audience == AUDIENCE

    async def count_records() -> int:
        async with database.sessions() as session:
            return int(
                await session.scalar(select(func.count()).select_from(FeatureConfigurationRecord))
                or 0
            )

    assert asyncio.run(count_records()) == 1


def test_publication_rejects_reuse_stale_version_and_missing_signer(tmp_path: Path) -> None:
    signer = FeatureConfigurationSigner(
        key_id="synthetic-key-1",
        private_key_base64=PRIVATE_KEY_BASE64,
    )
    database = prepare_database(tmp_path / "feature-conflicts.sqlite")
    app = create_app(
        Settings(env=Environment.TEST),
        database=database,
        feature_configuration_signer=signer,
    )
    configuration_id = new_uuid7()
    body = configuration_body(configuration_id)

    with TestClient(app) as client:
        assert client.post("/v1/product/feature-configurations", json=body).status_code == 200
        changed = {**body, "reason": "Different meaning."}
        reused = client.post("/v1/product/feature-configurations", json=changed)
        stale = client.post(
            "/v1/product/feature-configurations",
            json=configuration_body(new_uuid7(), expected_version=0),
        )

    assert reused.status_code == 409
    assert reused.json()["error"]["code"] == "FEATURE_CONFIGURATION_ID_REUSED"
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "FEATURE_CONFIGURATION_VERSION_CONFLICT"

    unsigned_database = prepare_database(tmp_path / "feature-unsigned.sqlite")
    unsigned_app = create_app(Settings(env=Environment.TEST), database=unsigned_database)
    with TestClient(unsigned_app) as client:
        unsigned = client.post(
            "/v1/product/feature-configurations",
            json=configuration_body(new_uuid7()),
        )

    assert unsigned.status_code == 503
    assert unsigned.json()["error"]["code"] == "FEATURE_CONFIGURATION_SIGNING_UNAVAILABLE"
