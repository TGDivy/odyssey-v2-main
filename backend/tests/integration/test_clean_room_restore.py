import json
import sqlite3
from datetime import UTC, datetime
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config

from odyssey.config import get_settings
from odyssey.db.backups import create_database_backup
from odyssey.db.restores import RestoreError, clean_room_restore


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
    assert report.restored_schema_revision == "20260815_0006"
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
