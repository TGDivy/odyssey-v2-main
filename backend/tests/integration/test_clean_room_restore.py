import asyncio
import json
import sqlite3
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config

from odyssey.attachments.backups import create_object_archive
from odyssey.attachments.models import AttachmentObjectRecord
from odyssey.attachments.storage import LocalAttachmentStore
from odyssey.config import get_settings
from odyssey.db.backups import create_database_backup
from odyssey.db.restores import RestoreError, clean_room_restore
from odyssey.db.session import Database


def test_clean_room_restore_applies_migrations_and_validates_integrity(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source_path = tmp_path / "source.sqlite"
    source_url = f"sqlite+aiosqlite:///{source_path}"
    monkeypatch.setenv("ODYSSEY_DATABASE_URL", source_url)
    get_settings.cache_clear()
    configuration = Config("alembic.ini")
    command.upgrade(configuration, "head")

    source = sqlite3.connect(source_path)
    source.execute(
        """
        INSERT INTO kill_switches (key, enabled, reason, updated_by)
        VALUES ('restore-test', 1, 'synthetic clean-room drill', 'tests')
        """
    )
    source.commit()
    source.close()
    backup_path = tmp_path / "backup"
    create_database_backup(source_url, destination=backup_path, allow_plaintext=True)

    restored_path = tmp_path / "restored.sqlite"
    restored_url = f"sqlite+aiosqlite:///{restored_path}"
    report_path = tmp_path / "restore-report.json"
    report = clean_room_restore(
        restored_url,
        backup=backup_path,
        alembic_ini=Path("alembic.ini"),
        report_path=report_path,
        generated_at=datetime(2026, 8, 15, tzinfo=UTC),
    )
    assert report.recovery_validation == "passed"
    assert report.integrity.healthy is True
    assert report.backup_count_validation == "passed"
    assert report.backup_count_mismatches == {}
    assert report.restored_schema_revision == "20260815_0018"
    assert report.integrity.table_counts["kill_switches"] == 1
    assert report_path.stat().st_mode & 0o777 == 0o600
    assert json.loads(report_path.read_text())["generated_at"] == "2026-08-15T00:00:00Z"

    restored = sqlite3.connect(restored_path)
    assert restored.execute("SELECT enabled FROM kill_switches").fetchone() == (1,)
    restored.close()

    with pytest.raises(RestoreError, match="already exists"):
        clean_room_restore(
            restored_url,
            backup=backup_path,
            alembic_ini=Path("alembic.ini"),
            report_path=tmp_path / "second-report.json",
        )
    get_settings.cache_clear()


def test_clean_room_restore_includes_verified_object_archive(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source_path = tmp_path / "object-source.sqlite"
    source_url = f"sqlite+aiosqlite:///{source_path}"
    monkeypatch.setenv("ODYSSEY_DATABASE_URL", source_url)
    get_settings.cache_clear()
    command.upgrade(Config("alembic.ini"), "head")
    source_store = LocalAttachmentStore(tmp_path / "source-objects")
    archive_store = LocalAttachmentStore(tmp_path / "archive-objects")
    restored_store = LocalAttachmentStore(tmp_path / "restored-objects")
    content = b"synthetic clean-room attachment"
    content_hash = sha256(content).hexdigest()

    async def prepare_objects() -> object:
        database = Database(source_url)
        try:
            stored = await source_store.write_object(content_hash, content)
            async with database.sessions() as session, session.begin():
                session.add(
                    AttachmentObjectRecord(
                        content_sha256=content_hash,
                        byte_size=len(content),
                        storage_key=stored.storage_key,
                        storage_backend=stored.storage_backend,
                        bucket_name=stored.bucket_name,
                        object_version_id=stored.version_id,
                        verified_at=datetime(2026, 8, 15, tzinfo=UTC),
                    )
                )
            async with database.sessions() as session:
                return await create_object_archive(
                    session,
                    source=source_store,
                    archive=archive_store,
                    created_at=datetime(2026, 8, 15, tzinfo=UTC),
                )
        finally:
            await database.dispose()

    envelope = asyncio.run(prepare_objects())
    backup_path = tmp_path / "object-database-backup"
    create_database_backup(source_url, destination=backup_path, allow_plaintext=True)
    restored_path = tmp_path / "object-restored.sqlite"
    report = clean_room_restore(
        f"sqlite+aiosqlite:///{restored_path}",
        backup=backup_path,
        alembic_ini=Path("alembic.ini"),
        report_path=tmp_path / "object-restore-report.json",
        generated_at=datetime(2026, 8, 15, tzinfo=UTC),
        object_archive=archive_store,
        object_destination=restored_store,
        object_envelope=envelope,
    )

    assert report.object_restore == "passed"
    assert report.object_manifest_sha256 == envelope.manifest_sha256
    assert report.object_count == 1
    assert asyncio.run(restored_store.read_object(content_hash)) == content
    get_settings.cache_clear()
