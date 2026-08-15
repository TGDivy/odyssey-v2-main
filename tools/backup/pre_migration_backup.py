#!/usr/bin/env python3
"""Create and verify a native checkpoint before a schema migration."""

import argparse
import json
from pathlib import Path

from odyssey.config import get_settings
from odyssey.db.backups import create_database_backup


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database-url")
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--allow-plaintext-local", action="store_true")
    arguments = parser.parse_args()
    report = create_database_backup(
        arguments.database_url or get_settings().database_url,
        destination=arguments.destination,
        allow_plaintext=arguments.allow_plaintext_local,
    )
    print(json.dumps(report.as_json(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
