#!/usr/bin/env python3
"""Export all Odyssey-owned relational data without a running API."""

import argparse
import asyncio
import json
from pathlib import Path

from odyssey.config import get_settings
from odyssey.db.exporter import export_database
from odyssey.db.session import Database


async def run(database_url: str | None, destination: Path) -> None:
    database = Database(database_url or get_settings().database_url)
    try:
        async with database.sessions() as session:
            report = await export_database(session, destination=destination)
        print(
            json.dumps(
                {
                    "destination": str(report.destination),
                    "generated_at": report.generated_at.isoformat(),
                    "manifest_sha256": report.manifest_sha256,
                    "tables": len(report.tables),
                },
                indent=2,
                sort_keys=True,
            )
        )
    finally:
        await database.dispose()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database-url")
    parser.add_argument("--destination", type=Path, required=True)
    arguments = parser.parse_args()
    asyncio.run(run(arguments.database_url, arguments.destination))


if __name__ == "__main__":
    main()
