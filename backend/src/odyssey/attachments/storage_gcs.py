"""Google Cloud Storage attachment backend using workload identity credentials."""

import asyncio
import tempfile
from hashlib import sha256
from typing import Any
from uuid import UUID

from google.api_core.exceptions import NotFound, PreconditionFailed
from google.cloud import storage

from odyssey.attachments.storage import (
    AttachmentObjectChecksumError,
    AttachmentStorageError,
    ChunkManifest,
    LocalAttachmentStore,
    StoredChunk,
    StoredObject,
)

SPOOL_MEMORY_BYTES = 32 * 1024 * 1024


class GCSAttachmentStore:
    storage_backend = "gcs"

    def __init__(
        self,
        *,
        bucket_name: str,
        project_id: str | None = None,
        kms_key_name: str | None = None,
        require_versioning: bool = True,
        require_uniform_bucket_access: bool = True,
        client: Any | None = None,
    ) -> None:
        if not bucket_name:
            raise ValueError("GCS attachment storage requires a bucket")
        self.bucket_name = bucket_name
        self.kms_key_name = kms_key_name
        self.require_versioning = require_versioning
        self.require_uniform_bucket_access = require_uniform_bucket_access
        self.client = client or storage.Client(project=project_id)
        self.bucket = self.client.bucket(bucket_name)

    async def validate_configuration(self) -> None:
        await asyncio.to_thread(self._validate_configuration)

    async def write_chunk(self, upload_id: UUID, chunk_index: int, content: bytes) -> StoredChunk:
        try:
            return await asyncio.to_thread(self._write_chunk, upload_id, chunk_index, content)
        except AttachmentStorageError:
            raise
        except Exception as error:
            raise AttachmentStorageError("GCS chunk upload failed") from error

    async def assemble(
        self,
        upload_id: UUID,
        chunks: tuple[ChunkManifest, ...],
        *,
        expected_content_sha256: str,
        expected_byte_size: int,
    ) -> StoredObject:
        try:
            return await asyncio.to_thread(
                self._assemble,
                upload_id,
                chunks,
                expected_content_sha256,
                expected_byte_size,
            )
        except AttachmentStorageError:
            raise
        except Exception as error:
            raise AttachmentStorageError("GCS object assembly failed") from error

    async def read_object(self, content_sha256: str) -> bytes:
        try:
            return await asyncio.to_thread(self._read_object, content_sha256)
        except AttachmentStorageError:
            raise
        except Exception as error:
            raise AttachmentStorageError("GCS object read failed") from error

    async def write_object(self, content_sha256: str, content: bytes) -> StoredObject:
        try:
            return await asyncio.to_thread(self._write_object, content_sha256, content)
        except AttachmentStorageError:
            raise
        except Exception as error:
            raise AttachmentStorageError("GCS object write failed") from error

    def _validate_configuration(self) -> None:
        self.bucket.reload()
        if self.require_versioning and not self.bucket.versioning_enabled:
            raise AttachmentStorageError("GCS attachment bucket versioning is not enabled")
        if (
            self.require_uniform_bucket_access
            and not self.bucket.iam_configuration.uniform_bucket_level_access_enabled
        ):
            raise AttachmentStorageError("GCS attachment bucket does not enforce uniform access")
        if self.kms_key_name and self.bucket.default_kms_key_name != self.kms_key_name:
            raise AttachmentStorageError(
                "GCS attachment bucket does not use the configured KMS key"
            )

    def _write_chunk(self, upload_id: UUID, chunk_index: int, content: bytes) -> StoredChunk:
        storage_key = LocalAttachmentStore.chunk_key(upload_id, chunk_index)
        content_hash = sha256(content).hexdigest()
        blob = self._blob(storage_key)
        blob.metadata = {"content-sha256": content_hash}
        try:
            blob.upload_from_string(content, if_generation_match=0, checksum="crc32c")
        except PreconditionFailed:
            existing = blob.download_as_bytes(checksum="crc32c")
            if existing != content:
                raise AttachmentObjectChecksumError(
                    "existing GCS chunk content is invalid"
                ) from None
        return StoredChunk(
            storage_key=storage_key,
            content_sha256=content_hash,
            byte_size=len(content),
        )

    def _assemble(
        self,
        upload_id: UUID,
        chunks: tuple[ChunkManifest, ...],
        expected_content_sha256: str,
        expected_byte_size: int,
    ) -> StoredObject:
        storage_key = LocalAttachmentStore.object_key(expected_content_sha256)
        destination = self._blob(storage_key)
        if destination.exists():
            destination.reload()
            self._validate_blob(
                destination,
                expected_content_sha256=expected_content_sha256,
                expected_byte_size=expected_byte_size,
            )
            self._remove_chunks(chunks)
            return self._stored_object(destination, expected_content_sha256, expected_byte_size)

        digest = sha256()
        total_bytes = 0
        with tempfile.SpooledTemporaryFile(max_size=SPOOL_MEMORY_BYTES, mode="w+b") as assembled:
            for expected_index, chunk in enumerate(chunks):
                if chunk.index != expected_index:
                    raise AttachmentStorageError("chunk manifest is not contiguous")
                content = self._blob(chunk.storage_key).download_as_bytes(checksum="crc32c")
                if (
                    len(content) != chunk.byte_size
                    or sha256(content).hexdigest() != chunk.content_sha256
                ):
                    raise AttachmentObjectChecksumError("stored GCS upload chunk is invalid")
                assembled.write(content)
                digest.update(content)
                total_bytes += len(content)
            if total_bytes != expected_byte_size or digest.hexdigest() != expected_content_sha256:
                raise AttachmentObjectChecksumError(
                    "assembled GCS object checksum does not match metadata"
                )
            assembled.seek(0)
            destination.metadata = {"content-sha256": expected_content_sha256}
            try:
                destination.upload_from_file(
                    assembled,
                    size=expected_byte_size,
                    rewind=True,
                    if_generation_match=0,
                    checksum="crc32c",
                )
            except PreconditionFailed:
                destination.reload()
                self._validate_blob(
                    destination,
                    expected_content_sha256=expected_content_sha256,
                    expected_byte_size=expected_byte_size,
                )
        destination.reload()
        self._remove_chunks(chunks)
        return self._stored_object(destination, expected_content_sha256, expected_byte_size)

    def _read_object(self, content_sha256: str) -> bytes:
        storage_key = LocalAttachmentStore.object_key(content_sha256)
        try:
            content = bytes(self._blob(storage_key).download_as_bytes(checksum="crc32c"))
        except NotFound as error:
            raise AttachmentStorageError("GCS object does not exist") from error
        if sha256(content).hexdigest() != content_sha256:
            raise AttachmentObjectChecksumError("stored GCS object checksum is invalid")
        return content

    def _write_object(self, content_sha256: str, content: bytes) -> StoredObject:
        if sha256(content).hexdigest() != content_sha256:
            raise AttachmentObjectChecksumError("object content does not match its hash")
        storage_key = LocalAttachmentStore.object_key(content_sha256)
        blob = self._blob(storage_key)
        if blob.exists():
            blob.reload()
            self._validate_blob(
                blob,
                expected_content_sha256=content_sha256,
                expected_byte_size=len(content),
            )
        else:
            blob.metadata = {"content-sha256": content_sha256}
            try:
                blob.upload_from_string(content, if_generation_match=0, checksum="crc32c")
            except PreconditionFailed:
                blob.reload()
                self._validate_blob(
                    blob,
                    expected_content_sha256=content_sha256,
                    expected_byte_size=len(content),
                )
        blob.reload()
        return self._stored_object(blob, content_sha256, len(content))

    def _blob(self, storage_key: str) -> Any:
        return self.bucket.blob(storage_key, kms_key_name=self.kms_key_name)

    def _remove_chunks(self, chunks: tuple[ChunkManifest, ...]) -> None:
        for chunk in chunks:
            try:
                self._blob(chunk.storage_key).delete()
            except NotFound:
                continue

    @staticmethod
    def _validate_blob(
        blob: Any,
        *,
        expected_content_sha256: str,
        expected_byte_size: int,
    ) -> None:
        metadata = blob.metadata or {}
        if blob.size != expected_byte_size or metadata.get("content-sha256") != (
            expected_content_sha256
        ):
            raise AttachmentObjectChecksumError("existing GCS object metadata is invalid")

    def _stored_object(
        self,
        blob: Any,
        content_sha256: str,
        byte_size: int,
    ) -> StoredObject:
        return StoredObject(
            storage_key=blob.name,
            content_sha256=content_sha256,
            byte_size=byte_size,
            storage_backend=self.storage_backend,
            bucket_name=self.bucket_name,
            version_id=str(blob.generation) if blob.generation is not None else None,
        )
