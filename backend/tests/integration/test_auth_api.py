import asyncio
from datetime import datetime, timedelta
from pathlib import Path
from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from odyssey.auth.apple import AppleIdentity, AppleIdentityTokenError, AppleIdentityVerifier
from odyssey.auth.persistence import (
    AppleAuthChallengeRecord,
    AuthDeviceAuditRecord,
    AuthDeviceRecord,
    DeviceCredentialRecord,
    OwnerIdentityRecord,
)
from odyssey.config import AuthMode, Environment, Settings
from odyssey.db.base import Base
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.main import create_app

ALLOWED_SUBJECT = "000999.synthetic-owner"
IDENTITY_TOKEN = "synthetic-apple-identity-token-" + ("x" * 120)


class FixtureAppleVerifier(AppleIdentityVerifier):
    def __init__(self, subject: str = ALLOWED_SUBJECT) -> None:
        self.subject = subject
        self.calls = 0

    async def verify(
        self,
        identity_token: str,
        *,
        raw_nonce: str,
        now: datetime,
    ) -> AppleIdentity:
        self.calls += 1
        if not identity_token.startswith("synthetic-apple-identity-token-") or len(raw_nonce) < 32:
            raise AppleIdentityTokenError("Apple identity token is invalid")
        return AppleIdentity(
            subject=self.subject,
            issued_at=now,
            expires_at=now + timedelta(minutes=5),
        )


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


def auth_settings() -> Settings:
    return Settings(
        env=Environment.TEST,
        auth_mode=AuthMode.SIGN_IN_WITH_APPLE,
        apple_client_id="com.example.odyssey",
        apple_bootstrap_subject=ALLOWED_SUBJECT,
        auth_access_token_signing_key="synthetic-signing-key-at-least-32-bytes-long",
    )


def enroll_device(
    client: TestClient,
    *,
    device_id: str,
    display_name: str,
    identity_token: str = IDENTITY_TOKEN,
) -> tuple[dict[str, object], dict[str, object]]:
    challenge = client.post("/v1/auth/apple/challenges", json={"device_id": device_id})
    assert challenge.status_code == 200
    challenge_body = challenge.json()
    request = {
        "challenge_id": challenge_body["challenge_id"],
        "device_id": device_id,
        "nonce": challenge_body["nonce"],
        "identity_token": identity_token,
        "display_name": display_name,
        "platform": "ios",
        "app_version": "1.0-test",
    }
    exchange = client.post("/v1/auth/apple/exchange", json=request)
    assert exchange.status_code == 200
    return request, exchange.json()


def test_enrollment_refresh_listing_and_revocation_are_device_bound(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "auth-api.sqlite")
    verifier = FixtureAppleVerifier()
    app = create_app(
        auth_settings(),
        database=database,
        apple_identity_verifier=verifier,
    )
    first_device = str(new_uuid7())
    second_device = str(new_uuid7())

    with TestClient(app) as client:
        _first_request, first = enroll_device(
            client,
            device_id=first_device,
            display_name="Synthetic iPhone",
        )
        first_headers = {"Authorization": f"Bearer {first['access_token']}"}
        listed = client.get("/v1/auth/devices", headers=first_headers)
        assert listed.status_code == 200
        assert [device["device_id"] for device in listed.json()["devices"]] == [first_device]

        refreshed = client.post(
            "/v1/auth/token/refresh",
            json={
                "device_id": first_device,
                "refresh_credential": first["refresh_credential"],
            },
        )
        assert refreshed.status_code == 200
        mismatched = client.get(
            "/v1/sync/changes",
            headers={
                "Authorization": f"Bearer {refreshed.json()['access_token']}",
                "X-Odyssey-Device-ID": second_device,
            },
        )
        assert mismatched.status_code == 403
        assert mismatched.json()["error"]["code"] == "DEVICE_ID_MISMATCH"

        _second_request, second = enroll_device(
            client,
            device_id=second_device,
            display_name="Synthetic iPad",
        )
        second_headers = {"Authorization": f"Bearer {second['access_token']}"}
        assert client.get("/v1/auth/devices", headers=second_headers).status_code == 200

        revoked = client.post(
            f"/v1/auth/devices/{second_device}/revoke",
            json={"reason": "lost"},
            headers=first_headers,
        )
        repeated = client.post(
            f"/v1/auth/devices/{second_device}/revoke",
            json={"reason": "lost"},
            headers=first_headers,
        )
        assert revoked.status_code == 200
        assert repeated.status_code == 200
        assert revoked.json()["status"] == "revoked"
        assert client.get("/v1/auth/devices", headers=second_headers).status_code == 401
        denied_refresh = client.post(
            "/v1/auth/token/refresh",
            json={
                "device_id": second_device,
                "refresh_credential": second["refresh_credential"],
            },
        )
        assert denied_refresh.status_code == 401

    async def assert_persistence() -> None:
        async with database.sessions() as session:
            identity = await session.get(OwnerIdentityRecord, "owner")
            credentials = tuple((await session.scalars(select(DeviceCredentialRecord))).all())
            challenges = tuple((await session.scalars(select(AppleAuthChallengeRecord))).all())
            audit_count = int(
                await session.scalar(select(func.count()).select_from(AuthDeviceAuditRecord)) or 0
            )
            second_record = await session.get(AuthDeviceRecord, UUID(second_device))
        assert identity is not None
        assert identity.apple_subject == ALLOWED_SUBJECT
        assert all(len(credential.credential_hash) == 64 for credential in credentials)
        assert first["refresh_credential"] not in {item.credential_hash for item in credentials}
        assert all(challenge.identity_token_hash != IDENTITY_TOKEN for challenge in challenges)
        assert audit_count == 3
        assert second_record is not None
        assert second_record.status == "revoked"
        await database.dispose()

    asyncio.run(assert_persistence())


def test_exchange_retry_is_recoverable_and_rejects_different_token(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "auth-replay.sqlite")
    app = create_app(
        auth_settings(),
        database=database,
        apple_identity_verifier=FixtureAppleVerifier(),
    )
    device_id = str(new_uuid7())

    with TestClient(app) as client:
        request, first = enroll_device(
            client,
            device_id=device_id,
            display_name="Synthetic iPhone",
        )
        replay = client.post("/v1/auth/apple/exchange", json=request)
        assert replay.status_code == 200
        second = replay.json()
        assert second["refresh_credential"] != first["refresh_credential"]
        old_refresh = client.post(
            "/v1/auth/token/refresh",
            json={
                "device_id": device_id,
                "refresh_credential": first["refresh_credential"],
            },
        )
        new_refresh = client.post(
            "/v1/auth/token/refresh",
            json={
                "device_id": device_id,
                "refresh_credential": second["refresh_credential"],
            },
        )
        assert old_refresh.status_code == 401
        assert new_refresh.status_code == 200

        changed_request = dict(request)
        changed_request["identity_token"] = IDENTITY_TOKEN + "different"
        changed = client.post("/v1/auth/apple/exchange", json=changed_request)
        assert changed.status_code == 401

    asyncio.run(database.dispose())


def test_bootstrap_subject_and_missing_configuration_fail_closed(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "auth-bootstrap.sqlite")
    wrong_subject_app = create_app(
        auth_settings(),
        database=database,
        apple_identity_verifier=FixtureAppleVerifier("000999.different-owner"),
    )
    device_id = str(new_uuid7())
    with TestClient(wrong_subject_app) as client:
        challenge = client.post("/v1/auth/apple/challenges", json={"device_id": device_id})
        body = challenge.json()
        denied = client.post(
            "/v1/auth/apple/exchange",
            json={
                "challenge_id": body["challenge_id"],
                "device_id": device_id,
                "nonce": body["nonce"],
                "identity_token": IDENTITY_TOKEN,
                "display_name": "Synthetic iPhone",
                "platform": "ios",
                "app_version": "1.0-test",
            },
        )
        assert denied.status_code == 403
        assert denied.json()["error"]["code"] == "OWNER_IDENTITY_NOT_ALLOWED"

    missing_configuration = create_app(
        Settings(env=Environment.TEST, auth_mode=AuthMode.SIGN_IN_WITH_APPLE),
        database=database,
    )
    with TestClient(missing_configuration) as client:
        unavailable = client.post(
            "/v1/auth/apple/challenges",
            json={"device_id": str(new_uuid7())},
        )
        protected = client.get("/v1/admin/diagnostics")
    assert unavailable.status_code == 503
    assert unavailable.json()["error"]["code"] == "AUTH_CONFIGURATION_UNAVAILABLE"
    assert protected.status_code == 401
    asyncio.run(database.dispose())
