"""Clean-room database restoration and recovery validation."""

import asyncio
import json
import os
import tempfile
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from alembic import command
from alembic.config import Config
from sqlalchemy import func, select, text
from sqlalchemy.engine import URL, make_url

from odyssey.config import get_settings
from odyssey.db.backups import (
    create_sqlite_artifact,
    postgres_environment,
    require_executable,
    run_postgres_command,
    sqlite_path,
    verify_database_backup,
    verify_manifest,
    write_private,
)
from odyssey.db.base import Base
from odyssey.db.models import LedgerEventRecord, SourceRecord
from odyssey.db.projections import (
    CurrentEntityProjectionRebuilder,
    ProjectionIntegrityReport,
    ProjectionRebuildReport,
)
from odyssey.db.session import Database

REBUILDABLE_TABLES = {"projection_checkpoints", "projection_records"}


class RestoreError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class NativeRestoreReport:
    database_engine: str
    backup_manifest_sha256: str
    restored: bool


@dataclass(frozen=True, slots=True)
class DatabaseIntegrityReport:
    healthy: bool
    database_integrity: str
    foreign_key_violations: int
    schema_revision: str | None
    ledger_event_count: int
    source_record_count: int
    projection: ProjectionIntegrityReport
    table_counts: dict[str, int]


@dataclass(frozen=True, slots=True)
class CleanRoomRestoreReport:
    recovery_validation: str
    generated_at: datetime
    target_database_engine: str
    backup_manifest_sha256: str
    backup_schema_revision: str | None
    restored_schema_revision: str | None
    database_restore: str
    object_restore: str
    migrations: str
    backup_count_validation: str
    backup_count_mismatches: dict[str, dict[str, int]]
    projection_rebuild: ProjectionRebuildReport
    integrity: DatabaseIntegrityReport
    remaining_manual_steps: tuple[str, ...]

    def as_json(self) -> dict[str, Any]:
        value = asdict(self)
        value["generated_at"] = self.generated_at.astimezone(UTC).isoformat().replace("+00:00", "Z")
        return value


def require_empty_postgres(url: URL) -> None:
    psql = require_executable("psql")
    completed = run_postgres_command(
        [
            psql,
            "--no-align",
            "--tuples-only",
            "--command",
            "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN "
            "('pg_catalog', 'information_schema')",
        ],
        environment=postgres_environment(url),
    )
    if completed.stdout.strip() != "0":
        raise RestoreError("PostgreSQL restore target is not empty")


def restore_sqlite(artifact: Path, url: URL) -> None:
    target = sqlite_path(url)
    if target.exists():
        raise RestoreError(f"SQLite restore target already exists: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{target.name}-", suffix=".restore", dir=target.parent
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        create_sqlite_artifact(artifact, temporary)
        temporary.replace(target)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def restore_postgres(artifact: Path, url: URL) -> None:
    require_empty_postgres(url)
    pg_restore = require_executable("pg_restore")
    run_postgres_command(
        [
            pg_restore,
            "--exit-on-error",
            "--no-owner",
            "--no-privileges",
            "--dbname",
            str(url.database),
            str(artifact),
        ],
        environment=postgres_environment(url),
    )


def restore_native_database(database_url: str, *, backup: Path) -> NativeRestoreReport:
    backup_report = verify_database_backup(backup)
    manifest, manifest_hash = verify_manifest(backup)
    artifact = backup / manifest["artifact"]["path"]
    url = make_url(database_url)
    target_engine = url.get_backend_name()
    if target_engine != backup_report.database_engine:
        raise RestoreError(
            f"backup engine {backup_report.database_engine} cannot restore into {target_engine}"
        )
    if target_engine == "sqlite":
        restore_sqlite(artifact, url)
    elif target_engine == "postgresql":
        restore_postgres(artifact, url)
    else:
        raise RestoreError(f"unsupported restore database engine: {target_engine}")
    return NativeRestoreReport(
        database_engine=target_engine,
        backup_manifest_sha256=manifest_hash,
        restored=True,
    )


def apply_current_migrations(database_url: str, *, alembic_ini: Path) -> None:
    previous_database_url = os.environ.get("ODYSSEY_DATABASE_URL")
    try:
        os.environ["ODYSSEY_DATABASE_URL"] = database_url
        get_settings.cache_clear()
        command.upgrade(Config(str(alembic_ini)), "head")
    finally:
        if previous_database_url is None:
            os.environ.pop("ODYSSEY_DATABASE_URL", None)
        else:
            os.environ["ODYSSEY_DATABASE_URL"] = previous_database_url
        get_settings.cache_clear()


async def rebuild_and_validate(
    database_url: str,
) -> tuple[ProjectionRebuildReport, DatabaseIntegrityReport]:
    database = Database(database_url)
    rebuilder = CurrentEntityProjectionRebuilder()
    try:
        async with database.engine.connect() as connection:
            if connection.dialect.name == "sqlite":
                integrity_rows = await connection.exec_driver_sql("PRAGMA integrity_check")
                database_integrity = str(integrity_rows.scalar_one())
                foreign_key_rows = await connection.exec_driver_sql("PRAGMA foreign_key_check")
                foreign_key_violations = len(foreign_key_rows.all())
            else:
                database_integrity = "constraints_enforced"
                foreign_key_violations = 0

        async with database.sessions() as session, session.begin():
            rebuild_report = await rebuilder.rebuild(session)
            projection_report = await rebuilder.verify(session)

        async with database.sessions() as session:
            revision = await session.scalar(text("SELECT version_num FROM alembic_version"))
            ledger_event_count = int(
                await session.scalar(select(func.count()).select_from(LedgerEventRecord)) or 0
            )
            source_record_count = int(
                await session.scalar(select(func.count()).select_from(SourceRecord)) or 0
            )
            table_counts = {
                table.name: int(await session.scalar(select(func.count()).select_from(table)) or 0)
                for table in Base.metadata.sorted_tables
            }
        integrity_report = DatabaseIntegrityReport(
            healthy=(database_integrity == "ok" or database_integrity == "constraints_enforced")
            and foreign_key_violations == 0
            and projection_report.healthy,
            database_integrity=database_integrity,
            foreign_key_violations=foreign_key_violations,
            schema_revision=str(revision) if revision else None,
            ledger_event_count=ledger_event_count,
            source_record_count=source_record_count,
            projection=projection_report,
            table_counts=table_counts,
        )
        return rebuild_report, integrity_report
    finally:
        await database.dispose()


def write_restore_report(path: Path, report: CleanRoomRestoreReport) -> None:
    if path.exists():
        raise RestoreError(f"restore report already exists: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    content = (json.dumps(report.as_json(), default=str, indent=2, sort_keys=True) + "\n").encode()
    write_private(path, content)


def clean_room_restore(
    database_url: str,
    *,
    backup: Path,
    alembic_ini: Path,
    report_path: Path,
    generated_at: datetime | None = None,
) -> CleanRoomRestoreReport:
    backup_report = verify_database_backup(backup)
    native_report = restore_native_database(database_url, backup=backup)
    apply_current_migrations(database_url, alembic_ini=alembic_ini)
    rebuild_report, integrity_report = asyncio.run(rebuild_and_validate(database_url))
    if not integrity_report.healthy:
        raise RestoreError("restored database failed integrity validation")
    count_mismatches = {
        table: {"backup": expected, "restored": integrity_report.table_counts[table]}
        for table, expected in (backup_report.table_counts or {}).items()
        if table in integrity_report.table_counts
        and table not in REBUILDABLE_TABLES
        and integrity_report.table_counts[table] != expected
    }
    if count_mismatches:
        raise RestoreError(f"restored table counts do not match backup: {count_mismatches}")
    report = CleanRoomRestoreReport(
        recovery_validation="passed",
        generated_at=generated_at or datetime.now(UTC),
        target_database_engine=native_report.database_engine,
        backup_manifest_sha256=native_report.backup_manifest_sha256,
        backup_schema_revision=backup_report.schema_revision,
        restored_schema_revision=integrity_report.schema_revision,
        database_restore="passed",
        object_restore="not_applicable_database_only_bundle",
        migrations="current_head_applied",
        backup_count_validation=(
            "passed" if backup_report.table_counts is not None else "unavailable"
        ),
        backup_count_mismatches=count_mismatches,
        projection_rebuild=rebuild_report,
        integrity=integrity_report,
        remaining_manual_steps=(
            "rotate production secrets when restoring a production incident",
            "enroll a fresh client and reconcile any surviving unsynced operations",
            "securely destroy the isolated target after retaining the report",
        ),
    )
    write_restore_report(report_path, report)
    return report
