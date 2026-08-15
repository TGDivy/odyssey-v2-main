import asyncio
import json
import os
import subprocess
import sys
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from uuid import UUID

from sqlalchemy import func, select

from odyssey.db.base import Base
from odyssey.db.exporter import export_database, normalize_json
from odyssey.db.importer import import_fixture
from odyssey.db.models import LedgerEventRecord, ProvenanceRecord, SourceRecord
from odyssey.db.projections import CurrentEntityProjectionRebuilder
from odyssey.db.session import Database

FIXTURE_ROOT = (
    Path(__file__).resolve().parents[3] / "fixtures" / "synthetic-life" / "generated" / "v1"
)
REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


def test_fixture_import_is_idempotent_and_export_is_verifiable(tmp_path: Path) -> None:
    async def scenario() -> None:
        database = Database(f"sqlite+aiosqlite:///{tmp_path / 'import.sqlite'}")
        async with database.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

        first = await import_fixture(
            database,
            ledger_path=FIXTURE_ROOT / "ledger.jsonl",
            source_records_path=FIXTURE_ROOT / "source-records.jsonl",
            batch_size=17,
            limit=50,
        )
        second = await import_fixture(
            database,
            ledger_path=FIXTURE_ROOT / "ledger.jsonl",
            source_records_path=FIXTURE_ROOT / "source-records.jsonl",
            batch_size=17,
            limit=50,
        )
        assert first.created_count == 50
        assert first.duplicate_count == 0
        assert first.source_created_count == first.source_record_count
        assert first.source_duplicate_count == 0
        assert first.available_source_record_count == 2_532
        assert second.created_count == 0
        assert second.duplicate_count == 50
        assert second.source_created_count == 0
        assert second.source_duplicate_count == second.source_record_count

        source_document = next(
            json.loads(line)
            for line in (FIXTURE_ROOT / "source-records.jsonl").read_text().splitlines()
            if '"record_type":"data_quality_gap"' in line
        )
        source_only_path = tmp_path / "source-only.jsonl"
        source_only_path.write_text(json.dumps(source_document, sort_keys=True) + "\n")
        empty_ledger_path = tmp_path / "empty-ledger.jsonl"
        empty_ledger_path.write_text("")
        source_only = await import_fixture(
            database,
            ledger_path=empty_ledger_path,
            source_records_path=source_only_path,
            batch_size=1,
        )
        source_only_retry = await import_fixture(
            database,
            ledger_path=empty_ledger_path,
            source_records_path=source_only_path,
            batch_size=1,
        )
        assert source_only.source_created_count == 1
        assert source_only_retry.source_duplicate_count == 1

        async with database.sessions() as session:
            ledger_count = int(
                await session.scalar(select(func.count()).select_from(LedgerEventRecord)) or 0
            )
            integrity = await CurrentEntityProjectionRebuilder().verify(session)
            export = await export_database(
                session,
                destination=tmp_path / "export",
                generated_at=datetime(2026, 8, 15, tzinfo=UTC),
            )
            imported_source = await session.get(SourceRecord, UUID(source_document["id"]))
            assert imported_source is not None
            assert imported_source.payload == source_document
            source_provenance = await session.get(ProvenanceRecord, imported_source.provenance_id)
            assert source_provenance is not None
            assert source_provenance.details["registration_only"] is True
        assert ledger_count == 50
        assert integrity.healthy is True
        assert export.manifest_sha256

        manifest_path = export.destination / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        ledger_report = next(
            table for table in manifest["tables"] if table["table"] == "ledger_events"
        )
        ledger_content = (export.destination / ledger_report["path"]).read_bytes()
        assert ledger_report["row_count"] == 50
        assert sha256(ledger_content).hexdigest() == ledger_report["sha256"]
        assert (
            (export.destination / "manifest.sha256").read_text().startswith(export.manifest_sha256)
        )
        await database.dispose()

    asyncio.run(scenario())

    standalone_destination = tmp_path / "standalone-export"
    environment = os.environ | {"PYTHONPATH": str(REPOSITORY_ROOT / "backend" / "src")}
    completed = subprocess.run(
        [
            sys.executable,
            str(REPOSITORY_ROOT / "tools" / "export" / "export_database.py"),
            "--database-url",
            f"sqlite+aiosqlite:///{tmp_path / 'import.sqlite'}",
            "--destination",
            str(standalone_destination),
        ],
        check=True,
        capture_output=True,
        env=environment,
        text=True,
    )
    standalone_report = json.loads(completed.stdout)
    assert standalone_report["tables"] == len(Base.metadata.sorted_tables)
    assert standalone_report["tables"] > 0
    assert normalize_json(datetime(2026, 8, 15, 12, 30)) == "2026-08-15T12:30:00Z"
