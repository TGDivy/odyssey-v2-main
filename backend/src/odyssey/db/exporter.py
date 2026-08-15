"""Standalone intelligible export with per-table content hashes."""

import asyncio
import base64
import json
from collections.abc import Mapping
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime
from hashlib import sha256
from pathlib import Path
from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.db import models as database_models
from odyssey.db.base import Base

assert database_models


@dataclass(frozen=True, slots=True)
class ExportTableReport:
    table: str
    row_count: int
    path: str
    sha256: str


@dataclass(frozen=True, slots=True)
class ExportReport:
    destination: Path
    generated_at: datetime
    tables: tuple[ExportTableReport, ...]
    manifest_sha256: str


def normalize_json(value: Any) -> Any:
    if isinstance(value, UUID):
        return str(value)
    if isinstance(value, datetime):
        instant = value if value.tzinfo is not None else value.replace(tzinfo=UTC)
        return instant.astimezone(UTC).isoformat().replace("+00:00", "Z")
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, bytes):
        return {"encoding": "base64", "data": base64.b64encode(value).decode()}
    if isinstance(value, Mapping):
        return {str(key): normalize_json(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [normalize_json(item) for item in value]
    return value


def write_atomic(path: Path, content: bytes) -> None:
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_bytes(content)
    temporary_path.replace(path)


async def export_database(
    session: AsyncSession,
    *,
    destination: Path,
    generated_at: datetime | None = None,
) -> ExportReport:
    export_time = generated_at or datetime.now(UTC)
    await asyncio.to_thread(destination.mkdir, parents=True, exist_ok=True)
    table_reports: list[ExportTableReport] = []
    for table in Base.metadata.sorted_tables:
        statement = select(table)
        primary_key_columns = list(table.primary_key.columns)
        if primary_key_columns:
            statement = statement.order_by(*primary_key_columns)
        result = await session.execute(statement)
        documents = [normalize_json(dict(row._mapping)) for row in result]
        content = (
            "\n".join(
                json.dumps(document, separators=(",", ":"), sort_keys=True)
                for document in documents
            )
            + ("\n" if documents else "")
        ).encode()
        relative_path = f"tables/{table.name}.jsonl"
        output_path = destination / relative_path
        await asyncio.to_thread(output_path.parent.mkdir, parents=True, exist_ok=True)
        await asyncio.to_thread(write_atomic, output_path, content)
        table_reports.append(
            ExportTableReport(
                table=table.name,
                row_count=len(documents),
                path=relative_path,
                sha256=sha256(content).hexdigest(),
            )
        )

    manifest = {
        "export_schema_version": 1,
        "generated_at": normalize_json(export_time),
        "scope": "all_odyssey_owned_database_data",
        "encryption": "none_local_development",
        "signature": "sha256_detached",
        "tables": [asdict(report) for report in table_reports],
    }
    manifest_content = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    manifest_hash = sha256(manifest_content).hexdigest()
    await asyncio.to_thread(write_atomic, destination / "manifest.json", manifest_content)
    await asyncio.to_thread(
        write_atomic,
        destination / "manifest.sha256",
        f"{manifest_hash}  manifest.json\n".encode(),
    )
    return ExportReport(
        destination=destination,
        generated_at=export_time,
        tables=tuple(table_reports),
        manifest_sha256=manifest_hash,
    )
