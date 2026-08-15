import asyncio
import base64
import io
import zipfile
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from sqlalchemy import func, select

from odyssey.attachments.storage import LocalAttachmentStore
from odyssey.auth.persistence import (
    AuthDeviceRecord,
    DeviceCredentialRecord,
    OwnerIdentityRecord,
    OwnerRecoveryCredentialRecord,
)
from odyssey.config import Environment, Settings
from odyssey.db.base import Base
from odyssey.db.models import ImmutableLedgerMutationError, OutboxRecord
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.exports.persistence import ExportJobAuditRecord, ExportJobRecord
from odyssey.exports.verification import (
    OwnerExportVerificationError,
    extract_verified_export,
    verify_owner_export,
)
from odyssey.main import create_app
from odyssey.worker import run as run_worker

WRAPPING_KEY = "synthetic-export-wrapping-key-material-0001"
PASSPHRASE = "synthetic owner export passphrase"
ACCESS_TOKEN = "synthetic-access-token-that-must-never-export"
DEVICE_CREDENTIAL_HASH = sha256(b"synthetic-device-credential").hexdigest()
RECOVERY_CREDENTIAL_HASH = sha256(b"synthetic-recovery-credential").hexdigest()
APPLE_SUBJECT = "synthetic-apple-subject-that-must-not-export"


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


def export_settings(*, maximum_bytes: int = 8 * 1024 * 1024) -> Settings:
    return Settings(
        env=Environment.TEST,
        owner_export_enabled=True,
        export_wrapping_key=WRAPPING_KEY,
        maximum_export_bytes=maximum_bytes,
        attachment_chunk_bytes=128,
        maximum_attachment_bytes=1024,
    )


def export_body(*, formats: list[str] | None = None) -> dict[str, object]:
    return {
        "scope": "all_odyssey_owned_data",
        "formats": formats or ["jsonl", "csv", "markdown"],
        "include_raw_sources": True,
        "include_model_traces": False,
        "encryption": {"mode": "owner_passphrase"},
    }


def export_headers(*, passphrase: str = PASSPHRASE) -> dict[str, str]:
    return {
        "Idempotency-Key": "synthetic-owner-export",
        "X-Odyssey-Export-Passphrase": passphrase,
    }


async def seed_operational_credentials(database: Database) -> None:
    now = datetime(2026, 8, 15, 12, tzinfo=UTC)
    device_id = new_uuid7()
    async with database.sessions() as session, session.begin():
        session.add(
            OwnerIdentityRecord(
                owner_id="owner",
                apple_subject=APPLE_SUBJECT,
                created_at=now,
                last_authenticated_at=now,
            )
        )
        await session.flush()
        session.add(
            AuthDeviceRecord(
                id=device_id,
                owner_id="owner",
                display_name="Synthetic export device",
                platform="ios",
                app_version="1.0-test",
                status="active",
                enrolled_at=now,
                last_authenticated_at=now,
                last_seen_at=now,
            )
        )
        await session.flush()
        session.add_all(
            (
                DeviceCredentialRecord(
                    device_id=device_id,
                    credential_hash=DEVICE_CREDENTIAL_HASH,
                    issued_at=now,
                    expires_at=now + timedelta(days=30),
                ),
                OwnerRecoveryCredentialRecord(
                    id=new_uuid7(),
                    owner_id="owner",
                    credential_hash=RECOVERY_CREDENTIAL_HASH,
                    label="synthetic recovery credential",
                    created_at=now,
                    expires_at=now + timedelta(days=30),
                    created_by="tests",
                ),
            )
        )


def seed_owner_record(client: TestClient) -> None:
    now = datetime(2026, 8, 15, 12, tzinfo=UTC)
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
                    "entity_type": "owner_note",
                    "entity_id": str(new_uuid7()),
                    "mutation_type": "create",
                    "base_revision": None,
                    "payload": {
                        "title": "Expected portable owner note",
                        "access_token": ACCESS_TOKEN,
                        "nested": {"api_key": "synthetic-api-key-that-must-not-export"},
                    },
                    "created_at": now.isoformat(),
                }
            ],
        },
        headers={"Idempotency-Key": "seed-owner-export-record"},
    )
    assert response.status_code == 200


def upload_attachment(client: TestClient, content: bytes) -> object:
    attachment_id = new_uuid7()
    initialized = client.post(
        "/v1/attachments/uploads",
        json={
            "attachment_id": str(attachment_id),
            "content_sha256": sha256(content).hexdigest(),
            "byte_size": len(content),
            "media_type": "text/plain",
            "sensitivity_class": "private",
            "encryption_mode": "none",
            "encryption_metadata": {},
        },
    )
    assert initialized.status_code == 200
    uploaded = client.put(
        initialized.json()["signed_chunk_url_template"].format(chunk_index=0),
        content=content,
        headers={"X-Chunk-SHA256": sha256(content).hexdigest()},
    )
    assert uploaded.status_code == 200
    completed = client.post(f"/v1/attachments/uploads/{initialized.json()['upload_id']}/complete")
    assert completed.status_code == 200
    return attachment_id


def test_owner_export_is_idempotent_encrypted_verifiable_and_resumable(
    tmp_path: Path,
) -> None:
    database = prepare_database(tmp_path / "owner-export.sqlite")
    store = LocalAttachmentStore(tmp_path / "objects")
    settings = export_settings()
    asyncio.run(seed_operational_credentials(database))
    app = create_app(settings, database=database, attachment_store=store)
    attachment_content = b"synthetic raw owner attachment"

    with TestClient(app) as client:
        seed_owner_record(client)
        attachment_id = upload_attachment(client, attachment_content)
        created = client.post(
            "/v1/exports",
            json=export_body(),
            headers=export_headers(),
        )
        replay = client.post(
            "/v1/exports",
            json=export_body(),
            headers=export_headers(),
        )
        changed_request = client.post(
            "/v1/exports",
            json=export_body(formats=["jsonl"]),
            headers=export_headers(),
        )
        changed_passphrase = client.post(
            "/v1/exports",
            json=export_body(),
            headers=export_headers(passphrase="different synthetic owner passphrase"),
        )

        assert created.status_code == 202
        assert replay.status_code == 202
        assert replay.json() == created.json()
        assert changed_request.status_code == 409
        assert changed_request.json()["error"]["code"] == "EXPORT_IDEMPOTENCY_KEY_REUSED"
        assert changed_passphrase.status_code == 409
        assert changed_passphrase.json()["error"]["code"] == "EXPORT_IDEMPOTENCY_KEY_REUSED"

        asyncio.run(
            run_worker(
                once=True,
                settings=settings,
                database=database,
                attachment_store=store,
            )
        )
        status = client.get(created.json()["status_url"])
        assert status.status_code == 200
        assert status.json()["status"] == "completed"
        assert status.json()["attempts"] == 1
        assert status.json()["download_url"]
        artifact_response = client.get(status.json()["download_url"])
        first_range = client.get(status.json()["download_url"], headers={"Range": "bytes=0-63"})
        suffix_range = client.get(status.json()["download_url"], headers={"Range": "bytes=-32"})
        invalid_range = client.get(
            status.json()["download_url"], headers={"Range": "bytes=999999999-"}
        )

    assert artifact_response.status_code == 200
    assert artifact_response.headers["accept-ranges"] == "bytes"
    assert artifact_response.headers["cache-control"] == "private, no-store"
    assert first_range.status_code == 206
    assert first_range.content == artifact_response.content[:64]
    assert suffix_range.status_code == 206
    assert suffix_range.content == artifact_response.content[-32:]
    assert invalid_range.status_code == 416
    assert invalid_range.headers["content-range"] == f"bytes */{len(artifact_response.content)}"

    expected_public_key = base64.b64decode(status.json()["signing_public_key"], validate=True)
    verified = verify_owner_export(
        artifact_response.content,
        passphrase=PASSPHRASE,
        expected_signing_public_key=expected_public_key,
    )
    assert verified.header["manifest_sha256"] == status.json()["manifest_sha256"]
    security = verified.manifest["security"]
    assert security["credential_material_included"] is False
    assert security["worker_key_envelope_included"] is False
    assert security["operational_secrets_included"] is False
    assert security["csv_formula_prefixes_escaped"] is True
    assert security["nested_sensitive_fields_redacted"] >= 6
    excluded_tables = {entry["table"] for entry in verified.manifest["excluded_datasets"]}
    assert {
        "auth_device_credentials",
        "owner_recovery_credentials",
        "apple_auth_challenges",
        "outbox_records",
    }.issubset(excluded_tables)

    with zipfile.ZipFile(io.BytesIO(verified.decrypted_zip)) as archive:
        extracted_content = b"\n".join(archive.read(path) for path in verified.verified_paths)
        attachment_path = f"attachments/objects/{sha256(attachment_content).hexdigest()}"
        assert archive.read(attachment_path) == attachment_content
        attachment_manifest = next(
            item
            for item in verified.manifest["attachments"]
            if item["attachment_id"] == str(attachment_id)
        )
        assert attachment_manifest["path"] == attachment_path
    assert b"Expected portable owner note" in extracted_content
    assert b"[redacted: operational secret]" in extracted_content
    for secret in (
        ACCESS_TOKEN,
        "synthetic-api-key-that-must-not-export",
        DEVICE_CREDENTIAL_HASH,
        RECOVERY_CREDENTIAL_HASH,
        APPLE_SUBJECT,
        WRAPPING_KEY,
    ):
        assert secret.encode() not in extracted_content
    export_job_dataset = next(
        dataset for dataset in verified.manifest["datasets"] if dataset["table"] == "export_jobs"
    )
    exported_job_columns = {column["name"] for column in export_job_dataset["columns"]}
    assert "worker_key_envelope" not in exported_job_columns
    assert "owner_key_envelope" not in exported_job_columns

    output_directory = tmp_path / "verified-export"
    extract_verified_export(verified, output_directory)
    assert (output_directory / attachment_path).read_bytes() == attachment_content
    with pytest.raises(OwnerExportVerificationError, match="pinned key"):
        verify_owner_export(
            artifact_response.content,
            passphrase=PASSPHRASE,
            expected_signing_public_key=b"x" * 32,
        )
    with pytest.raises(OwnerExportVerificationError):
        verify_owner_export(artifact_response.content, passphrase="wrong owner passphrase")

    async def verify_durability() -> None:
        async with database.sessions() as session:
            job_count = int(
                await session.scalar(select(func.count()).select_from(ExportJobRecord)) or 0
            )
            outbox_count = int(
                await session.scalar(
                    select(func.count())
                    .select_from(OutboxRecord)
                    .where(OutboxRecord.topic == "owner-export")
                )
                or 0
            )
            audits = tuple(
                (
                    await session.scalars(
                        select(ExportJobAuditRecord).order_by(ExportJobAuditRecord.sequence)
                    )
                ).all()
            )
        assert job_count == 1
        assert outbox_count == 1
        assert [audit.event_type for audit in audits] == [
            "queued",
            "processing_started",
            "completed",
        ]
        async with database.sessions() as session:
            stored_audit = await session.get(ExportJobAuditRecord, audits[0].sequence)
            assert stored_audit is not None
            stored_audit.details = {"changed": True}
            with pytest.raises(ImmutableLedgerMutationError, match="append-only"):
                await session.commit()
            await session.rollback()
        await database.dispose()

    asyncio.run(verify_durability())


def test_owner_export_gate_and_terminal_size_limit(tmp_path: Path) -> None:
    disabled_app = create_app(Settings(env=Environment.TEST))
    with TestClient(disabled_app) as client:
        disabled = client.post(
            "/v1/exports",
            json=export_body(),
            headers=export_headers(),
        )
    assert disabled.status_code == 503
    assert disabled.json()["error"]["code"] == "OWNER_EXPORT_DISABLED"
    with pytest.raises(ValidationError, match="wrapping key"):
        Settings(env=Environment.TEST, owner_export_enabled=True)

    database = prepare_database(tmp_path / "owner-export-size.sqlite")
    store = LocalAttachmentStore(tmp_path / "small-objects")
    settings = export_settings(maximum_bytes=2048)
    app = create_app(settings, database=database, attachment_store=store)
    with TestClient(app) as client:
        created = client.post(
            "/v1/exports",
            json=export_body(),
            headers=export_headers(),
        )
        assert created.status_code == 202
        asyncio.run(
            run_worker(
                once=True,
                settings=settings,
                database=database,
                attachment_store=store,
            )
        )
        status = client.get(created.json()["status_url"])
        download = client.get(f"{created.json()['status_url']}/download")
    assert status.status_code == 200
    assert status.json()["status"] == "failed"
    assert status.json()["last_error_code"] == "EXPORT_SIZE_LIMIT_EXCEEDED"
    assert status.json()["download_url"] is None
    assert download.status_code == 409
    assert download.json()["error"]["code"] == "EXPORT_FAILED"

    async def verify_terminal_state() -> None:
        async with database.sessions() as session:
            outbox = await session.scalar(
                select(OutboxRecord).where(OutboxRecord.topic == "owner-export")
            )
            audits = tuple(
                (
                    await session.scalars(
                        select(ExportJobAuditRecord).order_by(ExportJobAuditRecord.sequence)
                    )
                ).all()
            )
        assert outbox is not None
        assert outbox.status == "completed"
        assert [audit.event_type for audit in audits] == [
            "queued",
            "processing_started",
            "failed",
        ]
        await database.dispose()

    asyncio.run(verify_terminal_state())
