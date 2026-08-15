"""Verified Cloud SQL and attachment backups for the production job."""

import asyncio
import json
import os
import stat
import subprocess
from collections.abc import Mapping, Sequence
from contextlib import suppress
from dataclasses import dataclass
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any, Protocol

import structlog
from google.api_core.exceptions import PreconditionFailed
from google.cloud import storage
from pydantic import AwareDatetime, Field
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy import text
from sqlalchemy.engine import make_url

from odyssey.attachments.backups import (
    create_object_archive,
    object_archive_manifest_bytes,
    verify_object_archive,
)
from odyssey.attachments.storage import AttachmentStore
from odyssey.attachments.storage_factory import create_attachment_store
from odyssey.attachments.storage_gcs import GCSAttachmentStore
from odyssey.config import Settings, get_settings
from odyssey.db.session import Database
from odyssey.domain.common import StrictModel
from odyssey.logging import configure_logging

CLOUD_BACKUP_FORMAT = "odyssey-cloud-backup.v1"
CLOUD_BACKUP_REPORT_FORMAT = "odyssey-cloud-backup-report.v1"


class CloudBackupError(RuntimeError):
    pass


class CloudBackupSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="ODYSSEY_BACKUP_", extra="ignore")

    database_bucket: str = Field(min_length=1)
    object_archive_bucket: str = Field(min_length=1)
    archive_kms_key: str = Field(min_length=1)


class BackupObjectReference(StrictModel):
    retention_tier: str
    bucket_name: str
    storage_key: str
    generation: str
    content_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    byte_size: int = Field(ge=0)


class CloudBackupManifest(StrictModel):
    format: str = CLOUD_BACKUP_FORMAT
    backup_id: str
    created_at: AwareDatetime
    commit_sha: str
    database_schema_revision: str
    database_dump_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    database_dump_bytes: int = Field(ge=0)
    database_catalog_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    database_objects: tuple[BackupObjectReference, ...]
    object_manifest_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    object_manifest_archive_key: str
    object_manifest_archive_version: str | None
    object_count: int = Field(ge=0)
    object_bytes: int = Field(ge=0)


class CloudBackupEnvelope(StrictModel):
    manifest_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    manifest: CloudBackupManifest


class CloudBackupReport(StrictModel):
    format: str = CLOUD_BACKUP_REPORT_FORMAT
    status: str
    backup_id: str
    completed_at: AwareDatetime
    manifest_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    manifest_objects: tuple[BackupObjectReference, ...]
    database_object_count: int = Field(ge=1)
    object_archive_count: int = Field(ge=0)
    object_archive_bytes: int = Field(ge=0)
    report_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


@dataclass(frozen=True, slots=True)
class LogicalDump:
    path: Path
    content_sha256: str
    byte_size: int
    catalog_sha256: str


class CommandRunner(Protocol):
    def __call__(
        self,
        command: Sequence[str],
        *,
        env: Mapping[str, str],
        stdout: int,
        stderr: int,
        check: bool,
    ) -> subprocess.CompletedProcess[bytes]: ...


class BackupObjectStore(Protocol):
    @property
    def bucket_name(self) -> str: ...

    async def validate_configuration(self) -> None: ...

    async def write_file(
        self,
        storage_key: str,
        path: Path,
        *,
        retention_tier: str,
        content_sha256: str,
    ) -> BackupObjectReference: ...

    async def write_bytes(
        self,
        storage_key: str,
        content: bytes,
        *,
        retention_tier: str,
        content_sha256: str,
    ) -> BackupObjectReference: ...


class GCSBackupObjectStore:
    def __init__(
        self,
        *,
        bucket_name: str,
        project_id: str,
        kms_key_name: str,
        client: Any | None = None,
    ) -> None:
        self.bucket_name = bucket_name
        self.kms_key_name = kms_key_name
        self.client = client or storage.Client(project=project_id)
        self.bucket = self.client.bucket(bucket_name)

    async def validate_configuration(self) -> None:
        await asyncio.to_thread(self._validate_configuration)

    async def write_file(
        self,
        storage_key: str,
        path: Path,
        *,
        retention_tier: str,
        content_sha256: str,
    ) -> BackupObjectReference:
        return await asyncio.to_thread(
            self._write_file,
            storage_key,
            path,
            retention_tier,
            content_sha256,
        )

    async def write_bytes(
        self,
        storage_key: str,
        content: bytes,
        *,
        retention_tier: str,
        content_sha256: str,
    ) -> BackupObjectReference:
        return await asyncio.to_thread(
            self._write_bytes,
            storage_key,
            content,
            retention_tier,
            content_sha256,
        )

    def _validate_configuration(self) -> None:
        self.bucket.reload()
        if not self.bucket.versioning_enabled:
            raise CloudBackupError("database backup bucket versioning is not enabled")
        if not self.bucket.iam_configuration.uniform_bucket_level_access_enabled:
            raise CloudBackupError("database backup bucket does not enforce uniform access")
        if self.bucket.default_kms_key_name != self.kms_key_name:
            raise CloudBackupError("database backup bucket does not use the configured KMS key")

    def _write_file(
        self,
        storage_key: str,
        path: Path,
        retention_tier: str,
        content_sha256: str,
    ) -> BackupObjectReference:
        blob = self._blob(storage_key, content_sha256)
        with suppress(PreconditionFailed):
            blob.upload_from_filename(
                str(path),
                if_generation_match=0,
                checksum="crc32c",
            )
        return self._reference(blob, retention_tier, content_sha256, path.stat().st_size)

    def _write_bytes(
        self,
        storage_key: str,
        content: bytes,
        retention_tier: str,
        content_sha256: str,
    ) -> BackupObjectReference:
        blob = self._blob(storage_key, content_sha256)
        with suppress(PreconditionFailed):
            blob.upload_from_string(content, if_generation_match=0, checksum="crc32c")
        return self._reference(blob, retention_tier, content_sha256, len(content))

    def _blob(self, storage_key: str, content_sha256: str) -> Any:
        blob = self.bucket.blob(storage_key, kms_key_name=self.kms_key_name)
        blob.metadata = {
            "content-sha256": content_sha256,
            "backup-format": CLOUD_BACKUP_FORMAT,
        }
        return blob

    def _reference(
        self,
        blob: Any,
        retention_tier: str,
        content_sha256: str,
        byte_size: int,
    ) -> BackupObjectReference:
        blob.reload()
        metadata = blob.metadata or {}
        if (
            blob.generation is None
            or blob.size != byte_size
            or metadata.get("content-sha256") != content_sha256
        ):
            raise CloudBackupError("stored database backup object failed metadata verification")
        return BackupObjectReference(
            retention_tier=retention_tier,
            bucket_name=self.bucket_name,
            storage_key=blob.name,
            generation=str(blob.generation),
            content_sha256=content_sha256,
            byte_size=byte_size,
        )


def _sha256_file(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_bytes(value: StrictModel) -> bytes:
    return json.dumps(
        value.model_dump(mode="json"),
        separators=(",", ":"),
        sort_keys=True,
    ).encode()


def postgres_environment(database_url: str) -> dict[str, str]:
    url = make_url(database_url)
    if url.get_backend_name() != "postgresql":
        raise CloudBackupError("cloud logical backups require PostgreSQL")
    if url.host not in {"127.0.0.1", "localhost"}:
        raise CloudBackupError("cloud logical backups require the local authenticated proxy")
    if not url.username or not url.database:
        raise CloudBackupError("cloud logical backup database identity is incomplete")
    environment = {
        key: os.environ[key]
        for key in ("HOME", "LANG", "PATH", "SSL_CERT_DIR", "SSL_CERT_FILE")
        if key in os.environ
    }
    environment.update(
        {
            "PGDATABASE": url.database,
            "PGHOST": url.host,
            "PGPORT": str(url.port or 5432),
            "PGSSLMODE": "disable",
            "PGUSER": url.username,
        }
    )
    if url.password:
        environment["PGPASSWORD"] = url.password
    return environment


def _run_command(
    command: Sequence[str],
    *,
    env: Mapping[str, str],
    stdout: int,
    stderr: int,
    check: bool,
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        command,
        env=env,
        stdout=stdout,
        stderr=stderr,
        check=check,
    )


def create_logical_dump(
    database_url: str,
    destination: Path,
    *,
    runner: CommandRunner = _run_command,
) -> LogicalDump:
    environment = postgres_environment(database_url)
    dump_command = (
        "pg_dump",
        "--format=custom",
        "--compress=9",
        "--no-owner",
        "--no-privileges",
        f"--file={destination}",
    )
    dumped = runner(
        dump_command,
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )
    if dumped.returncode != 0 or not destination.is_file():
        raise CloudBackupError("PostgreSQL logical dump failed")
    destination.chmod(stat.S_IRUSR | stat.S_IWUSR)
    catalog = runner(
        ("pg_restore", "--list", str(destination)),
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if catalog.returncode != 0 or not catalog.stdout:
        raise CloudBackupError("PostgreSQL logical dump catalog verification failed")
    return LogicalDump(
        path=destination,
        content_sha256=_sha256_file(destination),
        byte_size=destination.stat().st_size,
        catalog_sha256=sha256(catalog.stdout).hexdigest(),
    )


def retention_tiers(created_at: datetime) -> tuple[str, ...]:
    tiers = ["daily"]
    if created_at.day == 1:
        tiers.append("monthly")
    if created_at.month == 1 and created_at.day == 1:
        tiers.append("annual")
    return tuple(tiers)


def _backup_id(created_at: datetime, execution_id: str, dump_sha256: str) -> str:
    execution_hash = sha256(execution_id.encode()).hexdigest()[:12]
    timestamp = created_at.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")
    return f"{timestamp}-{execution_hash}-{dump_sha256[:12]}"


def _tier_path(tier: str, created_at: datetime) -> str:
    if tier == "daily":
        return created_at.strftime("%Y/%m/%d")
    if tier == "monthly":
        return created_at.strftime("%Y/%m")
    return created_at.strftime("%Y")


def _report_hash(report: CloudBackupReport) -> str:
    payload = report.model_dump(mode="json", exclude={"report_sha256"})
    return sha256(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()).hexdigest()


async def complete_cloud_backup(
    *,
    logical_dump: LogicalDump,
    database: Database,
    source_objects: AttachmentStore,
    archive_objects: AttachmentStore,
    database_backups: BackupObjectStore,
    created_at: datetime,
    execution_id: str,
    commit_sha: str,
) -> CloudBackupReport:
    await database_backups.validate_configuration()
    async with database.sessions() as session:
        schema_revision = await session.scalar(text("SELECT version_num FROM alembic_version"))
        object_envelope = await create_object_archive(
            session,
            source=source_objects,
            archive=archive_objects,
            created_at=created_at,
        )
    if not isinstance(schema_revision, str) or not schema_revision:
        raise CloudBackupError("database schema revision is unavailable")
    archived_object_manifest = await archive_objects.write_object(
        object_envelope.manifest_sha256,
        object_archive_manifest_bytes(object_envelope.manifest),
    )
    object_report = await verify_object_archive(
        archive=archive_objects,
        envelope=object_envelope,
        verified_at=created_at,
    )
    if not object_report.verified:
        raise CloudBackupError("object archive verification failed")

    backup_id = _backup_id(created_at, execution_id, logical_dump.content_sha256)
    tiers = retention_tiers(created_at)
    database_objects = []
    for tier in tiers:
        storage_key = f"database/{tier}/{_tier_path(tier, created_at)}/{backup_id}.dump"
        database_objects.append(
            await database_backups.write_file(
                storage_key,
                logical_dump.path,
                retention_tier=tier,
                content_sha256=logical_dump.content_sha256,
            )
        )

    manifest = CloudBackupManifest(
        backup_id=backup_id,
        created_at=created_at,
        commit_sha=commit_sha,
        database_schema_revision=schema_revision,
        database_dump_sha256=logical_dump.content_sha256,
        database_dump_bytes=logical_dump.byte_size,
        database_catalog_sha256=logical_dump.catalog_sha256,
        database_objects=tuple(database_objects),
        object_manifest_sha256=object_envelope.manifest_sha256,
        object_manifest_archive_key=archived_object_manifest.storage_key,
        object_manifest_archive_version=archived_object_manifest.version_id,
        object_count=object_report.object_count,
        object_bytes=object_report.total_bytes,
    )
    manifest_sha256 = sha256(_canonical_bytes(manifest)).hexdigest()
    envelope = CloudBackupEnvelope(manifest_sha256=manifest_sha256, manifest=manifest)
    envelope_content = _canonical_bytes(envelope)
    envelope_sha256 = sha256(envelope_content).hexdigest()
    manifest_objects = []
    for tier in tiers:
        storage_key = f"manifests/{tier}/{_tier_path(tier, created_at)}/{backup_id}.json"
        manifest_objects.append(
            await database_backups.write_bytes(
                storage_key,
                envelope_content,
                retention_tier=tier,
                content_sha256=envelope_sha256,
            )
        )

    incomplete_report = CloudBackupReport(
        status="verified",
        backup_id=backup_id,
        completed_at=created_at,
        manifest_sha256=manifest_sha256,
        manifest_objects=tuple(manifest_objects),
        database_object_count=len(database_objects),
        object_archive_count=object_report.object_count,
        object_archive_bytes=object_report.total_bytes,
        report_sha256="0" * 64,
    )
    return incomplete_report.model_copy(update={"report_sha256": _report_hash(incomplete_report)})


async def run_cloud_backup(
    settings: Settings,
    backup_settings: CloudBackupSettings,
    *,
    created_at: datetime | None = None,
    execution_id: str | None = None,
) -> CloudBackupReport:
    active_time = created_at or datetime.now(UTC)
    active_execution_id = execution_id or os.environ.get("CLOUD_RUN_EXECUTION", "manual")
    source_objects = create_attachment_store(settings)
    archive_objects = GCSAttachmentStore(
        bucket_name=backup_settings.object_archive_bucket,
        project_id=settings.gcp_project_id,
        kms_key_name=backup_settings.archive_kms_key,
    )
    database_backups = GCSBackupObjectStore(
        bucket_name=backup_settings.database_bucket,
        project_id=settings.gcp_project_id,
        kms_key_name=backup_settings.archive_kms_key,
    )
    database = Database(settings.database_url)
    try:
        with TemporaryDirectory(prefix="odyssey-cloud-backup-") as temporary_directory:
            logical_dump = await asyncio.to_thread(
                create_logical_dump,
                settings.database_url,
                Path(temporary_directory) / "database.dump",
            )
            return await complete_cloud_backup(
                logical_dump=logical_dump,
                database=database,
                source_objects=source_objects,
                archive_objects=archive_objects,
                database_backups=database_backups,
                created_at=active_time,
                execution_id=active_execution_id,
                commit_sha=settings.commit_sha,
            )
    finally:
        await database.dispose()


def main() -> None:
    settings = get_settings()
    configure_logging(settings.log_level)
    logger = structlog.get_logger(__name__)
    try:
        report = asyncio.run(run_cloud_backup(settings, CloudBackupSettings()))
    except Exception as error:
        logger.error(
            "cloud_backup_failed",
            environment=settings.env.value,
            error_type=type(error).__name__,
        )
        raise SystemExit(1) from None
    logger.info(
        "cloud_backup_completed",
        environment=settings.env.value,
        backup_id=report.backup_id,
        manifest_sha256=report.manifest_sha256,
        report_sha256=report.report_sha256,
        database_object_count=report.database_object_count,
        object_archive_count=report.object_archive_count,
    )
    print(json.dumps(report.model_dump(mode="json"), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
