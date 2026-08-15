#!/usr/bin/env python3
"""Rebuild and verify every derived current-state projection."""

import argparse
import asyncio
import json
from dataclasses import asdict

from odyssey.config import get_settings
from odyssey.db.projections import CurrentEntityProjectionRebuilder
from odyssey.db.session import Database
from odyssey.sync.rebuild import SyncProjectionRebuilder


async def run(database_url: str | None) -> None:
    database = Database(database_url or get_settings().database_url)
    ledger_rebuilder = CurrentEntityProjectionRebuilder()
    sync_rebuilder = SyncProjectionRebuilder()
    try:
        async with database.sessions() as session, session.begin():
            ledger_rebuild = await ledger_rebuilder.rebuild(session)
            ledger_integrity = await ledger_rebuilder.verify(session)
            sync_rebuild = await sync_rebuilder.rebuild(session)
            sync_integrity = await sync_rebuilder.verify(session)
        print(
            json.dumps(
                {
                    "ledger": {
                        "rebuild": asdict(ledger_rebuild),
                        "integrity": asdict(ledger_integrity),
                    },
                    "sync": {
                        "rebuild": asdict(sync_rebuild),
                        "integrity": asdict(sync_integrity),
                    },
                },
                indent=2,
                sort_keys=True,
            )
        )
        if not ledger_integrity.healthy or not sync_integrity.healthy:
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
