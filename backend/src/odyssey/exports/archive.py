"""Intelligible, bounded owner archive assembly with explicit secret exclusions."""

import base64
import csv
import html
import io
import json
import math
import zipfile
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import UTC, date, datetime
from decimal import Decimal
from hashlib import sha256
from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.attachments.storage import AttachmentStore
from odyssey.db.base import Base
from odyssey.exports.contracts import ExportFormat
from odyssey.exports.crypto import EXPORT_FORMAT, ExportKeyManager

DATABASE_SCHEMA_REVISION = "20260815_0017"
MANIFEST_NAME = "manifest.json"
MANIFEST_SIGNATURE_NAME = "manifest.ed25519"
SIGNING_PUBLIC_KEY_NAME = "signing-public-key.txt"


class OwnerArchiveError(RuntimeError):
    pass


class OwnerArchiveTooLargeError(OwnerArchiveError):
    pass


class OwnerArchiveIntegrityError(OwnerArchiveError):
    pass


@dataclass(frozen=True, slots=True)
class ExportDatasetSpec:
    table_name: str
    columns: tuple[str, ...]
    raw_columns: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class ArchiveFile:
    path: str
    content: bytes
    media_type: str
    category: str
    record_count: int | None = None

    def manifest_entry(self) -> dict[str, object]:
        entry: dict[str, object] = {
            "path": self.path,
            "sha256": sha256(self.content).hexdigest(),
            "bytes": len(self.content),
            "media_type": self.media_type,
            "category": self.category,
        }
        if self.record_count is not None:
            entry["record_count"] = self.record_count
        return entry


@dataclass(frozen=True, slots=True)
class BuiltOwnerArchive:
    plaintext: bytes
    manifest: dict[str, object]
    manifest_content: bytes
    manifest_sha256: str
    manifest_signature: bytes
    signing_public_key: bytes


DATASET_SPECS = (
    ExportDatasetSpec(
        "assertions",
        (
            "id",
            "subject_id",
            "predicate",
            "object_value",
            "valid_from",
            "valid_to",
            "epistemic_status",
            "confidence",
            "supersedes_id",
            "retracted_at",
            "provenance_id",
            "created_at",
        ),
    ),
    ExportDatasetSpec(
        "attachments",
        (
            "id",
            "owner_id",
            "expected_content_sha256",
            "object_content_sha256",
            "byte_size",
            "media_type",
            "sensitivity_class",
            "encryption_mode",
            "encryption_metadata",
            "status",
            "created_at",
            "committed_at",
            "deleted_at",
        ),
    ),
    ExportDatasetSpec(
        "auth_device_audit",
        (
            "sequence",
            "id",
            "device_id",
            "event_type",
            "occurred_at",
            "actor_device_id",
            "reason_code",
            "details",
        ),
    ),
    ExportDatasetSpec(
        "auth_devices",
        (
            "id",
            "owner_id",
            "display_name",
            "platform",
            "app_version",
            "status",
            "enrolled_at",
            "last_authenticated_at",
            "last_seen_at",
            "revoked_at",
            "revocation_reason",
        ),
    ),
    ExportDatasetSpec(
        "canonical_entities",
        (
            "entity_type",
            "entity_id",
            "canonical_revision",
            "document",
            "field_versions",
            "content_hash",
            "tombstoned",
            "deletion_epoch",
            "updated_at",
            "last_operation_id",
            "last_device_id",
        ),
    ),
    ExportDatasetSpec(
        "context_snapshots",
        (
            "id",
            "owner_id",
            "as_of",
            "built_at",
            "horizon",
            "purpose",
            "builder_version",
            "content_hash",
            "document",
        ),
    ),
    ExportDatasetSpec(
        "decision_preparations",
        (
            "id",
            "decision_id",
            "owner_id",
            "context_snapshot_id",
            "question",
            "status",
            "response",
            "prepared_at",
            "policy_version",
        ),
    ),
    ExportDatasetSpec(
        "evidence_queries",
        (
            "id",
            "owner_id",
            "question",
            "personal_scope",
            "response",
            "source_entity_ids",
            "assembled_at",
            "retrieval_version",
        ),
    ),
    ExportDatasetSpec(
        "export_job_audit",
        ("sequence", "id", "job_id", "event_type", "occurred_at", "details"),
    ),
    ExportDatasetSpec(
        "export_jobs",
        (
            "id",
            "owner_id",
            "status",
            "phase",
            "scope",
            "formats",
            "include_raw_sources",
            "include_model_traces",
            "attempts",
            "last_error_code",
            "artifact_content_hash",
            "artifact_bytes",
            "manifest_sha256",
            "signing_public_key",
            "created_at",
            "updated_at",
            "completed_at",
        ),
    ),
    ExportDatasetSpec(
        "feature_configurations",
        (
            "id",
            "owner_id",
            "environment",
            "audience",
            "version",
            "issued_at",
            "not_before",
            "expires_at",
            "key_id",
            "public_key",
            "payload",
            "payload_sha256",
            "signature",
            "request_sha256",
            "reason",
            "created_by",
            "created_at",
        ),
    ),
    ExportDatasetSpec(
        "integrity_runs",
        (
            "id",
            "started_at",
            "completed_at",
            "status",
            "checker_version",
            "checks",
            "failure_codes",
            "report_hash",
        ),
    ),
    ExportDatasetSpec(
        "intervention_evaluations",
        (
            "id",
            "owner_id",
            "opportunity_id",
            "semantic_key",
            "evaluated_at",
            "urgency",
            "policy",
            "reason_codes",
            "surface",
            "expires_at",
            "retry_after",
            "policy_version",
            "request_context_hash",
        ),
    ),
    ExportDatasetSpec(
        "life_model_versions",
        (
            "id",
            "owner_id",
            "kind",
            "logical_id",
            "version_number",
            "acceptance_sequence",
            "supersedes_version_id",
            "status",
            "acceptance_method",
            "accepted_at",
            "content_hash",
            "document",
            "event_id",
            "event_type",
            "ledger_sequence",
            "created_at",
        ),
    ),
    ExportDatasetSpec(
        "kill_switch_audit",
        (
            "sequence",
            "id",
            "key",
            "enabled",
            "reason",
            "changed_at",
            "changed_by",
            "change_source",
            "correlation_id",
        ),
    ),
    ExportDatasetSpec("kill_switches", ("key", "enabled", "reason", "updated_at", "updated_by")),
    ExportDatasetSpec(
        "ledger_events",
        (
            "sequence",
            "event_id",
            "event_type",
            "event_schema_version",
            "aggregate_type",
            "aggregate_id",
            "occurred_at",
            "recorded_at",
            "actor",
            "correlation_id",
            "causation_id",
            "payload",
            "provenance_id",
        ),
    ),
    ExportDatasetSpec("owner_identities", ("owner_id", "created_at", "last_authenticated_at")),
    ExportDatasetSpec(
        "projection_checkpoints",
        (
            "projection_name",
            "last_sequence",
            "projection_version",
            "rebuilt_at",
            "updated_at",
        ),
    ),
    ExportDatasetSpec(
        "projection_records",
        (
            "projection_name",
            "projection_key",
            "document",
            "source_sequence",
            "projection_version",
            "updated_at",
        ),
    ),
    ExportDatasetSpec(
        "provenance_records",
        (
            "id",
            "source_kind",
            "source_id",
            "source_version",
            "actor_type",
            "actor_id",
            "device_id",
            "observed_at",
            "recorded_at",
            "transformation_chain",
            "model_run_id",
            "confidence",
            "consent_scope",
            "content_hash",
            "details",
        ),
    ),
    ExportDatasetSpec(
        "recommendation_feedback",
        (
            "id",
            "owner_id",
            "recommendation_id",
            "feedback_type",
            "apply_scope",
            "correction_assertion_id",
            "replacement_assertion_id",
            "ledger_event_id",
            "future_recommendations_affected",
            "response",
            "recorded_at",
            "policy_version",
        ),
    ),
    ExportDatasetSpec(
        "server_changes",
        (
            "change_id",
            "entity_type",
            "entity_id",
            "canonical_revision",
            "mutation_type",
            "payload",
            "content_hash",
            "tombstone",
            "deletion_epoch",
            "merge_result",
            "origin_operation_id",
            "origin_device_id",
            "received_at",
        ),
    ),
    ExportDatasetSpec(
        "source_records",
        (
            "id",
            "source_kind",
            "external_source_id",
            "occurred_at",
            "observed_at",
            "recorded_at",
            "timezone_id",
            "temporal_precision",
            "content_hash",
            "sensitivity",
            "provenance_id",
        ),
        raw_columns=("payload",),
    ),
    ExportDatasetSpec(
        "sync_conflict_resolutions",
        (
            "id",
            "conflict_id",
            "operation_id",
            "device_id",
            "strategy",
            "resolved_document",
            "response",
            "created_at",
        ),
    ),
    ExportDatasetSpec(
        "sync_conflicts",
        (
            "id",
            "operation_id",
            "device_id",
            "entity_type",
            "entity_id",
            "conflict_code",
            "base_revision",
            "current_revision",
            "current_document",
            "incoming_document",
            "conflicting_fields",
            "status",
            "created_at",
            "resolved_at",
            "resolution",
        ),
    ),
    ExportDatasetSpec(
        "sync_devices",
        (
            "id",
            "last_device_sequence",
            "last_server_cursor",
            "client_schema_version",
            "clock_skew_seconds",
            "registered_at",
            "last_push_at",
            "last_pull_at",
            "local_queued_operations",
            "local_oldest_unsynced_at",
            "local_attachment_backlog",
            "diagnostics_reported_at",
        ),
    ),
    ExportDatasetSpec(
        "sync_operations",
        (
            "operation_id",
            "device_id",
            "device_sequence",
            "entity_type",
            "entity_id",
            "mutation_type",
            "base_revision",
            "payload",
            "created_at",
            "received_at",
            "sensitivity_class",
            "status",
            "canonical_revision",
            "server_change_id",
            "conflict_id",
            "result",
        ),
    ),
)

EXCLUDED_DATASETS = (
    {
        "table": "apple_auth_challenges",
        "reason": "authentication challenges and token fingerprints are operational secrets",
    },
    {
        "table": "attachment_chunks",
        "reason": "temporary storage paths are operational metadata",
    },
    {
        "table": "attachment_objects",
        "reason": "storage paths and bucket versions are replaced by portable attachment manifests",
    },
    {
        "table": "attachment_uploads",
        "reason": "upload nonces and incomplete sessions are operational secrets",
    },
    {
        "table": "auth_device_credentials",
        "reason": "authentication credential material is never exportable",
    },
    {
        "table": "outbox_records",
        "reason": "delivery leases and idempotency keys are operational state",
    },
    {
        "table": "owner_recovery_credentials",
        "reason": "recovery credential material is never exportable",
    },
    {
        "table": "sync_batch_receipts",
        "reason": "request fingerprints and idempotency keys are operational state",
    },
    {"table": "sync_state", "reason": "server cursor state is operational metadata"},
)

SENSITIVE_FIELD_NAMES = frozenset(
    {
        "access_token",
        "api_key",
        "credential",
        "credential_hash",
        "idempotency_key",
        "idempotency_key_hash",
        "identity_token",
        "nonce_hash",
        "owner_key_envelope",
        "passphrase",
        "password",
        "private_key",
        "recovery_credential",
        "refresh_token",
        "secret",
        "token_nonce",
        "worker_key_envelope",
    }
)


class OwnerArchiveBuilder:
    def __init__(self, *, maximum_bytes: int) -> None:
        if maximum_bytes < 1024:
            raise ValueError("maximum export size must be at least 1024 bytes")
        self.maximum_bytes = maximum_bytes

    async def build(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        job_id: UUID,
        requested_at: datetime,
        generated_at: datetime,
        formats: tuple[ExportFormat, ...],
        include_raw_sources: bool,
        include_model_traces: bool,
        attachment_store: AttachmentStore,
        key_manager: ExportKeyManager,
    ) -> BuiltOwnerArchive:
        files: list[ArchiveFile] = []
        datasets: list[dict[str, object]] = []
        records_by_table: dict[str, list[dict[str, Any]]] = {}
        total_uncompressed_bytes = 0

        def add_file(archive_file: ArchiveFile) -> None:
            nonlocal total_uncompressed_bytes
            total_uncompressed_bytes += len(archive_file.content)
            if total_uncompressed_bytes > self.maximum_bytes:
                raise OwnerArchiveTooLargeError("owner export exceeds its configured size limit")
            files.append(archive_file)

        total_redactions = 0
        for dataset_spec in DATASET_SPECS:
            records, columns, redactions = await self._read_dataset(
                session,
                dataset_spec,
                owner_id=owner_id,
                include_raw_sources=include_raw_sources,
            )
            total_redactions += redactions
            records_by_table[dataset_spec.table_name] = records
            dataset_files: list[str] = []
            for export_format in formats:
                archive_file = _render_dataset(
                    dataset_spec.table_name,
                    columns,
                    records,
                    export_format,
                )
                add_file(archive_file)
                dataset_files.append(archive_file.path)
            table = Base.metadata.tables[dataset_spec.table_name]
            datasets.append(
                {
                    "table": dataset_spec.table_name,
                    "columns": [
                        {
                            "name": column_name,
                            "database_type": str(table.c[column_name].type),
                            "nullable": table.c[column_name].nullable,
                        }
                        for column_name in columns
                    ],
                    "record_count": len(records),
                    "files": dataset_files,
                    "redacted_field_count": redactions,
                }
            )

        attachment_entries: list[dict[str, object]] = []
        included_object_hashes: set[str] = set()
        if include_raw_sources:
            for attachment in records_by_table["attachments"]:
                attachment_entry = await self._add_attachment(
                    attachment,
                    attachment_store=attachment_store,
                    included_object_hashes=included_object_hashes,
                    add_file=add_file,
                )
                if attachment_entry is not None:
                    attachment_entries.append(attachment_entry)

        manifest: dict[str, object] = {
            "format": EXPORT_FORMAT,
            "database_schema_revision": DATABASE_SCHEMA_REVISION,
            "job_id": str(job_id),
            "owner_scope": "authenticated_single_owner",
            "requested_at": _normalize_datetime(requested_at),
            "generated_at": _normalize_datetime(generated_at),
            "scope": "all_odyssey_owned_data",
            "requested_formats": [export_format.value for export_format in formats],
            "include_raw_sources": include_raw_sources,
            "include_model_traces": include_model_traces,
            "model_trace_availability": (
                "no_model_run_store_present" if include_model_traces else "not_requested"
            ),
            "datasets": datasets,
            "attachments": attachment_entries,
            "files": [archive_file.manifest_entry() for archive_file in files],
            "excluded_datasets": list(EXCLUDED_DATASETS),
            "security": {
                "credential_material_included": False,
                "worker_key_envelope_included": False,
                "operational_secrets_included": False,
                "nested_sensitive_fields_redacted": total_redactions,
                "csv_formula_prefixes_escaped": True,
            },
            "control_files": [
                MANIFEST_NAME,
                MANIFEST_SIGNATURE_NAME,
                SIGNING_PUBLIC_KEY_NAME,
            ],
        }
        manifest_content = (_canonical_json(manifest) + "\n").encode()
        manifest_digest = sha256(manifest_content).hexdigest()
        signature, public_key = key_manager.sign_manifest(manifest_content)
        add_file(
            ArchiveFile(
                path=MANIFEST_NAME,
                content=manifest_content,
                media_type="application/json",
                category="control",
            )
        )
        add_file(
            ArchiveFile(
                path=MANIFEST_SIGNATURE_NAME,
                content=(base64.b64encode(signature).decode() + "\n").encode(),
                media_type="application/vnd.odyssey.ed25519-signature",
                category="control",
            )
        )
        add_file(
            ArchiveFile(
                path=SIGNING_PUBLIC_KEY_NAME,
                content=(base64.b64encode(public_key).decode() + "\n").encode(),
                media_type="application/vnd.odyssey.ed25519-public-key",
                category="control",
            )
        )
        plaintext = _build_zip(files)
        if len(plaintext) > self.maximum_bytes:
            raise OwnerArchiveTooLargeError("owner export exceeds its configured size limit")
        return BuiltOwnerArchive(
            plaintext=plaintext,
            manifest=manifest,
            manifest_content=manifest_content,
            manifest_sha256=manifest_digest,
            manifest_signature=signature,
            signing_public_key=public_key,
        )

    async def _read_dataset(
        self,
        session: AsyncSession,
        dataset_spec: ExportDatasetSpec,
        *,
        owner_id: str,
        include_raw_sources: bool,
    ) -> tuple[list[dict[str, Any]], tuple[str, ...], int]:
        table = Base.metadata.tables[dataset_spec.table_name]
        columns = dataset_spec.columns + (dataset_spec.raw_columns if include_raw_sources else ())
        selected_columns = tuple(table.c[column_name] for column_name in columns)
        statement = select(*selected_columns)
        if "owner_id" in table.c:
            statement = statement.where(table.c.owner_id == owner_id)
        elif dataset_spec.table_name == "export_job_audit":
            export_jobs = Base.metadata.tables["export_jobs"]
            statement = statement.where(
                table.c.job_id.in_(
                    select(export_jobs.c.id).where(export_jobs.c.owner_id == owner_id)
                )
            )
        elif dataset_spec.table_name == "auth_device_audit":
            auth_devices = Base.metadata.tables["auth_devices"]
            statement = statement.where(
                table.c.device_id.in_(
                    select(auth_devices.c.id).where(auth_devices.c.owner_id == owner_id)
                )
            )
        primary_key_columns = tuple(table.primary_key.columns)
        if primary_key_columns:
            statement = statement.order_by(*primary_key_columns)
        result = await session.execute(statement)
        records: list[dict[str, Any]] = []
        redactions = 0
        for row in result.mappings():
            normalized, record_redactions = _normalize_value(dict(row))
            if not isinstance(normalized, dict):
                raise OwnerArchiveIntegrityError("owner export row normalization failed")
            records.append(normalized)
            redactions += record_redactions
        return records, columns, redactions

    async def _add_attachment(
        self,
        attachment: dict[str, Any],
        *,
        attachment_store: AttachmentStore,
        included_object_hashes: set[str],
        add_file: Callable[[ArchiveFile], None],
    ) -> dict[str, object] | None:
        content_hash = attachment.get("object_content_sha256")
        if (
            attachment.get("status") != "available"
            or attachment.get("deleted_at") is not None
            or not isinstance(content_hash, str)
        ):
            return None
        path = f"attachments/objects/{content_hash}"
        if content_hash not in included_object_hashes:
            content = await attachment_store.read_object(content_hash)
            if sha256(content).hexdigest() != content_hash:
                raise OwnerArchiveIntegrityError("attachment content hash verification failed")
            expected_bytes = attachment.get("byte_size")
            if isinstance(expected_bytes, int) and len(content) != expected_bytes:
                raise OwnerArchiveIntegrityError("attachment byte-size verification failed")
            add_file(
                ArchiveFile(
                    path=path,
                    content=content,
                    media_type=str(attachment.get("media_type") or "application/octet-stream"),
                    category="attachment",
                )
            )
            included_object_hashes.add(content_hash)
        return {
            "attachment_id": str(attachment["id"]),
            "path": path,
            "sha256": content_hash,
            "bytes": attachment["byte_size"],
            "media_type": attachment["media_type"],
            "sensitivity_class": attachment["sensitivity_class"],
            "source_encryption_mode": attachment["encryption_mode"],
        }


def _render_dataset(
    table_name: str,
    columns: tuple[str, ...],
    records: list[dict[str, Any]],
    export_format: ExportFormat,
) -> ArchiveFile:
    if export_format is ExportFormat.JSONL:
        content = "".join(_canonical_json(record) + "\n" for record in records).encode()
        return ArchiveFile(
            path=f"data/jsonl/{table_name}.jsonl",
            content=content,
            media_type="application/x-ndjson",
            category="dataset",
            record_count=len(records),
        )
    if export_format is ExportFormat.CSV:
        output = io.StringIO(newline="")
        writer = csv.DictWriter(output, fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        for record in records:
            writer.writerow({column: _csv_value(record.get(column)) for column in columns})
        return ArchiveFile(
            path=f"data/csv/{table_name}.csv",
            content=output.getvalue().encode(),
            media_type="text/csv; charset=utf-8",
            category="dataset",
            record_count=len(records),
        )
    output_lines = [f"# {table_name}", "", f"Records: {len(records)}", ""]
    if records:
        output_lines.extend(
            (
                "| " + " | ".join(_markdown_value(column) for column in columns) + " |",
                "| " + " | ".join("---" for _column in columns) + " |",
            )
        )
        output_lines.extend(
            "| " + " | ".join(_markdown_value(record.get(column)) for column in columns) + " |"
            for record in records
        )
    else:
        output_lines.append("No records.")
    return ArchiveFile(
        path=f"data/markdown/{table_name}.md",
        content=("\n".join(output_lines) + "\n").encode(),
        media_type="text/markdown; charset=utf-8",
        category="dataset",
        record_count=len(records),
    )


def _normalize_value(value: Any) -> tuple[Any, int]:
    if isinstance(value, UUID):
        return str(value), 0
    if isinstance(value, datetime):
        return _normalize_datetime(value), 0
    if isinstance(value, date):
        return value.isoformat(), 0
    if isinstance(value, bytes):
        return {"encoding": "base64", "data": base64.b64encode(value).decode()}, 0
    if isinstance(value, Decimal):
        return str(value), 0
    if isinstance(value, float) and not math.isfinite(value):
        return str(value), 0
    if isinstance(value, Mapping):
        normalized: dict[str, Any] = {}
        redactions = 0
        for raw_key, item in value.items():
            key = str(raw_key)
            if _is_sensitive_field(key):
                normalized[key] = "[redacted: operational secret]"
                redactions += 1
                continue
            normalized_item, item_redactions = _normalize_value(item)
            normalized[key] = normalized_item
            redactions += item_redactions
        return normalized, redactions
    if isinstance(value, (list, tuple, set, frozenset)):
        normalized_items: list[Any] = []
        redactions = 0
        for item in value:
            normalized_item, item_redactions = _normalize_value(item)
            normalized_items.append(normalized_item)
            redactions += item_redactions
        return normalized_items, redactions
    return value, 0


def _is_sensitive_field(field_name: str) -> bool:
    normalized = field_name.strip().lower().replace("-", "_")
    return (
        normalized in SENSITIVE_FIELD_NAMES
        or "passphrase" in normalized
        or "password" in normalized
        or "credential" in normalized
        or normalized.endswith("_private_key")
        or normalized.endswith("_secret")
        or normalized.endswith("_access_token")
        or normalized.endswith("_refresh_token")
        or normalized.endswith("_identity_token")
    )


def _normalize_datetime(value: datetime) -> str:
    instant = value if value.tzinfo is not None else value.replace(tzinfo=UTC)
    return instant.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _canonical_json(value: object) -> str:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def _csv_value(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        rendered = "true" if value else "false"
    elif isinstance(value, (dict, list)):
        rendered = _canonical_json(value)
    else:
        rendered = str(value)
    if rendered.startswith(("=", "+", "-", "@", "\t", "\r")):
        return "'" + rendered
    return rendered


def _markdown_value(value: object) -> str:
    rendered = _csv_value(value)
    return html.escape(rendered, quote=False).replace("|", "\\|").replace("\n", "<br>")


def _build_zip(files: list[ArchiveFile]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(
        output,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for archive_file in sorted(files, key=lambda item: item.path):
            info = zipfile.ZipInfo(archive_file.path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o600 << 16
            info.flag_bits |= 0x800
            archive.writestr(info, archive_file.content)
    return output.getvalue()
