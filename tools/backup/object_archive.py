#!/usr/bin/env python3
"""Copy, verify, or restore the attachment object archive."""

import argparse
import asyncio
import json
import os
from pathlib import Path

from odyssey.attachments.backups import (
    create_object_archive,
    load_object_archive_manifest,
    object_archive_manifest_bytes,
    restore_object_archive,
    verify_object_archive,
    write_object_archive_manifest,
)
from odyssey.attachments.storage import AttachmentStore, LocalAttachmentStore
from odyssey.attachments.storage_factory import create_attachment_store
from odyssey.attachments.storage_gcs import GCSAttachmentStore
from odyssey.attachments.storage_s3 import S3AttachmentStore
from odyssey.config import AttachmentStoreBackend, get_settings
from odyssey.db.session import Database


def archive_store(arguments: argparse.Namespace) -> AttachmentStore:
    backend = AttachmentStoreBackend(arguments.archive_backend)
    if backend is AttachmentStoreBackend.LOCAL:
        if arguments.archive_path is None:
            raise ValueError("local object archives require --archive-path")
        if not arguments.allow_plaintext_local_archive:
            raise ValueError(
                "local object archives are plaintext; pass explicit local-only approval"
            )
        return LocalAttachmentStore(arguments.archive_path)
    if not arguments.archive_bucket:
        raise ValueError("cloud object archives require --archive-bucket")
    if backend is AttachmentStoreBackend.GCS:
        return GCSAttachmentStore(
            bucket_name=arguments.archive_bucket,
            project_id=arguments.archive_project,
            kms_key_name=arguments.archive_kms_key,
        )
    access_key = os.environ.get("ODYSSEY_ARCHIVE_STORAGE_ACCESS_KEY") or None
    secret_key = os.environ.get("ODYSSEY_ARCHIVE_STORAGE_SECRET_KEY") or None
    return S3AttachmentStore(
        bucket_name=arguments.archive_bucket,
        region=arguments.archive_region,
        endpoint_url=arguments.archive_endpoint,
        access_key=access_key,
        secret_key=secret_key,
        force_path_style=arguments.archive_force_path_style,
        server_side_encryption=arguments.archive_sse,
        kms_key_id=arguments.archive_kms_key,
    )


async def run(arguments: argparse.Namespace) -> int:
    settings = get_settings()
    archive = archive_store(arguments)
    if arguments.action == "verify":
        envelope = load_object_archive_manifest(arguments.manifest)
        report = await verify_object_archive(archive=archive, envelope=envelope)
        print(json.dumps(report.model_dump(mode="json"), indent=2, sort_keys=True))
        return 0

    database = Database(arguments.database_url or settings.database_url)
    active = create_attachment_store(settings)
    try:
        if arguments.action == "backup":
            async with database.sessions() as session:
                envelope = await create_object_archive(
                    session,
                    source=active,
                    archive=archive,
                )
            write_object_archive_manifest(arguments.manifest, envelope)
            archived_manifest = await archive.write_object(
                envelope.manifest_sha256,
                object_archive_manifest_bytes(envelope.manifest),
            )
            output = {
                "action": "backup",
                "manifest": str(arguments.manifest),
                "manifest_sha256": envelope.manifest_sha256,
                "manifest_archive_storage_key": archived_manifest.storage_key,
                "manifest_archive_version_id": archived_manifest.version_id,
                "object_count": envelope.manifest.object_count,
                "total_bytes": envelope.manifest.total_bytes,
            }
        else:
            envelope = load_object_archive_manifest(arguments.manifest)
            async with database.sessions() as session:
                report = await restore_object_archive(
                    session,
                    archive=archive,
                    destination=active,
                    envelope=envelope,
                )
            output = report.model_dump(mode="json")
        print(json.dumps(output, indent=2, sort_keys=True))
        return 0
    finally:
        await database.dispose()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("backup", "verify", "restore"))
    parser.add_argument("--database-url")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--archive-backend",
        choices=[backend.value for backend in AttachmentStoreBackend],
        required=True,
    )
    parser.add_argument("--archive-path", type=Path)
    parser.add_argument("--archive-bucket")
    parser.add_argument("--archive-project")
    parser.add_argument("--archive-region", default="us-east-1")
    parser.add_argument("--archive-endpoint")
    parser.add_argument("--archive-force-path-style", action="store_true")
    parser.add_argument("--archive-sse", choices=("AES256", "aws:kms"))
    parser.add_argument("--archive-kms-key")
    parser.add_argument("--allow-plaintext-local-archive", action="store_true")
    arguments = parser.parse_args()
    raise SystemExit(asyncio.run(run(arguments)))


if __name__ == "__main__":
    main()
