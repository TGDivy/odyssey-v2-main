import asyncio
import json
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config

from odyssey.attachments.models import AttachmentObjectRecord
from odyssey.attachments.storage import LocalAttachmentStore
from odyssey.backups.cloud import (
    BackupObjectReference,
    CloudBackupEnvelope,
    LogicalDump,
    complete_cloud_backup,
)
from odyssey.db.session import Database


class MemoryBackupStore:
    bucket_name = "synthetic-database-backups"

    def __init__(self) -> None:
        self.validated = False
        self.objects: dict[str, bytes] = {}

    async def validate_configuration(self) -> None:
        self.validated = True

    async def write_file(
        self,
        storage_key: str,
        path: Path,
        *,
        retention_tier: str,
        content_sha256: str,
    ) -> BackupObjectReference:
        return await self.write_bytes(
            storage_key,
            await asyncio.to_thread(path.read_bytes),
            retention_tier=retention_tier,
            content_sha256=content_sha256,
        )

    async def write_bytes(
        self,
        storage_key: str,
        content: bytes,
        *,
        retention_tier: str,
        content_sha256: str,
    ) -> BackupObjectReference:
        assert sha256(content).hexdigest() == content_sha256
        self.objects.setdefault(storage_key, content)
        assert self.objects[storage_key] == content
        return BackupObjectReference(
            retention_tier=retention_tier,
            bucket_name=self.bucket_name,
            storage_key=storage_key,
            generation="1",
            content_sha256=content_sha256,
            byte_size=len(content),
        )


def test_cloud_backup_combines_database_and_verified_object_archive(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database_path = tmp_path / "source.sqlite"
    database_url = f"sqlite+aiosqlite:///{database_path}"
    monkeypatch.setenv("ODYSSEY_DATABASE_URL", database_url)
    command.upgrade(Config("alembic.ini"), "head")
    database = Database(database_url)
    source_objects = LocalAttachmentStore(tmp_path / "source-objects")
    archive_objects = LocalAttachmentStore(tmp_path / "archive-objects")
    database_backups = MemoryBackupStore()
    dump_content = b"synthetic PostgreSQL dump fixture"
    dump_path = tmp_path / "database.dump"
    dump_path.write_bytes(dump_content)
    created_at = datetime(2026, 1, 1, tzinfo=UTC)
    attachment_content = b"synthetic attachment fixture"
    attachment_hash = sha256(attachment_content).hexdigest()

    async def scenario() -> None:
        stored = await source_objects.write_object(attachment_hash, attachment_content)
        async with database.sessions() as session, session.begin():
            session.add(
                AttachmentObjectRecord(
                    content_sha256=attachment_hash,
                    byte_size=len(attachment_content),
                    storage_key=stored.storage_key,
                    storage_backend=stored.storage_backend,
                    bucket_name=stored.bucket_name,
                    object_version_id=stored.version_id,
                    verified_at=created_at,
                )
            )
        report = await complete_cloud_backup(
            logical_dump=LogicalDump(
                path=dump_path,
                content_sha256=sha256(dump_content).hexdigest(),
                byte_size=len(dump_content),
                catalog_sha256=sha256(b"synthetic catalog").hexdigest(),
            ),
            database=database,
            source_objects=source_objects,
            archive_objects=archive_objects,
            database_backups=database_backups,
            created_at=created_at,
            execution_id="synthetic-cloud-run-execution",
            commit_sha="a" * 40,
        )

        assert database_backups.validated is True
        assert report.status == "verified"
        assert report.database_object_count == 3
        assert report.object_archive_count == 1
        assert report.object_archive_bytes == len(attachment_content)
        assert len(report.manifest_objects) == 3
        assert len(report.report_sha256) == 64
        manifest_content = database_backups.objects[report.manifest_objects[0].storage_key]
        envelope = CloudBackupEnvelope.model_validate_json(manifest_content)
        assert envelope.manifest_sha256 == report.manifest_sha256
        assert envelope.manifest.database_schema_revision == "20260815_0016"
        assert [item.retention_tier for item in envelope.manifest.database_objects] == [
            "daily",
            "monthly",
            "annual",
        ]
        assert attachment_hash not in json.dumps(report.model_dump(mode="json"))
        assert await archive_objects.read_object(attachment_hash) == attachment_content
        await database.dispose()

    asyncio.run(scenario())
