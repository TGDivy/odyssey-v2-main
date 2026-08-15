import asyncio
import io
from hashlib import sha256
from pathlib import Path
from typing import Any

from botocore.exceptions import ClientError

from odyssey.attachments.storage import ChunkManifest, LocalAttachmentStore
from odyssey.attachments.storage_factory import create_attachment_store
from odyssey.attachments.storage_gcs import GCSAttachmentStore
from odyssey.attachments.storage_s3 import S3AttachmentStore
from odyssey.config import AttachmentStoreBackend, Environment, Settings
from odyssey.domain.common import new_uuid7


class FakeBody(io.BytesIO):
    pass


class FakeS3Client:
    def __init__(self) -> None:
        self.objects: dict[str, tuple[bytes, dict[str, str], str]] = {}
        self.next_version = 1

    def head_bucket(self, **_: object) -> None:
        return None

    def get_bucket_versioning(self, **_: object) -> dict[str, str]:
        return {"Status": "Enabled"}

    def get_public_access_block(self, **_: object) -> dict[str, dict[str, bool]]:
        return {
            "PublicAccessBlockConfiguration": {
                "BlockPublicAcls": True,
                "IgnorePublicAcls": True,
                "BlockPublicPolicy": True,
                "RestrictPublicBuckets": True,
            }
        }

    def put_object(self, **arguments: Any) -> dict[str, str]:
        body = arguments["Body"]
        content = body if isinstance(body, bytes) else body.read()
        version = f"version-{self.next_version}"
        self.next_version += 1
        self.objects[str(arguments["Key"])] = (
            bytes(content),
            dict(arguments.get("Metadata", {})),
            version,
        )
        return {"VersionId": version}

    def get_object(self, **arguments: object) -> dict[str, FakeBody]:
        content, _metadata, _version = self.objects[str(arguments["Key"])]
        return {"Body": FakeBody(content)}

    def head_object(self, **arguments: object) -> dict[str, object]:
        key = str(arguments["Key"])
        if key not in self.objects:
            raise ClientError(
                {"Error": {"Code": "NoSuchKey", "Message": "missing"}},
                "HeadObject",
            )
        content, metadata, version = self.objects[key]
        return {
            "ContentLength": len(content),
            "Metadata": metadata,
            "VersionId": version,
        }

    def delete_objects(self, **arguments: Any) -> None:
        for item in arguments["Delete"]["Objects"]:
            self.objects.pop(str(item["Key"]), None)


class FakeGCSBlob:
    def __init__(self, bucket: "FakeGCSBucket", name: str) -> None:
        self.bucket = bucket
        self.name = name
        self.metadata: dict[str, str] | None = None
        self.size: int | None = None
        self.generation: int | None = None

    def exists(self) -> bool:
        return self.name in self.bucket.objects

    def reload(self) -> None:
        content, metadata, generation = self.bucket.objects[self.name]
        self.metadata = dict(metadata)
        self.size = len(content)
        self.generation = generation

    def upload_from_string(self, content: bytes, **_: object) -> None:
        self._store(content)

    def upload_from_file(self, source: Any, **_: object) -> None:
        self._store(bytes(source.read()))

    def download_as_bytes(self, **_: object) -> bytes:
        return self.bucket.objects[self.name][0]

    def delete(self) -> None:
        del self.bucket.objects[self.name]

    def _store(self, content: bytes) -> None:
        generation = self.bucket.next_generation
        self.bucket.next_generation += 1
        self.bucket.objects[self.name] = (content, dict(self.metadata or {}), generation)
        self.reload()


class FakeGCSBucket:
    def __init__(self) -> None:
        self.objects: dict[str, tuple[bytes, dict[str, str], int]] = {}
        self.next_generation = 1
        self.versioning_enabled = True
        self.default_kms_key_name = "synthetic-kms-key"
        self.iam_configuration = type(
            "IAMConfiguration",
            (),
            {"uniform_bucket_level_access_enabled": True},
        )()

    def reload(self) -> None:
        return None

    def blob(self, name: str, **_: object) -> FakeGCSBlob:
        return FakeGCSBlob(self, name)


class FakeGCSClient:
    def __init__(self) -> None:
        self.fake_bucket = FakeGCSBucket()

    def bucket(self, _name: str) -> FakeGCSBucket:
        return self.fake_bucket


def manifests(chunks: tuple[object, ...]) -> tuple[ChunkManifest, ...]:
    return tuple(
        ChunkManifest(
            index=index,
            storage_key=chunk.storage_key,
            content_sha256=chunk.content_sha256,
            byte_size=chunk.byte_size,
        )
        for index, chunk in enumerate(chunks)
    )


def test_s3_store_validates_assembles_and_tracks_version() -> None:
    fake = FakeS3Client()
    store = S3AttachmentStore(
        bucket_name="synthetic-attachments",
        region="us-east-1",
        server_side_encryption="AES256",
        client=fake,
    )
    upload_id = new_uuid7()
    content = b"first synthetic chunksecond synthetic chunk"

    async def scenario() -> None:
        await store.validate_configuration()
        chunks = (
            await store.write_chunk(upload_id, 0, b"first synthetic chunk"),
            await store.write_chunk(upload_id, 1, b"second synthetic chunk"),
        )
        stored = await store.assemble(
            upload_id,
            manifests(chunks),
            expected_content_sha256=sha256(content).hexdigest(),
            expected_byte_size=len(content),
        )
        assert stored.storage_backend == "s3"
        assert stored.bucket_name == "synthetic-attachments"
        assert stored.version_id == "version-3"
        assert await store.read_object(sha256(content).hexdigest()) == content

    asyncio.run(scenario())
    assert not any(key.startswith("uploads/") for key in fake.objects)


def test_gcs_store_validates_assembles_and_tracks_generation() -> None:
    fake = FakeGCSClient()
    store = GCSAttachmentStore(
        bucket_name="synthetic-attachments",
        kms_key_name="synthetic-kms-key",
        client=fake,
    )
    upload_id = new_uuid7()
    content = b"alpha-beta"

    async def scenario() -> None:
        await store.validate_configuration()
        chunks = (
            await store.write_chunk(upload_id, 0, b"alpha-"),
            await store.write_chunk(upload_id, 1, b"beta"),
        )
        stored = await store.assemble(
            upload_id,
            manifests(chunks),
            expected_content_sha256=sha256(content).hexdigest(),
            expected_byte_size=len(content),
        )
        assert stored.storage_backend == "gcs"
        assert stored.bucket_name == "synthetic-attachments"
        assert stored.version_id == "3"
        assert await store.read_object(sha256(content).hexdigest()) == content

    asyncio.run(scenario())
    assert not any(key.startswith("uploads/") for key in fake.fake_bucket.objects)


def test_storage_factory_keeps_tests_credential_free(tmp_path: Path) -> None:
    store = create_attachment_store(
        Settings(
            env=Environment.TEST,
            attachment_store_backend=AttachmentStoreBackend.LOCAL,
            attachment_storage_path=tmp_path,
        )
    )
    assert isinstance(store, LocalAttachmentStore)
