#!/usr/bin/env python3
"""Import the deterministic synthetic-life ledger without destructive reset."""

import argparse
import asyncio
import json
from pathlib import Path

from odyssey.config import get_settings
from odyssey.db.importer import import_fixture
from odyssey.db.session import Database

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = REPOSITORY_ROOT / "fixtures" / "synthetic-life" / "generated" / "v1"


async def run(arguments: argparse.Namespace) -> None:
    settings = get_settings()
    database = Database(arguments.database_url or settings.database_url)
    try:
        report = await import_fixture(
            database,
            ledger_path=arguments.fixture / "ledger.jsonl",
            source_records_path=arguments.fixture / "source-records.jsonl",
            batch_size=arguments.batch_size,
            limit=arguments.limit,
            rebuild_projections=not arguments.skip_rebuild,
        )
        print(json.dumps(report.as_json(), indent=2, default=str, sort_keys=True))
    finally:
        await database.dispose()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database-url")
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--batch-size", type=int, default=250)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--skip-rebuild", action="store_true")
    arguments = parser.parse_args()
    asyncio.run(run(arguments))


if __name__ == "__main__":
    main()
