"""Native database backup bundles with detached integrity manifests."""

import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from typing import Any

from sqlalchemy.engine import URL, make_url

BACKUP_FORMAT_VERSION = 1


class BackupError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class BackupArtifact:
    path: str
    media_type: str
    size_bytes: int
    sha256: str


@dataclass(frozen=True, slots=True)
class BackupReport:
    destination: Path
    database_engine: str
    schema_revision: str | None
    artifact: BackupArtifact
    manifest_sha256: str
    artifact_verified: bool

    def as_json(self) -> dict[str, Any]:
        value = asdict(self)
        value["destination"] = str(self.destination)
        return value


def file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def write_private(path: Path, content: bytes) -> None:
    path.write_bytes(content)
    path.chmod(0o600)


def sqlite_path(url: URL) -> Path:
    if not url.database or url.database == ":memory:":
        raise BackupError("in-memory SQLite databases cannot produce durable backups")
    path = Path(url.database).expanduser()
    return path if path.is_absolute() else (Path.cwd() / path).resolve()


def sqlite_integrity(path: Path) -> tuple[str, str | None, dict[str, int]]:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        integrity = str(connection.execute("PRAGMA integrity_check").fetchone()[0])
        if integrity != "ok":
            raise BackupError(f"SQLite integrity check failed: {integrity}")
        tables = [
            str(row[0])
            for row in connection.execute(
                """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """
            )
        ]
        counts = {
            table: int(connection.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0])
            for table in tables
        }
        revision = None
        if "alembic_version" in tables:
            row = connection.execute("SELECT version_num FROM alembic_version").fetchone()
            revision = str(row[0]) if row else None
        return integrity, revision, counts
    finally:
        connection.close()


def create_sqlite_artifact(source: Path, destination: Path) -> tuple[str | None, dict[str, int]]:
    if not source.is_file():
        raise BackupError(f"SQLite database does not exist: {source}")
    sqlite_integrity(source)
    source_connection = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    destination_connection = sqlite3.connect(destination)
    try:
        source_connection.backup(destination_connection)
    finally:
        destination_connection.close()
        source_connection.close()
    destination.chmod(0o600)
    _, revision, counts = sqlite_integrity(destination)
    return revision, counts


def query_value(url: URL, key: str) -> str | None:
    value = url.query.get(key)
    if isinstance(value, tuple):
        return value[-1] if value else None
    return value


def postgres_environment(url: URL) -> dict[str, str]:
    environment = os.environ.copy()
    values = {
        "PGHOST": url.host,
        "PGPORT": str(url.port) if url.port else None,
        "PGUSER": url.username,
        "PGPASSWORD": url.password,
        "PGDATABASE": url.database,
        "PGSSLMODE": query_value(url, "sslmode"),
        "PGSSLROOTCERT": query_value(url, "sslrootcert"),
        "PGSSLCERT": query_value(url, "sslcert"),
        "PGSSLKEY": query_value(url, "sslkey"),
    }
    environment.update({key: value for key, value in values.items() if value is not None})
    return environment


def require_executable(name: str) -> str:
    executable = shutil.which(name)
    if executable is None:
        raise BackupError(f"{name} is required for PostgreSQL backup operations")
    return executable


def run_postgres_command(command: list[str], *, environment: dict[str, str]) -> None:
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        env=environment,
        text=True,
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip() or "command failed"
        raise BackupError(message)


def create_postgres_artifact(url: URL, destination: Path) -> None:
    pg_dump = require_executable("pg_dump")
    pg_restore = require_executable("pg_restore")
    environment = postgres_environment(url)
    run_postgres_command(
        [
            pg_dump,
            "--format=custom",
            "--no-owner",
            "--no-privileges",
            "--file",
            str(destination),
        ],
        environment=environment,
    )
    destination.chmod(0o600)
    run_postgres_command([pg_restore, "--list", str(destination)], environment=environment)


def verify_manifest(destination: Path) -> tuple[dict[str, Any], str]:
    manifest_path = destination / "manifest.json"
    detached_path = destination / "manifest.sha256"
    if not manifest_path.is_file() or not detached_path.is_file():
        raise BackupError("backup manifest or detached hash is missing")
    manifest_content = manifest_path.read_bytes()
    manifest_hash = sha256(manifest_content).hexdigest()
    detached_parts = detached_path.read_text().strip().split()
    if detached_parts != [manifest_hash, "manifest.json"]:
        raise BackupError("backup manifest hash does not match")
    manifest = json.loads(manifest_content)
    if manifest.get("backup_format_version") != BACKUP_FORMAT_VERSION:
        raise BackupError("unsupported backup format version")
    return manifest, manifest_hash


def verify_database_backup(destination: Path) -> BackupReport:
    manifest, manifest_hash = verify_manifest(destination)
    artifact_document = manifest["artifact"]
    artifact = BackupArtifact(**artifact_document)
    artifact_path = destination / artifact.path
    if not artifact_path.is_file():
        raise BackupError("backup artifact is missing")
    if artifact_path.stat().st_size != artifact.size_bytes:
        raise BackupError("backup artifact size does not match")
    if file_sha256(artifact_path) != artifact.sha256:
        raise BackupError("backup artifact hash does not match")
    database_engine = str(manifest["database_engine"])
    if database_engine == "sqlite":
        sqlite_integrity(artifact_path)
    elif database_engine == "postgresql":
        pg_restore = require_executable("pg_restore")
        run_postgres_command(
            [pg_restore, "--list", str(artifact_path)],
            environment=os.environ.copy(),
        )
    else:
        raise BackupError(f"unsupported backup database engine: {database_engine}")
    return BackupReport(
        destination=destination,
        database_engine=database_engine,
        schema_revision=manifest.get("schema_revision"),
        artifact=artifact,
        manifest_sha256=manifest_hash,
        artifact_verified=True,
    )


def create_database_backup(
    database_url: str,
    *,
    destination: Path,
    created_at: datetime | None = None,
    allow_plaintext: bool = False,
) -> BackupReport:
    if not allow_plaintext:
        raise BackupError(
            "native backup artifacts are plaintext; pass explicit local-only approval or use "
            "the encrypted production backup workflow"
        )
    if destination.exists():
        raise BackupError(f"backup destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}-", dir=destination.parent))
    try:
        url = make_url(database_url)
        backend = url.get_backend_name()
        backup_time = created_at or datetime.now(UTC)
        schema_revision: str | None = None
        table_counts: dict[str, int] | None = None
        if backend == "sqlite":
            artifact_path = staging / "database.sqlite3"
            schema_revision, table_counts = create_sqlite_artifact(sqlite_path(url), artifact_path)
            media_type = "application/vnd.sqlite3"
        elif backend == "postgresql":
            artifact_path = staging / "database.pgdump"
            create_postgres_artifact(url, artifact_path)
            media_type = "application/vnd.postgresql.custom-dump"
        else:
            raise BackupError(f"unsupported database backend: {backend}")

        artifact = BackupArtifact(
            path=artifact_path.name,
            media_type=media_type,
            size_bytes=artifact_path.stat().st_size,
            sha256=file_sha256(artifact_path),
        )
        manifest = {
            "artifact": asdict(artifact),
            "backup_format_version": BACKUP_FORMAT_VERSION,
            "created_at": backup_time.astimezone(UTC).isoformat().replace("+00:00", "Z"),
            "database_engine": backend,
            "encryption": "none_explicit_local_only",
            "recovery_validation": "pending_clean_room_restore",
            "schema_revision": schema_revision,
            "table_counts": table_counts,
        }
        manifest_content = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
        manifest_hash = sha256(manifest_content).hexdigest()
        write_private(staging / "manifest.json", manifest_content)
        write_private(
            staging / "manifest.sha256",
            f"{manifest_hash}  manifest.json\n".encode(),
        )
        staging.replace(destination)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return verify_database_backup(destination)
