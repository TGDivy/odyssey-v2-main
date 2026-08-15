import asyncio
import json
import stat
import subprocess
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from typing import Any

import pytest
from google.api_core.exceptions import PreconditionFailed

from odyssey.attachments.backups import (
    ObjectArchiveManifest,
    load_object_archive_manifest,
    object_archive_manifest_bytes,
)
from odyssey.backups.cloud import (
    CLOUD_BACKUP_FORMAT,
    BackupObjectReference,
    CloudBackupEnvelope,
    CloudBackupError,
    CloudBackupManifest,
    GCSBackupObjectStore,
    create_logical_dump,
    load_cloud_backup_envelope,
    materialize_native_backup_bundle,
    materialize_object_archive_manifest,
    postgres_environment,
    retention_tiers,
    validate_cloud_backup_envelope,
)
from odyssey.db import backups as database_backups
from odyssey.db.backups import BackupError


def cloud_backup_envelope(content: bytes) -> CloudBackupEnvelope:
    content_sha256 = sha256(content).hexdigest()
    object_manifest = ObjectArchiveManifest(
        created_at=datetime(2026, 8, 15, tzinfo=UTC),
        object_count=0,
        total_bytes=0,
        entries=(),
    )
    manifest = CloudBackupManifest(
        backup_id="20260815T000000Z-synthetic",
        created_at=datetime(2026, 8, 15, tzinfo=UTC),
        commit_sha="a" * 40,
        database_schema_revision="20260815_0010",
        database_dump_sha256=content_sha256,
        database_dump_bytes=len(content),
        database_catalog_sha256=sha256(b"synthetic pg_restore catalog").hexdigest(),
        database_objects=(
            BackupObjectReference(
                retention_tier="daily",
                bucket_name="synthetic-database-backups",
                storage_key="database/daily/2026/08/15/synthetic.dump",
                generation="1",
                content_sha256=content_sha256,
                byte_size=len(content),
            ),
        ),
        object_manifest_sha256=sha256(object_archive_manifest_bytes(object_manifest)).hexdigest(),
        object_manifest_archive_key="objects/cc/manifest",
        object_manifest_archive_version="1",
        object_count=0,
        object_bytes=0,
    )
    manifest_content = json.dumps(
        manifest.model_dump(mode="json"),
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    return CloudBackupEnvelope(
        manifest_sha256=sha256(manifest_content).hexdigest(),
        manifest=manifest,
    )


def envelope_with_manifest(manifest: CloudBackupManifest) -> CloudBackupEnvelope:
    content = json.dumps(
        manifest.model_dump(mode="json"),
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    return CloudBackupEnvelope(
        manifest_sha256=sha256(content).hexdigest(),
        manifest=manifest,
    )


def test_cloud_backup_envelope_loads_only_with_valid_hash() -> None:
    envelope = cloud_backup_envelope(b"synthetic PostgreSQL dump")

    loaded = load_cloud_backup_envelope(envelope.model_dump_json().encode())

    assert loaded == envelope
    with pytest.raises(CloudBackupError, match="manifest hash does not match"):
        validate_cloud_backup_envelope(envelope.model_copy(update={"manifest_sha256": "0" * 64}))
    with pytest.raises(CloudBackupError, match="manifest is invalid"):
        load_cloud_backup_envelope(b"not-json")


def test_cloud_backup_envelope_rejects_mismatched_database_reference() -> None:
    envelope = cloud_backup_envelope(b"synthetic PostgreSQL dump")
    reference = envelope.manifest.database_objects[0].model_copy(
        update={"content_sha256": "d" * 64}
    )
    mismatched = envelope_with_manifest(
        envelope.manifest.model_copy(update={"database_objects": (reference,)})
    )

    with pytest.raises(CloudBackupError, match="database references disagree"):
        validate_cloud_backup_envelope(mismatched)


@pytest.mark.parametrize(
    "downloaded_content",
    [b"short", b"x" * len(b"synthetic PostgreSQL dump")],
)
def test_materialize_native_backup_rejects_invalid_dump(
    tmp_path: Path, downloaded_content: bytes
) -> None:
    expected_content = b"synthetic PostgreSQL dump"
    envelope = cloud_backup_envelope(expected_content)
    database_dump = tmp_path / "database.dump"
    database_dump.write_bytes(downloaded_content)

    with pytest.raises(CloudBackupError, match="dump failed manifest verification"):
        materialize_native_backup_bundle(
            envelope,
            database_dump=database_dump,
            destination=tmp_path / "native-backup",
        )


def test_materialize_native_backup_creates_private_verified_bundle(tmp_path: Path) -> None:
    content = b"synthetic PostgreSQL dump"
    envelope = cloud_backup_envelope(content)
    database_dump = tmp_path / "database.dump"
    database_dump.write_bytes(content)
    destination = tmp_path / "native-backup"

    manifest_sha256 = materialize_native_backup_bundle(
        envelope,
        database_dump=database_dump,
        destination=destination,
    )

    artifact_path = destination / "database.pgdump"
    manifest_path = destination / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert artifact_path.read_bytes() == content
    assert artifact_path.stat().st_mode & 0o777 == stat.S_IRUSR | stat.S_IWUSR
    assert manifest_path.stat().st_mode & 0o777 == stat.S_IRUSR | stat.S_IWUSR
    assert manifest["artifact"]["sha256"] == envelope.manifest.database_dump_sha256
    assert manifest["source_cloud_manifest_sha256"] == envelope.manifest_sha256
    assert manifest["source_database_catalog_sha256"] == envelope.manifest.database_catalog_sha256
    assert (destination / "manifest.sha256").read_text() == (f"{manifest_sha256}  manifest.json\n")
    assert manifest_sha256 == sha256(manifest_path.read_bytes()).hexdigest()
    assert not list(tmp_path.glob(".native-backup-*"))


def test_materialized_native_backup_verifies_postgres_catalog(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    content = b"synthetic PostgreSQL dump"
    envelope = cloud_backup_envelope(content)
    database_dump = tmp_path / "database.dump"
    database_dump.write_bytes(content)
    destination = tmp_path / "native-backup"
    materialize_native_backup_bundle(
        envelope,
        database_dump=database_dump,
        destination=destination,
    )

    def require_executable(name: str) -> str:
        assert name == "pg_restore"
        return name

    def matching_catalog(*_args: Any, **_kwargs: Any) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(
            ("pg_restore",),
            0,
            stdout="synthetic pg_restore catalog",
            stderr="",
        )

    monkeypatch.setattr(database_backups, "require_executable", require_executable)
    monkeypatch.setattr(database_backups, "run_postgres_command", matching_catalog)
    assert database_backups.verify_database_backup(destination).artifact_verified is True

    def mismatched_catalog(*_args: Any, **_kwargs: Any) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(
            ("pg_restore",),
            0,
            stdout="different catalog",
            stderr="",
        )

    monkeypatch.setattr(database_backups, "run_postgres_command", mismatched_catalog)
    with pytest.raises(BackupError, match="catalog hash does not match"):
        database_backups.verify_database_backup(destination)


def test_materialize_native_backup_never_replaces_destination(tmp_path: Path) -> None:
    content = b"synthetic PostgreSQL dump"
    envelope = cloud_backup_envelope(content)
    database_dump = tmp_path / "database.dump"
    database_dump.write_bytes(content)
    destination = tmp_path / "native-backup"
    destination.mkdir()

    with pytest.raises(CloudBackupError, match="destination already exists"):
        materialize_native_backup_bundle(
            envelope,
            database_dump=database_dump,
            destination=destination,
        )


def test_materialize_object_manifest_creates_verified_restore_envelope(
    tmp_path: Path,
) -> None:
    envelope = cloud_backup_envelope(b"synthetic PostgreSQL dump")
    archived_manifest = tmp_path / "archived-object-manifest.json"
    archived_manifest.write_bytes(
        object_archive_manifest_bytes(
            ObjectArchiveManifest(
                created_at=datetime(2026, 8, 15, tzinfo=UTC),
                object_count=0,
                total_bytes=0,
                entries=(),
            )
        )
    )
    destination = tmp_path / "object-manifest.json"

    manifest_sha256 = materialize_object_archive_manifest(
        envelope,
        archived_manifest=archived_manifest,
        destination=destination,
    )

    restored_envelope = load_object_archive_manifest(destination)
    assert restored_envelope.manifest_sha256 == manifest_sha256
    assert restored_envelope.manifest_sha256 == envelope.manifest.object_manifest_sha256
    assert destination.stat().st_mode & 0o777 == stat.S_IRUSR | stat.S_IWUSR


def test_materialize_object_manifest_rejects_cloud_count_mismatch(tmp_path: Path) -> None:
    envelope = cloud_backup_envelope(b"synthetic PostgreSQL dump")
    mismatched = envelope_with_manifest(envelope.manifest.model_copy(update={"object_count": 1}))
    archived_manifest = tmp_path / "archived-object-manifest.json"
    archived_manifest.write_bytes(
        object_archive_manifest_bytes(
            ObjectArchiveManifest(
                created_at=datetime(2026, 8, 15, tzinfo=UTC),
                object_count=0,
                total_bytes=0,
                entries=(),
            )
        )
    )

    with pytest.raises(CloudBackupError, match="manifests disagree"):
        materialize_object_archive_manifest(
            mismatched,
            archived_manifest=archived_manifest,
            destination=tmp_path / "object-manifest.json",
        )


def test_materialize_object_manifest_rejects_archived_hash_mismatch(tmp_path: Path) -> None:
    envelope = cloud_backup_envelope(b"synthetic PostgreSQL dump")
    archived_manifest = tmp_path / "archived-object-manifest.json"
    archived_manifest.write_bytes(
        object_archive_manifest_bytes(
            ObjectArchiveManifest(
                created_at=datetime(2026, 8, 16, tzinfo=UTC),
                object_count=0,
                total_bytes=0,
                entries=(),
            )
        )
    )

    with pytest.raises(CloudBackupError, match="failed cloud verification"):
        materialize_object_archive_manifest(
            envelope,
            archived_manifest=archived_manifest,
            destination=tmp_path / "object-manifest.json",
        )


def test_logical_dump_uses_isolated_proxy_environment(tmp_path: Path, monkeypatch: Any) -> None:
    monkeypatch.setenv("ODYSSEY_AUTH_ACCESS_TOKEN_SIGNING_KEY", "must-not-leak")
    destination = tmp_path / "database.dump"
    calls: list[tuple[tuple[str, ...], dict[str, str]]] = []

    def runner(
        command: tuple[str, ...],
        *,
        env: dict[str, str],
        stdout: int,
        stderr: int,
        check: bool,
    ) -> subprocess.CompletedProcess[bytes]:
        del stdout, stderr, check
        calls.append((command, env))
        if command[0] == "pg_dump":
            destination.write_bytes(b"synthetic-postgres-custom-dump")
            return subprocess.CompletedProcess(command, 0, stdout=b"", stderr=b"")
        return subprocess.CompletedProcess(
            command,
            0,
            stdout=b"synthetic pg_restore catalog",
            stderr=b"",
        )

    logical_dump = create_logical_dump(
        "postgresql+asyncpg://backup%40example.iam:local-password@127.0.0.1:5432/odyssey",
        destination,
        runner=runner,
    )

    assert logical_dump.content_sha256 == sha256(destination.read_bytes()).hexdigest()
    assert logical_dump.catalog_sha256 == sha256(b"synthetic pg_restore catalog").hexdigest()
    assert destination.stat().st_mode & 0o777 == stat.S_IRUSR | stat.S_IWUSR
    assert calls[0][0][0] == "pg_dump"
    assert calls[1][0][0] == "pg_restore"
    assert all("local-password" not in argument for call in calls for argument in call[0])
    assert calls[0][1]["PGUSER"] == "backup@example.iam"
    assert calls[0][1]["PGPASSWORD"] == "local-password"
    assert calls[0][1]["PGSSLMODE"] == "disable"
    assert "ODYSSEY_AUTH_ACCESS_TOKEN_SIGNING_KEY" not in calls[0][1]


@pytest.mark.parametrize(
    ("database_url", "message"),
    [
        ("sqlite+aiosqlite:///local.db", "require PostgreSQL"),
        ("postgresql+asyncpg://user@example.net/odyssey", "local authenticated proxy"),
        ("postgresql+asyncpg://127.0.0.1/odyssey", "identity is incomplete"),
    ],
)
def test_postgres_environment_fails_closed(database_url: str, message: str) -> None:
    with pytest.raises(CloudBackupError, match=message):
        postgres_environment(database_url)


def test_logical_dump_rejects_dump_and_catalog_failures(tmp_path: Path) -> None:
    destination = tmp_path / "failed.dump"

    def dump_failure(*_args: Any, **_kwargs: Any) -> subprocess.CompletedProcess[bytes]:
        return subprocess.CompletedProcess(("pg_dump",), 1, stdout=b"", stderr=b"private")

    with pytest.raises(CloudBackupError, match="logical dump failed"):
        create_logical_dump(
            "postgresql+asyncpg://backup@localhost/odyssey",
            destination,
            runner=dump_failure,
        )

    def catalog_failure(
        command: tuple[str, ...], **_kwargs: Any
    ) -> subprocess.CompletedProcess[bytes]:
        if command[0] == "pg_dump":
            destination.write_bytes(b"dump")
            return subprocess.CompletedProcess(command, 0, stdout=b"", stderr=b"")
        return subprocess.CompletedProcess(command, 1, stdout=b"", stderr=b"private")

    with pytest.raises(CloudBackupError, match="catalog verification failed"):
        create_logical_dump(
            "postgresql+asyncpg://backup@localhost/odyssey",
            destination,
            runner=catalog_failure,
        )


def test_retention_tiers_are_calendar_bounded() -> None:
    assert retention_tiers(datetime(2026, 8, 15, tzinfo=UTC)) == ("daily",)
    assert retention_tiers(datetime(2026, 8, 1, tzinfo=UTC)) == ("daily", "monthly")
    assert retention_tiers(datetime(2026, 1, 1, tzinfo=UTC)) == (
        "daily",
        "monthly",
        "annual",
    )


class FakeIamConfiguration:
    uniform_bucket_level_access_enabled = True


class FakeBlob:
    def __init__(self, name: str, metadata: dict[str, str]) -> None:
        self.name = name
        self.metadata = metadata
        self.generation: int | None = None
        self.size: int | None = None

    def upload_from_filename(self, path: str, **_kwargs: Any) -> None:
        if self.generation is not None:
            raise PreconditionFailed("already exists")
        self.size = Path(path).stat().st_size
        self.generation = 1

    def upload_from_string(self, content: bytes, **_kwargs: Any) -> None:
        if self.generation is not None:
            raise PreconditionFailed("already exists")
        self.size = len(content)
        self.generation = 1

    def reload(self) -> None:
        return None


class FakeBucket:
    versioning_enabled = True
    default_kms_key_name = "projects/test/locations/EU/keyRings/archive/cryptoKeys/archive"
    iam_configuration = FakeIamConfiguration()

    def __init__(self) -> None:
        self.blobs: dict[str, FakeBlob] = {}

    def reload(self) -> None:
        return None

    def blob(self, name: str, *, kms_key_name: str) -> FakeBlob:
        assert kms_key_name == self.default_kms_key_name
        if name not in self.blobs:
            self.blobs[name] = FakeBlob(name, {})
        blob = self.blobs[name]
        if blob.generation is None:
            blob.metadata = {}
        return blob


class FakeClient:
    def __init__(self, bucket: FakeBucket) -> None:
        self.active_bucket = bucket

    def bucket(self, name: str) -> FakeBucket:
        assert name == "synthetic-backups"
        return self.active_bucket


def test_gcs_backup_store_validates_and_never_overwrites(tmp_path: Path) -> None:
    async def scenario() -> None:
        bucket = FakeBucket()
        store = GCSBackupObjectStore(
            bucket_name="synthetic-backups",
            project_id="synthetic-project",
            kms_key_name=bucket.default_kms_key_name,
            client=FakeClient(bucket),
        )
        await store.validate_configuration()
        content = b"synthetic logical backup"
        content_hash = sha256(content).hexdigest()
        dump = tmp_path / "database.dump"
        dump.write_bytes(content)

        first = await store.write_file(
            "database/daily/test.dump",
            dump,
            retention_tier="daily",
            content_sha256=content_hash,
        )
        second = await store.write_file(
            "database/daily/test.dump",
            dump,
            retention_tier="daily",
            content_sha256=content_hash,
        )
        manifest = await store.write_bytes(
            "manifests/daily/test.json",
            content,
            retention_tier="daily",
            content_sha256=content_hash,
        )

        assert first == second
        assert manifest.byte_size == len(content)
        assert bucket.blobs[first.storage_key].metadata["backup-format"] == CLOUD_BACKUP_FORMAT

    asyncio.run(scenario())


def test_gcs_backup_store_rejects_unsafe_bucket() -> None:
    async def scenario() -> None:
        bucket = FakeBucket()
        bucket.versioning_enabled = False
        store = GCSBackupObjectStore(
            bucket_name="synthetic-backups",
            project_id="synthetic-project",
            kms_key_name=bucket.default_kms_key_name,
            client=FakeClient(bucket),
        )
        with pytest.raises(CloudBackupError, match="versioning"):
            await store.validate_configuration()

    asyncio.run(scenario())
