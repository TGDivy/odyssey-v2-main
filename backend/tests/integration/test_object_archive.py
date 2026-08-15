import asyncio
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path

import pytest

from odyssey.attachments.backups import (
    ObjectArchiveError,
    create_object_archive,
    load_object_archive_manifest,
    restore_object_archive,
    verify_object_archive,
    write_object_archive_manifest,
)
from odyssey.attachments.models import AttachmentObjectRecord
from odyssey.attachments.storage import LocalAttachmentStore
from odyssey.db.base import Base
from odyssey.db.session import Database

NOW = datetime(2026, 8, 15, 18, 0, tzinfo=UTC)


def test_object_archive_copies_verifies_and_restores(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'objects.sqlite'}")
        source = LocalAttachmentStore(tmp_path / "source")
        archive = LocalAttachmentStore(tmp_path / "archive")
        restored = LocalAttachmentStore(tmp_path / "restored")
        contents = (b"first durable object", b"second durable object")
        try:
            async with database.engine.begin() as connection:
                await connection.run_sync(Base.metadata.create_all)
            async with database.sessions() as session, session.begin():
                for content in contents:
                    content_hash = sha256(content).hexdigest()
                    stored = await source.write_object(content_hash, content)
                    session.add(
                        AttachmentObjectRecord(
                            content_sha256=content_hash,
                            byte_size=len(content),
                            storage_key=stored.storage_key,
                            storage_backend=stored.storage_backend,
                            bucket_name=stored.bucket_name,
                            object_version_id=stored.version_id,
                            verified_at=NOW,
                        )
                    )
            async with database.sessions() as session:
                envelope = await create_object_archive(
                    session,
                    source=source,
                    archive=archive,
                    created_at=NOW,
                )
            manifest_path = tmp_path / "object-manifest.json"
            write_object_archive_manifest(manifest_path, envelope)
            loaded = load_object_archive_manifest(manifest_path)
            verified = await verify_object_archive(
                archive=archive,
                envelope=loaded,
                verified_at=NOW,
            )
            async with database.sessions() as session:
                restore_report = await restore_object_archive(
                    session,
                    archive=archive,
                    destination=restored,
                    envelope=loaded,
                    restored_at=NOW,
                )

            assert envelope.manifest.object_count == 2
            assert envelope.manifest.total_bytes == sum(map(len, contents))
            assert verified.verified is True
            assert restore_report.operation == "restore"
            assert manifest_path.stat().st_mode & 0o777 == 0o600
            for content in contents:
                content_hash = sha256(content).hexdigest()
                assert await restored.read_object(content_hash) == content

            corrupted_entry = loaded.manifest.entries[0]
            corrupted_path = archive.root / corrupted_entry.archive_storage_key
            corrupted_path.write_bytes(b"corrupted archive object")
            with pytest.raises(ObjectArchiveError, match="failed size or hash"):
                await verify_object_archive(archive=archive, envelope=loaded)
        finally:
            await database.dispose()

    asyncio.run(scenario())
