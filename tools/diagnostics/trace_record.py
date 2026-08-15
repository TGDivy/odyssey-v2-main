#!/usr/bin/env python3
"""Emit a payload-free source-to-sync record trace."""

import argparse
import asyncio
import json
from pathlib import Path
from uuid import UUID

from odyssey.config import get_settings
from odyssey.db.backups import write_private
from odyssey.db.session import Database
from odyssey.operations.record_trace import (
    HttpTraceReference,
    RecordTraceNotFoundError,
    RecordTraceQuery,
    RecordTraceService,
)


def http_trace(value: str) -> HttpTraceReference:
    fields = value.split(",")
    if len(fields) != 4:
        raise argparse.ArgumentTypeError("HTTP trace must be PHASE,CORRELATION_ID,TRACE_ID,SPAN_ID")
    try:
        return HttpTraceReference(
            phase=fields[0],
            correlation_id=fields[1],
            trace_id=fields[2],
            span_id=fields[3],
        )
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


async def run(arguments: argparse.Namespace) -> int:
    query = RecordTraceQuery(
        source_record_id=arguments.source_record_id,
        event_id=arguments.event_id,
        aggregate_id=arguments.aggregate_id,
        correlation_id=arguments.correlation_id,
        ledger_sequence=arguments.ledger_sequence,
        http_traces=tuple(arguments.http_trace),
    )
    database = Database(arguments.database_url or get_settings().database_url)
    try:
        async with database.sessions() as session:
            try:
                envelope = await RecordTraceService().trace(session, query)
            except RecordTraceNotFoundError as error:
                print(
                    json.dumps(
                        {
                            "error": {
                                "code": "RECORD_TRACE_NOT_FOUND",
                                "message": str(error),
                            }
                        }
                    )
                )
                return 3
        document = envelope.model_dump(mode="json")
        content = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
        if arguments.report is not None:
            if arguments.report.exists():
                raise FileExistsError(f"report already exists: {arguments.report}")
            arguments.report.parent.mkdir(parents=True, exist_ok=True)
            write_private(arguments.report, content)
        print(content.decode(), end="")
        return 0 if envelope.report.complete else 2
    finally:
        await database.dispose()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database-url")
    parser.add_argument("--report", type=Path)
    parser.add_argument(
        "--http-trace",
        action="append",
        type=http_trace,
        default=[],
        metavar="PHASE,CORRELATION_ID,TRACE_ID,SPAN_ID",
    )
    selector = parser.add_mutually_exclusive_group(required=True)
    selector.add_argument("--source-record-id", type=UUID)
    selector.add_argument("--event-id", type=UUID)
    selector.add_argument("--aggregate-id", type=UUID)
    selector.add_argument("--correlation-id", type=UUID)
    selector.add_argument("--ledger-sequence", type=int)
    arguments = parser.parse_args()
    raise SystemExit(asyncio.run(run(arguments)))


if __name__ == "__main__":
    main()
