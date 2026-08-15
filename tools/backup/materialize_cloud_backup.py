#!/usr/bin/env python3
"""Materialize a verified cloud database dump for clean-room restoration."""

import argparse
import json
from pathlib import Path

from odyssey.backups.cloud import (
    load_cloud_backup_envelope,
    load_cloud_object_archive_envelope,
    materialize_native_backup_bundle,
    materialize_object_archive_manifest,
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cloud-manifest", type=Path, required=True)
    parser.add_argument("--database-dump", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--archived-object-manifest", type=Path)
    parser.add_argument("--object-manifest-destination", type=Path)
    parser.add_argument("--allow-plaintext-isolated-restore", action="store_true")
    arguments = parser.parse_args()
    if not arguments.allow_plaintext_isolated_restore:
        parser.error(
            "materialized database dumps are plaintext; pass explicit isolated-restore approval"
        )
    object_manifest_arguments = (
        arguments.archived_object_manifest,
        arguments.object_manifest_destination,
    )
    if any(value is not None for value in object_manifest_arguments) and not all(
        value is not None for value in object_manifest_arguments
    ):
        parser.error(
            "object manifest materialization requires --archived-object-manifest and "
            "--object-manifest-destination"
        )
    envelope = load_cloud_backup_envelope(arguments.cloud_manifest.read_bytes())
    if arguments.archived_object_manifest is not None:
        load_cloud_object_archive_envelope(
            envelope,
            arguments.archived_object_manifest.read_bytes(),
        )
    manifest_sha256 = materialize_native_backup_bundle(
        envelope,
        database_dump=arguments.database_dump,
        destination=arguments.destination,
    )
    object_manifest_sha256 = (
        materialize_object_archive_manifest(
            envelope,
            archived_manifest=arguments.archived_object_manifest,
            destination=arguments.object_manifest_destination,
        )
        if arguments.archived_object_manifest is not None
        and arguments.object_manifest_destination is not None
        else None
    )
    print(
        json.dumps(
            {
                "database_dump_sha256": envelope.manifest.database_dump_sha256,
                "destination": str(arguments.destination),
                "manifest_sha256": manifest_sha256,
                "object_manifest_destination": (
                    str(arguments.object_manifest_destination)
                    if arguments.object_manifest_destination is not None
                    else None
                ),
                "object_manifest_sha256": object_manifest_sha256,
                "source_cloud_manifest_sha256": envelope.manifest_sha256,
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
