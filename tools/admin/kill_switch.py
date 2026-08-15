#!/usr/bin/env python3
"""List or change audited operational kill switches."""

import argparse
import asyncio
import json

from odyssey.config import get_settings
from odyssey.db.session import Database
from odyssey.operations.kill_switches import KillSwitchKey, KillSwitchService


async def run(arguments: argparse.Namespace) -> None:
    database = Database(arguments.database_url or get_settings().database_url)
    service = KillSwitchService()
    try:
        async with database.sessions() as session:
            if arguments.action == "list":
                states = await service.list(session)
                value: object = [state.as_json() for state in states]
            else:
                async with session.begin():
                    state = await service.set(
                        session,
                        key=arguments.key,
                        enabled=arguments.action == "enable",
                        reason=arguments.reason,
                        changed_by=arguments.changed_by,
                        change_source="operator_cli",
                    )
                value = state.as_json()
        print(json.dumps(value, indent=2, sort_keys=True))
    finally:
        await database.dispose()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database-url")
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser("list")
    for action in ("enable", "disable"):
        action_parser = subparsers.add_parser(action)
        action_parser.add_argument("key", choices=[key.value for key in KillSwitchKey])
        action_parser.add_argument("--reason", required=True)
        action_parser.add_argument("--changed-by", required=True)
    arguments = parser.parse_args()
    asyncio.run(run(arguments))


if __name__ == "__main__":
    main()
