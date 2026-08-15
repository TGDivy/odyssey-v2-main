import asyncio
import stat
import subprocess
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from typing import Any

import pytest
from google.api_core.exceptions import PreconditionFailed

from odyssey.backups.cloud import (
    CLOUD_BACKUP_FORMAT,
    CloudBackupError,
    GCSBackupObjectStore,
    create_logical_dump,
    postgres_environment,
    retention_tiers,
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
