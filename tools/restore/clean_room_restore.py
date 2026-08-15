#!/usr/bin/env python3
"""Restore a native backup into an empty target and validate recovery."""

import argparse
import json
from pathlib import Path

from odyssey.attachments.backups import load_object_archive_manifest
from odyssey.attachments.storage import LocalAttachmentStore
from odyssey.db.restores import clean_room_restore

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backup", type=Path, required=True)
    parser.add_argument("--database-url", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--object-manifest", type=Path)
    parser.add_argument("--object-archive-path", type=Path)
    parser.add_argument("--object-restore-path", type=Path)
    parser.add_argument("--allow-plaintext-local-object-archive", action="store_true")
    arguments = parser.parse_args()
    object_arguments = (
        arguments.object_manifest,
        arguments.object_archive_path,
        arguments.object_restore_path,
    )
    if any(value is not None for value in object_arguments) and not all(
        value is not None for value in object_arguments
    ):
        parser.error(
            "object restore requires --object-manifest, --object-archive-path, "
            "and --object-restore-path"
        )
    if arguments.object_manifest is not None and not (
        arguments.allow_plaintext_local_object_archive
    ):
        parser.error("local object archives require explicit plaintext local-only approval")
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
        object_archive=(
            LocalAttachmentStore(arguments.object_archive_path)
            if arguments.object_archive_path is not None
            else None
        ),
        object_destination=(
            LocalAttachmentStore(arguments.object_restore_path)
            if arguments.object_restore_path is not None
            else None
        ),
        object_envelope=object_envelope,
    )
    print(json.dumps(report.as_json(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
