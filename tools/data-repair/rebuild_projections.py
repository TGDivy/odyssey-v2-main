#!/usr/bin/env python3
"""Rebuild and verify every derived current-state projection."""

import argparse
import asyncio
import json
from dataclasses import asdict

from odyssey.config import get_settings
from odyssey.db.projections import CurrentEntityProjectionRebuilder
from odyssey.db.session import Database


async def run(database_url: str | None) -> None:
    database = Database(database_url or get_settings().database_url)
    rebuilder = CurrentEntityProjectionRebuilder()
    try:
        async with database.sessions() as session, session.begin():
            rebuild_report = await rebuilder.rebuild(session)
            integrity_report = await rebuilder.verify(session)
        print(
            json.dumps(
                {
                    "rebuild": asdict(rebuild_report),
                    "integrity": asdict(integrity_report),
                },
                indent=2,
                sort_keys=True,
            )
        )
        if not integrity_report.healthy:
            raise SystemExit(2)
    finally:
        await database.dispose()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database-url")
    arguments = parser.parse_args()
    asyncio.run(run(arguments.database_url))


if __name__ == "__main__":
    main()
