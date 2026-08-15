import sqlite3
from datetime import UTC, datetime
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config

from odyssey.config import get_settings
from odyssey.db.backups import BackupError, create_database_backup, verify_database_backup


def test_sqlite_backup_is_online_private_and_verifiable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database_path = tmp_path / "source.sqlite"
    database_url = f"sqlite+aiosqlite:///{database_path}"
    monkeypatch.setenv("ODYSSEY_DATABASE_URL", database_url)
    get_settings.cache_clear()
    command.upgrade(Config("alembic.ini"), "head")

    source = sqlite3.connect(database_path)
    source.execute(
        """
        INSERT INTO kill_switches (key, enabled, reason, updated_by)
        VALUES ('test-switch', 0, 'synthetic backup test', 'tests')
        """
    )
    source.commit()

    destination = tmp_path / "backup"
    report = create_database_backup(
        database_url,
        destination=destination,
        created_at=datetime(2026, 8, 15, tzinfo=UTC),
        allow_plaintext=True,
    )
    assert report.artifact_verified is True
    assert report.schema_revision == "20260815_0006"
    assert report.artifact.sha256
    assert (destination / "database.sqlite3").stat().st_mode & 0o777 == 0o600

    source.execute("DELETE FROM kill_switches WHERE key = 'test-switch'")
    source.commit()
    source.close()
    backup = sqlite3.connect(destination / "database.sqlite3")
    assert backup.execute("SELECT count(*) FROM kill_switches").fetchone() == (1,)
    backup.close()
    assert verify_database_backup(destination) == report

    with pytest.raises(BackupError, match="already exists"):
        create_database_backup(database_url, destination=destination, allow_plaintext=True)
    with pytest.raises(BackupError, match="plaintext"):
        create_database_backup(database_url, destination=tmp_path / "unsafe")

    get_settings.cache_clear()
