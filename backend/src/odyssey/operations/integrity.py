"""Scheduled integrity checks with durable reports and safety freezes."""

import json
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from hashlib import sha256
from pathlib import Path
from typing import Any
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncSession

from odyssey.attachments.contracts import AttachmentStatus, AttachmentUploadStatus
from odyssey.attachments.models import (
    AttachmentObjectRecord,
    AttachmentRecord,
    AttachmentUploadRecord,
)
from odyssey.db.backups import BackupError, verify_database_backup, verify_manifest
from odyssey.db.models import (
    AssertionRecord,
    IntegrityRunRecord,
    LedgerEventRecord,
    ProvenanceRecord,
    SourceRecord,
)
from odyssey.db.projections import CurrentEntityProjectionRebuilder
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7
from odyssey.operations.kill_switches import KillSwitchKey, KillSwitchService

INTEGRITY_CHECKER_VERSION = "integrity.v2"


class CheckStatus(StrEnum):
    SUCCESS = "pass"
    FAIL = "fail"
    NOT_APPLICABLE = "not_applicable"
    NOT_CONFIGURED = "not_configured"


@dataclass(frozen=True, slots=True)
class IntegrityCheckResult:
    code: str
    status: CheckStatus
    summary: str
    observed: dict[str, str | int | bool]

    def as_json(self) -> dict[str, Any]:
        value = asdict(self)
        value["status"] = self.status.value
        return value


@dataclass(frozen=True, slots=True)
class IntegrityReport:
    run_id: UUID
    started_at: datetime
    completed_at: datetime
    checker_version: str
    healthy: bool
    checks: tuple[IntegrityCheckResult, ...]
    failure_codes: tuple[str, ...]
    destructive_compaction_frozen: bool
    report_hash: str

    def as_json(self) -> dict[str, Any]:
        return {
            "run_id": str(self.run_id),
            "started_at": instant_json(self.started_at),
            "completed_at": instant_json(self.completed_at),
            "checker_version": self.checker_version,
            "healthy": self.healthy,
            "checks": [check.as_json() for check in self.checks],
            "failure_codes": list(self.failure_codes),
            "destructive_compaction_frozen": self.destructive_compaction_frozen,
            "report_hash": self.report_hash,
        }


def instant_json(value: datetime) -> str:
    instant = value if value.tzinfo is not None else value.replace(tzinfo=UTC)
    return instant.astimezone(UTC).isoformat().replace("+00:00", "Z")


def canonical_hash(value: dict[str, Any]) -> str:
    content = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
    return sha256(content).hexdigest()


async def database_checks(connection: AsyncConnection) -> list[IntegrityCheckResult]:
    if connection.dialect.name == "sqlite":
        integrity_rows = await connection.exec_driver_sql("PRAGMA integrity_check")
        integrity_values = [str(row[0]) for row in integrity_rows.all()]
        foreign_keys_enabled = bool(
            (await connection.exec_driver_sql("PRAGMA foreign_keys")).scalar_one()
        )
        foreign_key_rows = await connection.exec_driver_sql("PRAGMA foreign_key_check")
        foreign_key_violations = len(foreign_key_rows.all())
        trigger_rows = await connection.exec_driver_sql(
            "SELECT name FROM sqlite_master WHERE type = 'trigger'"
        )
        triggers = {str(row[0]) for row in trigger_rows.all()}
        required_triggers = {
            "attachment_chunks_reject_delete",
            "attachment_chunks_reject_update",
            "attachment_objects_reject_delete",
            "attachment_objects_reject_update",
            "integrity_runs_reject_delete",
            "integrity_runs_reject_update",
            "kill_switch_audit_reject_delete",
            "kill_switch_audit_reject_update",
            "ledger_events_reject_delete",
            "ledger_events_reject_update",
            "provenance_records_reject_delete",
            "provenance_records_reject_update",
            "source_records_reject_delete",
            "source_records_reject_update",
            "server_changes_reject_delete",
            "server_changes_reject_update",
            "sync_batch_receipts_reject_delete",
            "sync_batch_receipts_reject_update",
            "sync_operations_reject_delete",
            "sync_operations_reject_update",
        }
        missing_triggers = required_triggers - triggers
        return [
            IntegrityCheckResult(
                code="database_integrity",
                status=(CheckStatus.SUCCESS if integrity_values == ["ok"] else CheckStatus.FAIL),
                summary="SQLite structural integrity check",
                observed={"result": ",".join(integrity_values)},
            ),
            IntegrityCheckResult(
                code="foreign_key_constraints",
                status=(
                    CheckStatus.SUCCESS
                    if foreign_keys_enabled and foreign_key_violations == 0
                    else CheckStatus.FAIL
                ),
                summary="Foreign-key consistency",
                observed={
                    "enforcement_enabled": foreign_keys_enabled,
                    "violations": foreign_key_violations,
                },
            ),
            IntegrityCheckResult(
                code="immutability_triggers",
                status=CheckStatus.SUCCESS if not missing_triggers else CheckStatus.FAIL,
                summary="Database-level append-only enforcement",
                observed={
                    "required": len(required_triggers),
                    "present": len(required_triggers - missing_triggers),
                    "missing": ",".join(sorted(missing_triggers)),
                },
            ),
        ]
    trigger_rows = await connection.exec_driver_sql(
        "SELECT tgname FROM pg_trigger WHERE NOT tgisinternal"
    )
    triggers = {str(row[0]) for row in trigger_rows.all()}
    required_triggers = {
        "attachment_chunks_immutable",
        "attachment_objects_immutable",
        "integrity_runs_immutable",
        "kill_switch_audit_immutable",
        "ledger_events_immutable",
        "provenance_records_immutable",
        "source_records_immutable",
        "server_changes_immutable",
        "sync_batch_receipts_immutable",
        "sync_operations_immutable",
    }
    missing_triggers = required_triggers - triggers
    unvalidated_foreign_keys = int(
        (
            await connection.exec_driver_sql(
                "SELECT count(*) FROM pg_constraint WHERE contype = 'f' AND NOT convalidated"
            )
        ).scalar_one()
    )
    return [
        IntegrityCheckResult(
            code="database_integrity",
            status=CheckStatus.SUCCESS,
            summary="PostgreSQL connection and constraints are active",
            observed={"dialect": connection.dialect.name},
        ),
        IntegrityCheckResult(
            code="foreign_key_constraints",
            status=(CheckStatus.SUCCESS if unvalidated_foreign_keys == 0 else CheckStatus.FAIL),
            summary="PostgreSQL enforces declared foreign keys",
            observed={"unvalidated": unvalidated_foreign_keys},
        ),
        IntegrityCheckResult(
            code="immutability_triggers",
            status=CheckStatus.SUCCESS if not missing_triggers else CheckStatus.FAIL,
            summary="Database-level append-only enforcement",
            observed={
                "required": len(required_triggers),
                "present": len(required_triggers - missing_triggers),
                "missing": ",".join(sorted(missing_triggers)),
            },
        ),
    ]


async def source_hash_check(session: AsyncSession) -> IntegrityCheckResult:
    records = (
        await session.execute(
            select(SourceRecord.id, SourceRecord.payload, SourceRecord.content_hash)
        )
    ).all()
    mismatches = 0
    for _record_id, payload, expected_hash in records:
        if canonical_hash(payload) != expected_hash:
            mismatches += 1
    return IntegrityCheckResult(
        code="source_hashes",
        status=CheckStatus.SUCCESS if mismatches == 0 else CheckStatus.FAIL,
        summary="Immutable source payload hashes",
        observed={"checked": len(records), "mismatches": mismatches},
    )


async def provenance_check(session: AsyncSession) -> IntegrityCheckResult:
    orphaned_ledger = int(
        await session.scalar(
            select(func.count())
            .select_from(LedgerEventRecord)
            .outerjoin(
                ProvenanceRecord,
                LedgerEventRecord.provenance_id == ProvenanceRecord.id,
            )
            .where(ProvenanceRecord.id.is_(None))
        )
        or 0
    )
    orphaned_sources = int(
        await session.scalar(
            select(func.count())
            .select_from(SourceRecord)
            .outerjoin(ProvenanceRecord, SourceRecord.provenance_id == ProvenanceRecord.id)
            .where(ProvenanceRecord.id.is_(None))
        )
        or 0
    )
    orphaned_assertions = int(
        await session.scalar(
            select(func.count())
            .select_from(AssertionRecord)
            .outerjoin(
                ProvenanceRecord,
                AssertionRecord.provenance_id == ProvenanceRecord.id,
            )
            .where(ProvenanceRecord.id.is_(None))
        )
        or 0
    )
    orphaned = orphaned_ledger + orphaned_sources + orphaned_assertions
    return IntegrityCheckResult(
        code="provenance_reachability",
        status=CheckStatus.SUCCESS if orphaned == 0 else CheckStatus.FAIL,
        summary="Canonical records resolve to provenance",
        observed={
            "orphaned_ledger": orphaned_ledger,
            "orphaned_sources": orphaned_sources,
            "orphaned_assertions": orphaned_assertions,
        },
    )


async def projection_check(session: AsyncSession) -> IntegrityCheckResult:
    report = await CurrentEntityProjectionRebuilder().verify(session)
    return IntegrityCheckResult(
        code="ledger_projection_reconciliation",
        status=CheckStatus.SUCCESS if report.healthy else CheckStatus.FAIL,
        summary="Ledger and current-entity projection reconciliation",
        observed={
            "ledger_events": report.ledger_event_count,
            "expected_projections": report.expected_projection_count,
            "actual_projections": report.actual_projection_count,
            "ledger_sequence": report.ledger_sequence,
            "checkpoint_sequence": report.checkpoint_sequence,
        },
    )


async def attachment_manifest_check(session: AsyncSession) -> IntegrityCheckResult:
    available_without_manifest = int(
        await session.scalar(
            select(func.count())
            .select_from(AttachmentRecord)
            .outerjoin(
                AttachmentObjectRecord,
                AttachmentRecord.object_content_sha256 == AttachmentObjectRecord.content_sha256,
            )
            .where(
                AttachmentRecord.status == AttachmentStatus.AVAILABLE,
                AttachmentObjectRecord.content_sha256.is_(None),
            )
        )
        or 0
    )
    manifest_mismatches = int(
        await session.scalar(
            select(func.count())
            .select_from(AttachmentRecord)
            .join(
                AttachmentObjectRecord,
                AttachmentRecord.object_content_sha256 == AttachmentObjectRecord.content_sha256,
            )
            .where(
                (AttachmentRecord.expected_content_sha256 != AttachmentObjectRecord.content_sha256)
                | (AttachmentRecord.byte_size != AttachmentObjectRecord.byte_size)
            )
        )
        or 0
    )
    orphaned_objects = int(
        await session.scalar(
            select(func.count())
            .select_from(AttachmentObjectRecord)
            .outerjoin(
                AttachmentRecord,
                AttachmentObjectRecord.content_sha256 == AttachmentRecord.object_content_sha256,
            )
            .where(AttachmentRecord.id.is_(None))
        )
        or 0
    )
    completed_upload_mismatches = int(
        await session.scalar(
            select(func.count())
            .select_from(AttachmentUploadRecord)
            .join(
                AttachmentRecord,
                AttachmentUploadRecord.attachment_id == AttachmentRecord.id,
            )
            .where(
                AttachmentUploadRecord.status == AttachmentUploadStatus.COMPLETED,
                AttachmentRecord.status != AttachmentStatus.AVAILABLE,
            )
        )
        or 0
    )
    failures = (
        available_without_manifest
        + manifest_mismatches
        + orphaned_objects
        + completed_upload_mismatches
    )
    return IntegrityCheckResult(
        code="attachments_and_object_manifests",
        status=CheckStatus.SUCCESS if failures == 0 else CheckStatus.FAIL,
        summary="Attachment references resolve to verified content-addressed manifests",
        observed={
            "available_without_manifest": available_without_manifest,
            "manifest_mismatches": manifest_mismatches,
            "orphaned_objects": orphaned_objects,
            "completed_upload_mismatches": completed_upload_mismatches,
        },
    )


def backup_freshness_check(
    backup: Path | None, *, now: datetime, maximum_age: timedelta
) -> IntegrityCheckResult:
    if backup is None:
        return IntegrityCheckResult(
            code="backup_freshness",
            status=CheckStatus.NOT_CONFIGURED,
            summary="No backup bundle was supplied to this local check",
            observed={},
        )
    try:
        verify_database_backup(backup)
        manifest, _manifest_hash = verify_manifest(backup)
        created_at = datetime.fromisoformat(str(manifest["created_at"]).replace("Z", "+00:00"))
        age = now - created_at
        healthy = timedelta(minutes=-5) <= age <= maximum_age
        return IntegrityCheckResult(
            code="backup_freshness",
            status=CheckStatus.SUCCESS if healthy else CheckStatus.FAIL,
            summary="Backup artifact integrity and age",
            observed={"age_seconds": int(age.total_seconds())},
        )
    except (BackupError, KeyError, TypeError, ValueError) as error:
        return IntegrityCheckResult(
            code="backup_freshness",
            status=CheckStatus.FAIL,
            summary="Backup bundle could not be verified",
            observed={"error_type": type(error).__name__},
        )


def deferred_checks() -> list[IntegrityCheckResult]:
    return [
        IntegrityCheckResult(
            code="sync_and_tombstone_consistency",
            status=CheckStatus.NOT_APPLICABLE,
            summary="Sync operation and tombstone tables are introduced in Milestone 0.3",
            observed={},
        ),
        IntegrityCheckResult(
            code="external_reference_deduplication",
            status=CheckStatus.NOT_APPLICABLE,
            summary="External connector records are not enabled",
            observed={},
        ),
    ]


async def run_integrity_checks(
    database: Database,
    *,
    backup: Path | None = None,
    maximum_backup_age: timedelta = timedelta(hours=26),
    now: datetime | None = None,
) -> IntegrityReport:
    started_at = now or datetime.now(UTC)
    run_id = new_uuid7()
    async with database.engine.connect() as connection:
        checks = await database_checks(connection)
    async with database.sessions() as session, session.begin():
        checks.extend(
            [
                await source_hash_check(session),
                await provenance_check(session),
                await projection_check(session),
                await attachment_manifest_check(session),
                backup_freshness_check(
                    backup,
                    now=started_at,
                    maximum_age=maximum_backup_age,
                ),
                *deferred_checks(),
            ]
        )
        failure_codes = tuple(check.code for check in checks if check.status is CheckStatus.FAIL)
        kill_switches = KillSwitchService()
        frozen = await kill_switches.is_enabled(session, KillSwitchKey.DESTRUCTIVE_COMPACTION)
        if failure_codes and not frozen:
            await kill_switches.set(
                session,
                key=KillSwitchKey.DESTRUCTIVE_COMPACTION,
                enabled=True,
                reason=f"integrity failure: {','.join(failure_codes)}",
                changed_by="integrity-checker",
                change_source=INTEGRITY_CHECKER_VERSION,
                changed_at=started_at,
            )
            frozen = True
        completed_at = datetime.now(UTC)
        report_document = {
            "run_id": str(run_id),
            "started_at": instant_json(started_at),
            "completed_at": instant_json(completed_at),
            "checker_version": INTEGRITY_CHECKER_VERSION,
            "healthy": not failure_codes,
            "checks": [check.as_json() for check in checks],
            "failure_codes": list(failure_codes),
            "destructive_compaction_frozen": frozen,
        }
        report_hash = canonical_hash(report_document)
        session.add(
            IntegrityRunRecord(
                id=run_id,
                started_at=started_at,
                completed_at=completed_at,
                status="healthy" if not failure_codes else "failed",
                checker_version=INTEGRITY_CHECKER_VERSION,
                checks=[check.as_json() for check in checks],
                failure_codes=list(failure_codes),
                report_hash=report_hash,
            )
        )
    return IntegrityReport(
        run_id=run_id,
        started_at=started_at,
        completed_at=completed_at,
        checker_version=INTEGRITY_CHECKER_VERSION,
        healthy=not failure_codes,
        checks=tuple(checks),
        failure_codes=failure_codes,
        destructive_compaction_frozen=frozen,
        report_hash=report_hash,
    )
