import asyncio
from hashlib import sha256
from pathlib import Path
from typing import cast

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from odyssey.attachments.models import (
    AttachmentChunkRecord,
    AttachmentObjectRecord,
    AttachmentRecord,
    AttachmentUploadRecord,
)
from odyssey.attachments.service import UploadTokenSigner
from odyssey.attachments.storage import LocalAttachmentStore
from odyssey.config import Environment, Settings
from odyssey.db.base import Base
from odyssey.db.models import OutboxRecord
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.main import create_app


def prepare_database(path: Path) -> Database:
    database = Database(f"sqlite+aiosqlite:///{path}")

    async def create_schema() -> None:
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(create_schema())
    return database


def upload_body(
    attachment_id: object, content: bytes, *, claimed_hash: str | None = None
) -> dict[str, object]:
    return {
        "attachment_id": str(attachment_id),
        "content_sha256": claimed_hash or sha256(content).hexdigest(),
        "byte_size": len(content),
        "media_type": "application/octet-stream",
        "sensitivity_class": "sensitive",
        "encryption_mode": "client_side",
        "encryption_metadata": {
            "algorithm": "synthetic-aes-256-gcm",
            "key_reference": "device-keychain:synthetic",
        },
    }


def test_resumable_attachment_upload_replay_and_content_deduplication(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "attachment.sqlite")
    store = LocalAttachmentStore(tmp_path / "objects")
    signer = UploadTokenSigner(b"synthetic-test-signing-key")
    settings = Settings(
        env=Environment.TEST,
        attachment_chunk_bytes=8,
        maximum_attachment_bytes=1024,
    )
    app = create_app(
        settings,
        database=database,
        attachment_store=store,
        upload_token_signer=signer,
    )
    content = b"encrypted-object-bytes"
    attachment_id = new_uuid7()
    body = upload_body(attachment_id, content)

    with TestClient(app) as client:
        initialized = client.post("/v1/attachments/uploads", json=body)
        assert initialized.status_code == 200
        template = initialized.json()["signed_chunk_url_template"]
        first_chunk_url = template.format(chunk_index=0)
        first_chunk = content[:8]
        first = client.put(
            first_chunk_url,
            content=first_chunk,
            headers={"X-Chunk-SHA256": sha256(first_chunk).hexdigest()},
        )
        replay = client.put(
            first_chunk_url,
            content=first_chunk,
            headers={"X-Chunk-SHA256": sha256(first_chunk).hexdigest()},
        )
        assert first.status_code == 200
        assert first.json()["created"] is True
        assert replay.status_code == 200
        assert replay.json()["created"] is False

    resumed_app = create_app(
        settings,
        database=database,
        attachment_store=store,
        upload_token_signer=UploadTokenSigner(b"replacement-process-signing-key"),
    )
    with TestClient(resumed_app) as client:
        resumed = client.post("/v1/attachments/uploads", json=body)
        assert resumed.status_code == 200
        assert resumed.json()["upload_id"] == initialized.json()["upload_id"]
        template = resumed.json()["signed_chunk_url_template"]
        incomplete = client.post(f"/v1/attachments/uploads/{resumed.json()['upload_id']}/complete")
        assert incomplete.status_code == 422
        assert incomplete.json()["error"]["code"] == "ATTACHMENT_UPLOAD_INCOMPLETE"
        chunks = (content[8:16], content[16:])
        for chunk_index, chunk in enumerate(chunks, start=1):
            response = client.put(
                template.format(chunk_index=chunk_index),
                content=chunk,
                headers={"X-Chunk-SHA256": sha256(chunk).hexdigest()},
            )
            assert response.status_code == 200
            assert response.json()["created"] is True
        completed = client.post(f"/v1/attachments/uploads/{resumed.json()['upload_id']}/complete")
        completed_replay = client.post(
            f"/v1/attachments/uploads/{resumed.json()['upload_id']}/complete"
        )
        status = client.get(f"/v1/attachments/{attachment_id}")
        duplicate_body = upload_body(new_uuid7(), content)
        duplicate = client.post("/v1/attachments/uploads", json=duplicate_body)

    assert completed.status_code == 200
    assert completed.json()["object_ref"] == f"sha256:{sha256(content).hexdigest()}"
    assert completed_replay.json() == completed.json()
    assert status.status_code == 200
    assert status.json()["status"] == "available"
    assert duplicate.status_code == 200
    assert duplicate.json()["status"] == "available"
    assert duplicate.json()["deduplicated"] is True
    assert duplicate.json()["upload_id"] is None
    assert asyncio.run(store.read_object(sha256(content).hexdigest())) == content

    async def database_counts() -> tuple[int, int, int, int, int]:
        async with database.sessions() as session:
            values = []
            for model in (
                AttachmentRecord,
                AttachmentUploadRecord,
                AttachmentChunkRecord,
                AttachmentObjectRecord,
                OutboxRecord,
            ):
                count = await session.scalar(select(func.count()).select_from(model))
                values.append(int(count or 0))
            return cast(tuple[int, int, int, int, int], tuple(values))

    assert asyncio.run(database_counts()) == (2, 1, 3, 1, 1)


def test_attachment_tokens_and_checksums_fail_closed(tmp_path: Path) -> None:
    database = prepare_database(tmp_path / "attachment-errors.sqlite")
    store = LocalAttachmentStore(tmp_path / "error-objects")
    settings = Settings(
        env=Environment.TEST,
        attachment_chunk_bytes=64,
        maximum_attachment_bytes=1024,
    )
    app = create_app(
        settings,
        database=database,
        attachment_store=store,
        upload_token_signer=UploadTokenSigner(b"synthetic-error-signing-key"),
    )
    content = b"synthetic attachment"
    claimed_hash = sha256(b"different attachment").hexdigest()
    body = upload_body(new_uuid7(), content, claimed_hash=claimed_hash)

    with TestClient(app) as client:
        initialized = client.post("/v1/attachments/uploads", json=body)
        template = initialized.json()["signed_chunk_url_template"]
        invalid_token_url = (
            template.format(chunk_index=0).split("?", maxsplit=1)[0]
            + "?token=invalid-token-value-that-is-long-enough"
        )
        invalid_token = client.put(
            invalid_token_url,
            content=content,
            headers={"X-Chunk-SHA256": sha256(content).hexdigest()},
        )
        wrong_chunk_hash = client.put(
            template.format(chunk_index=0),
            content=content,
            headers={"X-Chunk-SHA256": "0" * 64},
        )
        uploaded = client.put(
            template.format(chunk_index=0),
            content=content,
            headers={"X-Chunk-SHA256": sha256(content).hexdigest()},
        )
        completion = client.post(
            f"/v1/attachments/uploads/{initialized.json()['upload_id']}/complete"
        )

    assert invalid_token.status_code == 401
    assert invalid_token.json()["error"]["code"] == "ATTACHMENT_UPLOAD_TOKEN_INVALID"
    assert wrong_chunk_hash.status_code == 422
    assert wrong_chunk_hash.json()["error"]["code"] == "ATTACHMENT_CHUNK_CHECKSUM_MISMATCH"
    assert uploaded.status_code == 200
    assert completion.status_code == 422
    assert completion.json()["error"]["code"] == "ATTACHMENT_CHECKSUM_MISMATCH"

    async def object_count() -> int:
        async with database.sessions() as session:
            value = await session.scalar(select(func.count()).select_from(AttachmentObjectRecord))
            return int(value or 0)

    assert asyncio.run(object_count()) == 0
