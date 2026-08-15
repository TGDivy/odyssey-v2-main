#!/usr/bin/env python3
"""Restore a native backup into an empty target and validate recovery."""

import argparse
import json
from pathlib import Path

from odyssey.attachments.backups import load_object_archive_manifest
from odyssey.attachments.storage import AttachmentStore, LocalAttachmentStore
from odyssey.attachments.storage_gcs import GCSAttachmentStore
from odyssey.db.restores import clean_room_restore

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def object_store(
    *,
    role: str,
    backend: str,
    local_path: Path | None,
    bucket_name: str | None,
    project_id: str | None,
    kms_key_name: str | None,
    allow_plaintext_local: bool,
) -> AttachmentStore:
    if backend == "local":
        if local_path is None:
            raise ValueError(f"local {role} requires its path argument")
        if any(value is not None for value in (bucket_name, project_id, kms_key_name)):
            raise ValueError(f"local {role} cannot use GCS arguments")
        if not allow_plaintext_local:
            raise ValueError("local object storage is plaintext; pass explicit local-only approval")
        return LocalAttachmentStore(local_path)
    if local_path is not None:
        raise ValueError(f"GCS {role} cannot use a local path")
    if bucket_name is None or kms_key_name is None:
        raise ValueError(f"GCS {role} requires bucket and KMS key arguments")
    return GCSAttachmentStore(
        bucket_name=bucket_name,
        project_id=project_id,
        kms_key_name=kms_key_name,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backup", type=Path, required=True)
    parser.add_argument("--database-url", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--object-manifest", type=Path)
    parser.add_argument("--object-archive-backend", choices=("local", "gcs"))
    parser.add_argument("--object-archive-path", type=Path)
    parser.add_argument("--object-archive-bucket")
    parser.add_argument("--object-archive-project")
    parser.add_argument("--object-archive-kms-key")
    parser.add_argument("--object-restore-backend", choices=("local", "gcs"))
    parser.add_argument("--object-restore-path", type=Path)
    parser.add_argument("--object-restore-bucket")
    parser.add_argument("--object-restore-project")
    parser.add_argument("--object-restore-kms-key")
    parser.add_argument(
        "--allow-plaintext-local-objects",
        "--allow-plaintext-local-object-archive",
        dest="allow_plaintext_local_objects",
        action="store_true",
    )
    arguments = parser.parse_args()
    archive_backend = arguments.object_archive_backend or (
        "local" if arguments.object_archive_path is not None else None
    )
    restore_backend = arguments.object_restore_backend or (
        "local" if arguments.object_restore_path is not None else None
    )
    object_arguments = (
        arguments.object_manifest,
        archive_backend,
        arguments.object_archive_path,
        arguments.object_archive_bucket,
        arguments.object_archive_project,
        arguments.object_archive_kms_key,
        restore_backend,
        arguments.object_restore_path,
        arguments.object_restore_bucket,
        arguments.object_restore_project,
        arguments.object_restore_kms_key,
    )
    archive: AttachmentStore | None = None
    destination: AttachmentStore | None = None
    if any(value is not None for value in object_arguments):
        if arguments.object_manifest is None or archive_backend is None or restore_backend is None:
            parser.error("object restore requires --object-manifest and archive/restore backends")
        try:
            archive = object_store(
                role="object archive",
                backend=archive_backend,
                local_path=arguments.object_archive_path,
                bucket_name=arguments.object_archive_bucket,
                project_id=arguments.object_archive_project,
                kms_key_name=arguments.object_archive_kms_key,
                allow_plaintext_local=arguments.allow_plaintext_local_objects,
            )
            destination = object_store(
                role="object restore destination",
                backend=restore_backend,
                local_path=arguments.object_restore_path,
                bucket_name=arguments.object_restore_bucket,
                project_id=arguments.object_restore_project,
                kms_key_name=arguments.object_restore_kms_key,
                allow_plaintext_local=arguments.allow_plaintext_local_objects,
            )
        except ValueError as error:
            parser.error(str(error))
    object_envelope = (
        load_object_archive_manifest(arguments.object_manifest)
        if arguments.object_manifest is not None
        else None
    )
    report = clean_room_restore(
        arguments.database_url,
        backup=arguments.backup,
        alembic_ini=REPOSITORY_ROOT / "backend" / "alembic.ini",
        report_path=arguments.report,
        object_archive=archive,
        object_destination=destination,
        object_envelope=object_envelope,
    )
    print(json.dumps(report.as_json(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
