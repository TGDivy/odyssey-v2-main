#!/usr/bin/env python3
"""Restore a native backup into an empty target and validate recovery."""

import argparse
import json
from pathlib import Path

from odyssey.db.restores import clean_room_restore

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backup", type=Path, required=True)
    parser.add_argument("--database-url", required=True)
    parser.add_argument("--report", type=Path, required=True)
    arguments = parser.parse_args()
    report = clean_room_restore(
        arguments.database_url,
        backup=arguments.backup,
        alembic_ini=REPOSITORY_ROOT / "backend" / "alembic.ini",
        report_path=arguments.report,
    )
    print(json.dumps(report.as_json(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
