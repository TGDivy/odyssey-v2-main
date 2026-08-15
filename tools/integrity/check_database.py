#!/usr/bin/env python3
"""Run scheduled database integrity checks and freeze unsafe compaction."""

import argparse
import asyncio
import json
from pathlib import Path

from odyssey.config import get_settings
from odyssey.db.backups import write_private
from odyssey.db.session import Database
from odyssey.operations.integrity import run_integrity_checks


async def run(arguments: argparse.Namespace) -> int:
    database = Database(arguments.database_url or get_settings().database_url)
    try:
        report = await run_integrity_checks(database, backup=arguments.backup)
        document = report.as_json()
        content = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
        if arguments.report:
            if arguments.report.exists():
                raise FileExistsError(f"report already exists: {arguments.report}")
            arguments.report.parent.mkdir(parents=True, exist_ok=True)
            write_private(arguments.report, content)
        print(content.decode(), end="")
        return 0 if report.healthy else 2
    finally:
        await database.dispose()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database-url")
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--report", type=Path)
    arguments = parser.parse_args()
    raise SystemExit(asyncio.run(run(arguments)))


if __name__ == "__main__":
    main()
