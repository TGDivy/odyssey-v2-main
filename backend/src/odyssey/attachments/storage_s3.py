"""S3-compatible attachment storage for MinIO and IAM-backed deployments."""

import asyncio
import tempfile
from hashlib import sha256
from typing import Any, cast
from uuid import UUID

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

from odyssey.attachments.storage import (
    AttachmentObjectChecksumError,
    AttachmentStorageError,
    ChunkManifest,
    LocalAttachmentStore,
    StoredChunk,
    StoredObject,
)

SPOOL_MEMORY_BYTES = 32 * 1024 * 1024


class S3AttachmentStore:
    storage_backend = "s3"

    def __init__(
        self,
        *,
        bucket_name: str,
        region: str,
        endpoint_url: str | None = None,
        access_key: str | None = None,
        secret_key: str | None = None,
        force_path_style: bool = False,
        server_side_encryption: str | None = None,
        kms_key_id: str | None = None,
        require_versioning: bool = True,
        require_public_access_block: bool = True,
        client: Any | None = None,
    ) -> None:
        if not bucket_name:
            raise ValueError("S3 attachment storage requires a bucket")
        if (access_key is None) != (secret_key is None):
            raise ValueError("S3 static access key and secret must be configured together")
        if kms_key_id and server_side_encryption != "aws:kms":
            raise ValueError("an S3 KMS key requires aws:kms server-side encryption")
        self.bucket_name = bucket_name
        self.require_versioning = require_versioning
        self.require_public_access_block = require_public_access_block
        self.server_side_encryption = server_side_encryption
        self.kms_key_id = kms_key_id
        self.client = client or boto3.client(
            "s3",
            region_name=region,
            endpoint_url=endpoint_url,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            config=Config(
                signature_version="s3v4",
                s3={"addressing_style": "path" if force_path_style else "auto"},
            ),
        )

    async def validate_configuration(self) -> None:
        await asyncio.to_thread(self._validate_configuration)

    async def write_chunk(self, upload_id: UUID, chunk_index: int, content: bytes) -> StoredChunk:
        try:
            return await asyncio.to_thread(self._write_chunk, upload_id, chunk_index, content)
        except AttachmentStorageError:
            raise
        except Exception as error:
            raise AttachmentStorageError("S3 chunk upload failed") from error

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
            raise AttachmentStorageError("S3 object assembly failed") from error

    async def read_object(self, content_sha256: str) -> bytes:
        try:
            return await asyncio.to_thread(self._read_object, content_sha256)
        except AttachmentStorageError:
            raise
        except Exception as error:
            raise AttachmentStorageError("S3 object read failed") from error

    async def write_object(self, content_sha256: str, content: bytes) -> StoredObject:
        try:
            return await asyncio.to_thread(self._write_object, content_sha256, content)
        except AttachmentStorageError:
            raise
        except Exception as error:
            raise AttachmentStorageError("S3 object write failed") from error

    def _validate_configuration(self) -> None:
        self.client.head_bucket(Bucket=self.bucket_name)
        if self.require_versioning:
            versioning = self.client.get_bucket_versioning(Bucket=self.bucket_name)
            if versioning.get("Status") != "Enabled":
                raise AttachmentStorageError("S3 attachment bucket versioning is not enabled")
        if self.require_public_access_block:
            public_access = self.client.get_public_access_block(Bucket=self.bucket_name)
            configuration = public_access.get("PublicAccessBlockConfiguration", {})
            required = (
                "BlockPublicAcls",
                "IgnorePublicAcls",
                "BlockPublicPolicy",
                "RestrictPublicBuckets",
            )
            if not all(configuration.get(key) is True for key in required):
                raise AttachmentStorageError("S3 attachment bucket permits public access")

    def _write_chunk(self, upload_id: UUID, chunk_index: int, content: bytes) -> StoredChunk:
        storage_key = LocalAttachmentStore.chunk_key(upload_id, chunk_index)
        content_hash = sha256(content).hexdigest()
        existing = self._head_object(storage_key)
        if existing is not None:
            self._validate_object_metadata(
                existing,
                expected_content_sha256=content_hash,
                expected_byte_size=len(content),
            )
            return StoredChunk(
                storage_key=storage_key,
                content_sha256=content_hash,
                byte_size=len(content),
            )
        self.client.put_object(
            Bucket=self.bucket_name,
            Key=storage_key,
            Body=content,
            ContentLength=len(content),
            Metadata={"content-sha256": content_hash},
            **self._encryption_arguments(),
        )
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
        existing = self._head_object(storage_key)
        if existing is not None:
            self._validate_object_metadata(
                existing,
                expected_content_sha256=expected_content_sha256,
                expected_byte_size=expected_byte_size,
            )
            self._remove_chunks(chunks)
            return StoredObject(
                storage_key=storage_key,
                content_sha256=expected_content_sha256,
                byte_size=expected_byte_size,
                storage_backend=self.storage_backend,
                bucket_name=self.bucket_name,
                version_id=self._version_id(existing),
            )

        digest = sha256()
        total_bytes = 0
        with tempfile.SpooledTemporaryFile(max_size=SPOOL_MEMORY_BYTES, mode="w+b") as assembled:
            for expected_index, chunk in enumerate(chunks):
                if chunk.index != expected_index:
                    raise AttachmentStorageError("chunk manifest is not contiguous")
                response = self.client.get_object(Bucket=self.bucket_name, Key=chunk.storage_key)
                body = response["Body"]
                try:
                    content = body.read()
                finally:
                    body.close()
                if (
                    len(content) != chunk.byte_size
                    or sha256(content).hexdigest() != chunk.content_sha256
                ):
                    raise AttachmentObjectChecksumError("stored S3 upload chunk is invalid")
                assembled.write(content)
                digest.update(content)
                total_bytes += len(content)
            if total_bytes != expected_byte_size or digest.hexdigest() != expected_content_sha256:
                raise AttachmentObjectChecksumError(
                    "assembled S3 object checksum does not match metadata"
                )
            assembled.seek(0)
            response = self.client.put_object(
                Bucket=self.bucket_name,
                Key=storage_key,
                Body=assembled,
                ContentLength=expected_byte_size,
                Metadata={"content-sha256": expected_content_sha256},
                **self._encryption_arguments(),
            )
        self._remove_chunks(chunks)
        return StoredObject(
            storage_key=storage_key,
            content_sha256=expected_content_sha256,
            byte_size=expected_byte_size,
            storage_backend=self.storage_backend,
            bucket_name=self.bucket_name,
            version_id=self._version_id(response),
        )

    def _read_object(self, content_sha256: str) -> bytes:
        storage_key = LocalAttachmentStore.object_key(content_sha256)
        response = self.client.get_object(Bucket=self.bucket_name, Key=storage_key)
        body = response["Body"]
        try:
            content = bytes(body.read())
        finally:
            body.close()
        if sha256(content).hexdigest() != content_sha256:
            raise AttachmentObjectChecksumError("stored S3 object checksum is invalid")
        return content

    def _write_object(self, content_sha256: str, content: bytes) -> StoredObject:
        if sha256(content).hexdigest() != content_sha256:
            raise AttachmentObjectChecksumError("object content does not match its hash")
        storage_key = LocalAttachmentStore.object_key(content_sha256)
        existing = self._head_object(storage_key)
        if existing is not None:
            self._validate_object_metadata(
                existing,
                expected_content_sha256=content_sha256,
                expected_byte_size=len(content),
            )
            response = existing
        else:
            response = self.client.put_object(
                Bucket=self.bucket_name,
                Key=storage_key,
                Body=content,
                ContentLength=len(content),
                Metadata={"content-sha256": content_sha256},
                **self._encryption_arguments(),
            )
        return StoredObject(
            storage_key=storage_key,
            content_sha256=content_sha256,
            byte_size=len(content),
            storage_backend=self.storage_backend,
            bucket_name=self.bucket_name,
            version_id=self._version_id(response),
        )

    def _head_object(self, storage_key: str) -> dict[str, Any] | None:
        try:
            return cast(
                dict[str, Any],
                self.client.head_object(Bucket=self.bucket_name, Key=storage_key),
            )
        except ClientError as error:
            code = str(error.response.get("Error", {}).get("Code", ""))
            if code in {"404", "NoSuchKey", "NotFound"}:
                return None
            raise

    @staticmethod
    def _validate_object_metadata(
        metadata: dict[str, Any],
        *,
        expected_content_sha256: str,
        expected_byte_size: int,
    ) -> None:
        stored_hash = metadata.get("Metadata", {}).get("content-sha256")
        if metadata.get("ContentLength") != expected_byte_size or stored_hash != (
            expected_content_sha256
        ):
            raise AttachmentObjectChecksumError("existing S3 object metadata is invalid")

    def _remove_chunks(self, chunks: tuple[ChunkManifest, ...]) -> None:
        if not chunks:
            return
        self.client.delete_objects(
            Bucket=self.bucket_name,
            Delete={"Objects": [{"Key": chunk.storage_key} for chunk in chunks], "Quiet": True},
        )

    def _encryption_arguments(self) -> dict[str, str]:
        if self.server_side_encryption is None:
            return {}
        arguments = {"ServerSideEncryption": self.server_side_encryption}
        if self.kms_key_id is not None:
            arguments["SSEKMSKeyId"] = self.kms_key_id
        return arguments

    @staticmethod
    def _version_id(response: dict[str, Any]) -> str | None:
        value = response.get("VersionId")
        return str(value) if value is not None else None
