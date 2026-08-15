"""Manifest-verified attachment object backup and clean-room restoration."""

import json
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path

from pydantic import AwareDatetime, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.attachments.models import AttachmentObjectRecord
from odyssey.attachments.storage import AttachmentStore
from odyssey.db.backups import write_private
from odyssey.domain.common import StrictModel

OBJECT_ARCHIVE_FORMAT = "odyssey-object-archive.v1"


class ObjectArchiveError(RuntimeError):
    pass


class ObjectArchiveEntry(StrictModel):
    content_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    byte_size: int = Field(ge=0)
    source_storage_backend: str
    source_bucket_name: str | None
    source_storage_key: str
    source_version_id: str | None
    archive_storage_backend: str
    archive_bucket_name: str | None
    archive_storage_key: str
    archive_version_id: str | None


class ObjectArchiveManifest(StrictModel):
    format: str = OBJECT_ARCHIVE_FORMAT
    created_at: AwareDatetime
    object_count: int = Field(ge=0)
    total_bytes: int = Field(ge=0)
    entries: tuple[ObjectArchiveEntry, ...]


class ObjectArchiveEnvelope(StrictModel):
    manifest_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    manifest: ObjectArchiveManifest


class ObjectArchiveCopyReport(StrictModel):
    operation: str
    completed_at: AwareDatetime
    manifest_sha256: str
    object_count: int = Field(ge=0)
    total_bytes: int = Field(ge=0)
    destination_storage_backend: str
    destination_bucket_name: str | None
    verified: bool


def _manifest_hash(manifest: ObjectArchiveManifest) -> str:
    return sha256(object_archive_manifest_bytes(manifest)).hexdigest()


def object_archive_manifest_bytes(manifest: ObjectArchiveManifest) -> bytes:
    return json.dumps(
        manifest.model_dump(mode="json"),
        separators=(",", ":"),
        sort_keys=True,
    ).encode()


def write_object_archive_manifest(path: Path, envelope: ObjectArchiveEnvelope) -> None:
    if path.exists():
        raise ObjectArchiveError(f"object archive manifest already exists: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    content = (
        json.dumps(envelope.model_dump(mode="json"), indent=2, sort_keys=True) + "\n"
    ).encode()
    write_private(path, content)


def load_object_archive_manifest(path: Path) -> ObjectArchiveEnvelope:
    if not path.is_file():
        raise ObjectArchiveError(f"object archive manifest does not exist: {path}")
    try:
        envelope = ObjectArchiveEnvelope.model_validate_json(path.read_bytes())
    except ValueError as error:
        raise ObjectArchiveError("object archive manifest is invalid") from error
    if envelope.manifest.format != OBJECT_ARCHIVE_FORMAT:
        raise ObjectArchiveError("object archive format is unsupported")
    if _manifest_hash(envelope.manifest) != envelope.manifest_sha256:
        raise ObjectArchiveError("object archive manifest hash does not match")
    if envelope.manifest.object_count != len(envelope.manifest.entries):
        raise ObjectArchiveError("object archive count does not match its entries")
    if envelope.manifest.total_bytes != sum(entry.byte_size for entry in envelope.manifest.entries):
        raise ObjectArchiveError("object archive byte count does not match its entries")
    hashes = [entry.content_sha256 for entry in envelope.manifest.entries]
    if hashes != sorted(set(hashes)):
        raise ObjectArchiveError("object archive entries are not unique and sorted")
    return envelope


async def create_object_archive(
    session: AsyncSession,
    *,
    source: AttachmentStore,
    archive: AttachmentStore,
    created_at: datetime | None = None,
) -> ObjectArchiveEnvelope:
    await source.validate_configuration()
    await archive.validate_configuration()
    records = tuple(
        (
            await session.scalars(
                select(AttachmentObjectRecord).order_by(AttachmentObjectRecord.content_sha256)
            )
        ).all()
    )
    entries: list[ObjectArchiveEntry] = []
    for record in records:
        if record.storage_backend != source.storage_backend:
            raise ObjectArchiveError(
                f"object {record.content_sha256} belongs to storage backend "
                f"{record.storage_backend}, not {source.storage_backend}"
            )
        if record.bucket_name is not None and record.bucket_name != source.bucket_name:
            raise ObjectArchiveError(
                f"object {record.content_sha256} belongs to another storage bucket"
            )
        content = await source.read_object(record.content_sha256)
        _verify_content(record.content_sha256, record.byte_size, content)
        archived = await archive.write_object(record.content_sha256, content)
        entries.append(
            ObjectArchiveEntry(
                content_sha256=record.content_sha256,
                byte_size=record.byte_size,
                source_storage_backend=record.storage_backend,
                source_bucket_name=record.bucket_name,
                source_storage_key=record.storage_key,
                source_version_id=record.object_version_id,
                archive_storage_backend=archived.storage_backend,
                archive_bucket_name=archived.bucket_name,
                archive_storage_key=archived.storage_key,
                archive_version_id=archived.version_id,
            )
        )
    manifest = ObjectArchiveManifest(
        created_at=created_at or datetime.now(UTC),
        object_count=len(entries),
        total_bytes=sum(entry.byte_size for entry in entries),
        entries=tuple(entries),
    )
    return ObjectArchiveEnvelope(
        manifest_sha256=_manifest_hash(manifest),
        manifest=manifest,
    )


async def verify_object_archive(
    *,
    archive: AttachmentStore,
    envelope: ObjectArchiveEnvelope,
    verified_at: datetime | None = None,
) -> ObjectArchiveCopyReport:
    _validate_envelope(envelope)
    await archive.validate_configuration()
    for entry in envelope.manifest.entries:
        if entry.archive_storage_backend != archive.storage_backend:
            raise ObjectArchiveError(
                f"archive object {entry.content_sha256} belongs to another backend"
            )
        if entry.archive_bucket_name is not None and (
            entry.archive_bucket_name != archive.bucket_name
        ):
            raise ObjectArchiveError(
                f"archive object {entry.content_sha256} belongs to another bucket"
            )
        content = await archive.read_object(entry.content_sha256)
        _verify_content(entry.content_sha256, entry.byte_size, content)
    return ObjectArchiveCopyReport(
        operation="verify",
        completed_at=verified_at or datetime.now(UTC),
        manifest_sha256=envelope.manifest_sha256,
        object_count=envelope.manifest.object_count,
        total_bytes=envelope.manifest.total_bytes,
        destination_storage_backend=archive.storage_backend,
        destination_bucket_name=archive.bucket_name,
        verified=True,
    )


async def restore_object_archive(
    session: AsyncSession,
    *,
    archive: AttachmentStore,
    destination: AttachmentStore,
    envelope: ObjectArchiveEnvelope,
    restored_at: datetime | None = None,
) -> ObjectArchiveCopyReport:
    _validate_envelope(envelope)
    await archive.validate_configuration()
    await destination.validate_configuration()
    records = {
        record.content_sha256: record
        for record in (
            await session.scalars(
                select(AttachmentObjectRecord).order_by(AttachmentObjectRecord.content_sha256)
            )
        ).all()
    }
    manifest_hashes = {entry.content_sha256 for entry in envelope.manifest.entries}
    if set(records) != manifest_hashes:
        raise ObjectArchiveError(
            "restored database object manifest does not match the object archive"
        )
    for entry in envelope.manifest.entries:
        record = records[entry.content_sha256]
        if record.byte_size != entry.byte_size:
            raise ObjectArchiveError(
                f"database metadata disagrees with archive object {entry.content_sha256}"
            )
        content = await archive.read_object(entry.content_sha256)
        _verify_content(entry.content_sha256, entry.byte_size, content)
        restored = await destination.write_object(entry.content_sha256, content)
        if restored.byte_size != entry.byte_size:
            raise ObjectArchiveError(
                f"restored object {entry.content_sha256} has an unexpected size"
            )
    return ObjectArchiveCopyReport(
        operation="restore",
        completed_at=restored_at or datetime.now(UTC),
        manifest_sha256=envelope.manifest_sha256,
        object_count=envelope.manifest.object_count,
        total_bytes=envelope.manifest.total_bytes,
        destination_storage_backend=destination.storage_backend,
        destination_bucket_name=destination.bucket_name,
        verified=True,
    )


def _validate_envelope(envelope: ObjectArchiveEnvelope) -> None:
    if envelope.manifest.format != OBJECT_ARCHIVE_FORMAT:
        raise ObjectArchiveError("object archive format is unsupported")
    if _manifest_hash(envelope.manifest) != envelope.manifest_sha256:
        raise ObjectArchiveError("object archive manifest hash does not match")


def _verify_content(content_sha256: str, byte_size: int, content: bytes) -> None:
    if len(content) != byte_size or sha256(content).hexdigest() != content_sha256:
        raise ObjectArchiveError(f"object {content_sha256} failed size or hash verification")
