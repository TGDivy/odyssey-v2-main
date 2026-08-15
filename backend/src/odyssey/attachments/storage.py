"""Portable attachment storage contract and atomic local implementation."""

import asyncio
import os
import shutil
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from typing import Protocol
from uuid import UUID, uuid4


class AttachmentStorageError(RuntimeError):
    pass


class AttachmentObjectChecksumError(AttachmentStorageError):
    pass


@dataclass(frozen=True, slots=True)
class StoredChunk:
    storage_key: str
    content_sha256: str
    byte_size: int


@dataclass(frozen=True, slots=True)
class ChunkManifest:
    index: int
    storage_key: str
    content_sha256: str
    byte_size: int


@dataclass(frozen=True, slots=True)
class StoredObject:
    storage_key: str
    content_sha256: str
    byte_size: int
    storage_backend: str
    bucket_name: str | None = None
    version_id: str | None = None


class AttachmentStore(Protocol):
    @property
    def storage_backend(self) -> str: ...

    @property
    def bucket_name(self) -> str | None: ...

    async def validate_configuration(self) -> None: ...

    async def write_chunk(
        self,
        upload_id: UUID,
        chunk_index: int,
        content: bytes,
    ) -> StoredChunk: ...

    async def assemble(
        self,
        upload_id: UUID,
        chunks: tuple[ChunkManifest, ...],
        *,
        expected_content_sha256: str,
        expected_byte_size: int,
    ) -> StoredObject: ...

    async def read_object(self, content_sha256: str) -> bytes: ...

    async def write_object(self, content_sha256: str, content: bytes) -> StoredObject: ...


class LocalAttachmentStore:
    storage_backend = "local"
    bucket_name = None

    def __init__(self, root: Path) -> None:
        self.root = root

    async def validate_configuration(self) -> None:
        await asyncio.to_thread(self.root.mkdir, parents=True, exist_ok=True)

    async def write_chunk(self, upload_id: UUID, chunk_index: int, content: bytes) -> StoredChunk:
        return await asyncio.to_thread(self._write_chunk, upload_id, chunk_index, content)

    async def assemble(
        self,
        upload_id: UUID,
        chunks: tuple[ChunkManifest, ...],
        *,
        expected_content_sha256: str,
        expected_byte_size: int,
    ) -> StoredObject:
        return await asyncio.to_thread(
            self._assemble,
            upload_id,
            chunks,
            expected_content_sha256,
            expected_byte_size,
        )

    async def read_object(self, content_sha256: str) -> bytes:
        path = self.root / self.object_key(content_sha256)
        return await asyncio.to_thread(path.read_bytes)

    async def write_object(self, content_sha256: str, content: bytes) -> StoredObject:
        return await asyncio.to_thread(self._write_object, content_sha256, content)

    def _write_chunk(self, upload_id: UUID, chunk_index: int, content: bytes) -> StoredChunk:
        storage_key = self.chunk_key(upload_id, chunk_index)
        destination = self.root / storage_key
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(f".{destination.name}.{uuid4()}.tmp")
        try:
            with temporary.open("wb") as output:
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)
        return StoredChunk(
            storage_key=storage_key,
            content_sha256=sha256(content).hexdigest(),
            byte_size=len(content),
        )

    def _assemble(
        self,
        upload_id: UUID,
        chunks: tuple[ChunkManifest, ...],
        expected_content_sha256: str,
        expected_byte_size: int,
    ) -> StoredObject:
        storage_key = self.object_key(expected_content_sha256)
        destination = self.root / storage_key
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            content = destination.read_bytes()
            if (
                len(content) != expected_byte_size
                or sha256(content).hexdigest() != expected_content_sha256
            ):
                raise AttachmentObjectChecksumError("existing content-addressed object is invalid")
            self._remove_upload(upload_id)
            return StoredObject(
                storage_key,
                expected_content_sha256,
                expected_byte_size,
                self.storage_backend,
            )

        temporary = destination.with_name(f".{destination.name}.{upload_id}.assembling")
        digest = sha256()
        total_bytes = 0
        try:
            with temporary.open("wb") as output:
                for expected_index, chunk in enumerate(chunks):
                    if chunk.index != expected_index:
                        raise AttachmentStorageError("chunk manifest is not contiguous")
                    chunk_path = self.root / chunk.storage_key
                    content = chunk_path.read_bytes()
                    if (
                        len(content) != chunk.byte_size
                        or sha256(content).hexdigest() != chunk.content_sha256
                    ):
                        raise AttachmentObjectChecksumError("stored upload chunk is invalid")
                    output.write(content)
                    digest.update(content)
                    total_bytes += len(content)
                output.flush()
                os.fsync(output.fileno())
            if total_bytes != expected_byte_size or digest.hexdigest() != expected_content_sha256:
                raise AttachmentObjectChecksumError(
                    "assembled object checksum does not match metadata"
                )
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)
        self._remove_upload(upload_id)
        return StoredObject(
            storage_key,
            expected_content_sha256,
            expected_byte_size,
            self.storage_backend,
        )

    def _remove_upload(self, upload_id: UUID) -> None:
        shutil.rmtree(self.root / "uploads" / str(upload_id), ignore_errors=True)

    def _write_object(self, content_sha256: str, content: bytes) -> StoredObject:
        if sha256(content).hexdigest() != content_sha256:
            raise AttachmentObjectChecksumError("object content does not match its hash")
        storage_key = self.object_key(content_sha256)
        destination = self.root / storage_key
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            existing = destination.read_bytes()
            if existing != content:
                raise AttachmentObjectChecksumError("existing content-addressed object is invalid")
        else:
            temporary = destination.with_name(f".{destination.name}.{uuid4()}.tmp")
            try:
                with temporary.open("wb") as output:
                    output.write(content)
                    output.flush()
                    os.fsync(output.fileno())
                temporary.replace(destination)
            finally:
                temporary.unlink(missing_ok=True)
        return StoredObject(
            storage_key=storage_key,
            content_sha256=content_sha256,
            byte_size=len(content),
            storage_backend=self.storage_backend,
        )

    @staticmethod
    def chunk_key(upload_id: UUID, chunk_index: int) -> str:
        return f"uploads/{upload_id}/{chunk_index:08d}.part"

    @staticmethod
    def object_key(content_sha256: str) -> str:
        return f"objects/sha256/{content_sha256[:2]}/{content_sha256}"
