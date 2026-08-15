"""Persistent credential-free client used by sync recovery and chaos drills."""

import json
import sqlite3
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum
from hashlib import sha256
from pathlib import Path
from types import TracebackType
from typing import Self, cast
from uuid import UUID

from pydantic import JsonValue

from odyssey.domain.capture import CapturePayloadKind
from odyssey.domain.common import DataClass, new_uuid7
from odyssey.sync.contracts import (
    SyncChange,
    SyncMutationType,
    SyncOperationInput,
    SyncPullResponse,
    SyncPushRequest,
    SyncPushResponse,
    format_cursor,
    parse_cursor,
)

CLIENT_SCHEMA_VERSION = 1


class SimulatedClientError(RuntimeError):
    """Raised when durable client state would become ambiguous or unsafe."""


class DeliveryState(StrEnum):
    PENDING = "pending"
    IN_FLIGHT = "in_flight"
    ACKNOWLEDGED = "acknowledged"
    REJECTED = "rejected"
    CONFLICT = "conflict"


@dataclass(frozen=True)
class QueuedCapture:
    capture_id: UUID
    event_id: UUID
    operation_id: UUID
    device_sequence: int


@dataclass(frozen=True)
class OutboundCapture:
    capture_id: UUID
    idempotency_key: str
    body: dict[str, JsonValue]


@dataclass(frozen=True)
class OutboundPush:
    idempotency_key: str
    request: SyncPushRequest


@dataclass(frozen=True)
class LocalEntity:
    entity_type: str
    entity_id: UUID
    canonical_revision: int
    document: dict[str, JsonValue]
    tombstoned: bool
    last_change_id: int
    server_epoch: int


@dataclass(frozen=True)
class RestoreReplayPlan:
    previous_cursor: str
    restored_cursor: str
    previous_server_epoch: int
    server_epoch: int
    requeued_operation_ids: tuple[UUID, ...]


def _dump_json(value: object) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def _load_document(value: str) -> dict[str, JsonValue]:
    loaded = json.loads(value)
    if not isinstance(loaded, dict):
        raise SimulatedClientError("persisted JSON document is not an object")
    return cast(dict[str, JsonValue], loaded)


class DurableSimulatedClient:
    """Small SQLite client that survives response loss, restarts, and rollback drills."""

    def __init__(
        self,
        path: Path,
        *,
        device_id: UUID | None = None,
        schema_version: int = CLIENT_SCHEMA_VERSION,
    ) -> None:
        if schema_version < 1:
            raise ValueError("schema_version must be positive")
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self._connection = sqlite3.connect(path, isolation_level=None)
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA foreign_keys=ON")
        self._connection.execute("PRAGMA journal_mode=WAL")
        self._connection.execute("PRAGMA synchronous=FULL")
        self._initialize(device_id=device_id, schema_version=schema_version)
        path.chmod(0o600)

    def __enter__(self) -> Self:
        return self

    def __exit__(
        self,
        _exception_type: type[BaseException] | None,
        _exception: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        self.close()

    def close(self) -> None:
        self._connection.close()

    @property
    def device_id(self) -> UUID:
        return UUID(str(self._metadata()["device_id"]))

    @property
    def cursor(self) -> str:
        return format_cursor(int(self._metadata()["cursor"]))

    @property
    def server_epoch(self) -> int:
        return int(self._metadata()["server_epoch"])

    def queue_capture(
        self,
        *,
        content_or_object_ref: str,
        timezone: str,
        invoking_surface: str,
        captured_at: datetime | None = None,
        kind: CapturePayloadKind = CapturePayloadKind.TEXT,
        sensitivity: DataClass = DataClass.PRIVATE,
        broad_location: str | None = None,
        capture_id: UUID | None = None,
        event_id: UUID | None = None,
        operation_id: UUID | None = None,
    ) -> QueuedCapture:
        if not content_or_object_ref:
            raise ValueError("capture content cannot be empty")
        occurred_at = captured_at or datetime.now(UTC)
        if occurred_at.tzinfo is None:
            raise ValueError("captured_at must include a timezone")
        selected_capture_id = capture_id or new_uuid7()
        selected_event_id = event_id or new_uuid7()
        selected_operation_id = operation_id or new_uuid7()
        capture_body: dict[str, JsonValue] = {
            "capture_id": str(selected_capture_id),
            "event_id": str(selected_event_id),
            "captured_at": occurred_at.isoformat(),
            "kind": kind.value,
            "content_or_object_ref": content_or_object_ref,
            "device_id": str(self.device_id),
            "timezone": timezone,
            "broad_location": broad_location,
            "invoking_surface": invoking_surface,
            "sensitivity": sensitivity.value,
        }
        sync_payload: dict[str, JsonValue] = {
            "capture_id": str(selected_capture_id),
            "event_id": str(selected_event_id),
            "kind": kind.value,
            "content_or_object_ref": content_or_object_ref,
            "captured_at": occurred_at.isoformat(),
            "initial_context": {
                "device_id": str(self.device_id),
                "timezone": timezone,
                "broad_location": broad_location,
                "invoking_surface": invoking_surface,
            },
            "interpretation_status": "pending",
        }
        with self._transaction():
            sequence = self._next_device_sequence()
            operation = SyncOperationInput(
                operation_id=selected_operation_id,
                device_sequence=sequence,
                entity_type="capture",
                entity_id=selected_capture_id,
                mutation_type=SyncMutationType.CREATE,
                payload=sync_payload,
                created_at=occurred_at,
                idempotency_key=str(selected_operation_id),
                sensitivity_class=sensitivity,
            )
            self._connection.execute(
                """
                INSERT INTO capture_requests(
                    capture_id, event_id, operation_id, request_json,
                    idempotency_key, delivery_state, created_at
                ) VALUES (?, ?, ?, ?, ?, 'pending', ?)
                """,
                (
                    str(selected_capture_id),
                    str(selected_event_id),
                    str(selected_operation_id),
                    _dump_json(capture_body),
                    str(selected_event_id),
                    occurred_at.isoformat(),
                ),
            )
            self._insert_operation(operation)
            self._write_optimistic_entity(operation)
            self._connection.execute(
                "UPDATE client_metadata SET next_device_sequence=? WHERE singleton=1",
                (sequence + 1,),
            )
        return QueuedCapture(
            capture_id=selected_capture_id,
            event_id=selected_event_id,
            operation_id=selected_operation_id,
            device_sequence=sequence,
        )

    def queue_operation(
        self,
        *,
        entity_type: str,
        entity_id: UUID,
        mutation_type: SyncMutationType,
        payload: dict[str, JsonValue] | None = None,
        base_revision: int | None = None,
        created_at: datetime | None = None,
        operation_id: UUID | None = None,
        sensitivity: DataClass = DataClass.PRIVATE,
    ) -> UUID:
        occurred_at = created_at or datetime.now(UTC)
        if occurred_at.tzinfo is None:
            raise ValueError("created_at must include a timezone")
        selected_operation_id = operation_id or new_uuid7()
        with self._transaction():
            sequence = self._next_device_sequence()
            operation = SyncOperationInput(
                operation_id=selected_operation_id,
                device_sequence=sequence,
                entity_type=entity_type,
                entity_id=entity_id,
                mutation_type=mutation_type,
                base_revision=base_revision,
                payload=payload or {},
                created_at=occurred_at,
                idempotency_key=str(selected_operation_id),
                sensitivity_class=sensitivity,
            )
            self._insert_operation(operation)
            self._write_optimistic_entity(operation)
            self._connection.execute(
                "UPDATE client_metadata SET next_device_sequence=? WHERE singleton=1",
                (sequence + 1,),
            )
        return selected_operation_id

    def next_capture(self) -> OutboundCapture | None:
        with self._transaction():
            row = self._connection.execute(
                """
                SELECT capture_id, idempotency_key, request_json, delivery_state
                FROM capture_requests
                WHERE delivery_state IN ('pending', 'in_flight')
                ORDER BY created_at, capture_id
                LIMIT 1
                """
            ).fetchone()
            if row is None:
                return None
            if row["delivery_state"] == "pending":
                self._connection.execute(
                    "UPDATE capture_requests SET delivery_state='in_flight' WHERE capture_id=?",
                    (row["capture_id"],),
                )
            return OutboundCapture(
                capture_id=UUID(str(row["capture_id"])),
                idempotency_key=str(row["idempotency_key"]),
                body=_load_document(str(row["request_json"])),
            )

    def apply_capture_response(
        self,
        capture_id: UUID,
        response: Mapping[str, object],
    ) -> None:
        response_capture_id = UUID(str(response.get("capture_id", "")))
        response_event_id = UUID(str(response.get("event_id", "")))
        ledger_sequence = response.get("ledger_sequence")
        if response_capture_id != capture_id or not isinstance(ledger_sequence, int):
            raise SimulatedClientError("capture response does not match the durable request")
        with self._transaction():
            row = self._connection.execute(
                """
                SELECT event_id, delivery_state, response_json
                FROM capture_requests WHERE capture_id=?
                """,
                (str(capture_id),),
            ).fetchone()
            if row is None or UUID(str(row["event_id"])) != response_event_id:
                raise SimulatedClientError("capture response references an unknown request")
            response_json = _dump_json(dict(response))
            if row["delivery_state"] == "confirmed":
                if row["response_json"] != response_json:
                    raise SimulatedClientError("confirmed capture received a different response")
                return
            self._connection.execute(
                """
                UPDATE capture_requests
                SET delivery_state='confirmed', response_json=?, confirmed_at=?
                WHERE capture_id=?
                """,
                (response_json, datetime.now(UTC).isoformat(), str(capture_id)),
            )

    def next_push(self, *, limit: int = 500) -> OutboundPush | None:
        if limit < 1 or limit > 500:
            raise ValueError("push limit must be between 1 and 500")
        with self._transaction():
            existing = self._connection.execute(
                """
                SELECT idempotency_key, request_json
                FROM push_batches
                WHERE delivery_state='in_flight'
                ORDER BY created_at, idempotency_key
                LIMIT 1
                """
            ).fetchone()
            if existing is not None:
                return OutboundPush(
                    idempotency_key=str(existing["idempotency_key"]),
                    request=SyncPushRequest.model_validate_json(str(existing["request_json"])),
                )
            rows = self._connection.execute(
                """
                SELECT operation_id, operation_json
                FROM operations
                WHERE delivery_state='pending'
                ORDER BY device_sequence
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
            if not rows:
                return None
            operations = tuple(
                SyncOperationInput.model_validate_json(str(row["operation_json"])) for row in rows
            )
            request = SyncPushRequest(
                device_id=self.device_id,
                client_schema_version=int(self._metadata()["schema_version"]),
                base_cursor=self.cursor,
                operations=operations,
            )
            batch_key = f"simulated-{new_uuid7()}"
            request_json = request.model_dump_json()
            created_at = datetime.now(UTC).isoformat()
            self._connection.execute(
                """
                INSERT INTO push_batches(
                    idempotency_key, base_cursor, request_json, delivery_state, created_at
                ) VALUES (?, ?, ?, 'in_flight', ?)
                """,
                (batch_key, parse_cursor(request.base_cursor), request_json, created_at),
            )
            for ordinal, row in enumerate(rows):
                self._connection.execute(
                    """
                    INSERT INTO push_batch_operations(idempotency_key, operation_id, ordinal)
                    VALUES (?, ?, ?)
                    """,
                    (batch_key, row["operation_id"], ordinal),
                )
                self._connection.execute(
                    "UPDATE operations SET delivery_state='in_flight' WHERE operation_id=?",
                    (row["operation_id"],),
                )
            return OutboundPush(idempotency_key=batch_key, request=request)

    def apply_push_response(
        self,
        batch_idempotency_key: str,
        response: SyncPushResponse,
    ) -> None:
        response_json = response.model_dump_json()
        with self._transaction():
            batch = self._connection.execute(
                """
                SELECT base_cursor, delivery_state, response_json
                FROM push_batches WHERE idempotency_key=?
                """,
                (batch_idempotency_key,),
            ).fetchone()
            if batch is None:
                raise SimulatedClientError("push response references an unknown batch")
            if batch["delivery_state"] == "completed":
                if batch["response_json"] != response_json:
                    raise SimulatedClientError("completed push batch received a different response")
                return
            if batch["delivery_state"] != "in_flight":
                raise SimulatedClientError("push response references an inactive batch")
            response_cursor = parse_cursor(response.next_cursor)
            if response_cursor < int(batch["base_cursor"]):
                raise SimulatedClientError("push response moved the server cursor backwards")
            operation_rows = self._connection.execute(
                """
                SELECT operation_id FROM push_batch_operations
                WHERE idempotency_key=? ORDER BY ordinal
                """,
                (batch_idempotency_key,),
            ).fetchall()
            batch_operation_ids = {UUID(str(row["operation_id"])) for row in operation_rows}
            reported_ids = {item.operation_id for item in response.accepted}
            reported_ids.update(item.operation_id for item in response.rejected)
            reported_ids.update(item.operation_id for item in response.conflicts)
            if not reported_ids.issubset(batch_operation_ids):
                raise SimulatedClientError("push response contains an operation outside the batch")
            now = datetime.now(UTC).isoformat()
            response_hash = sha256(response_json.encode()).hexdigest()
            for accepted in response.accepted:
                self._connection.execute(
                    """
                    UPDATE operations
                    SET delivery_state='acknowledged', latest_server_change_id=?,
                        latest_canonical_revision=?, latest_merge_result=?
                    WHERE operation_id=?
                    """,
                    (
                        accepted.server_change_id,
                        accepted.canonical_revision,
                        accepted.merge_result,
                        str(accepted.operation_id),
                    ),
                )
                self._connection.execute(
                    """
                    INSERT INTO operation_acknowledgements(
                        operation_id, server_epoch, server_change_id,
                        canonical_revision, merge_result, response_hash, acknowledged_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        str(accepted.operation_id),
                        self.server_epoch,
                        accepted.server_change_id,
                        accepted.canonical_revision,
                        accepted.merge_result,
                        response_hash,
                        now,
                    ),
                )
                self._confirm_optimistic_entity(accepted.operation_id)
            for rejected in response.rejected:
                state = DeliveryState.PENDING if rejected.retryable else DeliveryState.REJECTED
                self._connection.execute(
                    "UPDATE operations SET delivery_state=? WHERE operation_id=?",
                    (state.value, str(rejected.operation_id)),
                )
            for conflict in response.conflicts:
                self._connection.execute(
                    "UPDATE operations SET delivery_state='conflict' WHERE operation_id=?",
                    (str(conflict.operation_id),),
                )
            for operation_id in batch_operation_ids - reported_ids:
                self._connection.execute(
                    "UPDATE operations SET delivery_state='pending' WHERE operation_id=?",
                    (str(operation_id),),
                )
            self._connection.execute(
                "UPDATE client_metadata SET cursor=MAX(cursor, ?) WHERE singleton=1",
                (response_cursor,),
            )
            self._connection.execute(
                """
                UPDATE push_batches
                SET delivery_state='completed', response_json=?, completed_at=?
                WHERE idempotency_key=?
                """,
                (response_json, now, batch_idempotency_key),
            )

    def apply_pull_response(self, response: SyncPullResponse) -> None:
        with self._transaction():
            current_cursor = parse_cursor(self.cursor)
            response_cursor = parse_cursor(response.next_cursor)
            if response_cursor < current_cursor:
                raise SimulatedClientError("pull response moved the server cursor backwards")
            change_ids = [change.change_id for change in response.changes]
            if change_ids != sorted(set(change_ids)):
                raise SimulatedClientError("pull changes are not unique and ascending")
            if change_ids and (change_ids[0] <= current_cursor or change_ids[-1] > response_cursor):
                raise SimulatedClientError("pull changes do not match the requested cursor window")
            for change in response.changes:
                self._apply_change(change)
            self._connection.execute(
                "UPDATE client_metadata SET cursor=? WHERE singleton=1",
                (response_cursor,),
            )

    def reconcile_server_restore(
        self,
        restored_cursor: str,
        *,
        backup_history_verified: bool,
        backup_reference: str,
        confirmed_by: str,
    ) -> RestoreReplayPlan:
        target_cursor = parse_cursor(restored_cursor)
        metadata = self._metadata()
        previous_cursor = int(metadata["cursor"])
        previous_epoch = int(metadata["server_epoch"])
        if target_cursor >= previous_cursor:
            raise SimulatedClientError("restore reconciliation requires a server cursor rollback")
        if not backup_history_verified or not backup_reference.strip() or not confirmed_by.strip():
            raise SimulatedClientError(
                "restore replay requires verified backup history and an operator confirmation"
            )
        with self._transaction():
            in_flight = self._connection.execute(
                """
                SELECT operation_id FROM operations WHERE delivery_state='in_flight'
                """
            ).fetchall()
            self._connection.execute(
                """
                UPDATE push_batches
                SET delivery_state='abandoned_restore', completed_at=?
                WHERE delivery_state='in_flight'
                """,
                (datetime.now(UTC).isoformat(),),
            )
            self._connection.execute(
                "UPDATE operations SET delivery_state='pending' WHERE delivery_state='in_flight'"
            )
            acknowledged = self._connection.execute(
                """
                SELECT DISTINCT operation_id
                FROM operation_acknowledgements
                WHERE server_epoch=? AND server_change_id>?
                ORDER BY operation_id
                """,
                (previous_epoch, target_cursor),
            ).fetchall()
            requeued = {UUID(str(row["operation_id"])) for row in (*in_flight, *acknowledged)}
            for operation_id in requeued:
                self._connection.execute(
                    "UPDATE operations SET delivery_state='pending' WHERE operation_id=?",
                    (str(operation_id),),
                )
            new_epoch = previous_epoch + 1
            now = datetime.now(UTC).isoformat()
            self._connection.execute(
                "UPDATE client_metadata SET cursor=?, server_epoch=? WHERE singleton=1",
                (target_cursor, new_epoch),
            )
            self._connection.execute(
                """
                INSERT INTO restore_reconciliations(
                    previous_cursor, restored_cursor, previous_server_epoch,
                    server_epoch, backup_reference, confirmed_by,
                    requeued_operation_count, confirmed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    previous_cursor,
                    target_cursor,
                    previous_epoch,
                    new_epoch,
                    backup_reference,
                    confirmed_by,
                    len(requeued),
                    now,
                ),
            )
        return RestoreReplayPlan(
            previous_cursor=format_cursor(previous_cursor),
            restored_cursor=restored_cursor,
            previous_server_epoch=previous_epoch,
            server_epoch=previous_epoch + 1,
            requeued_operation_ids=tuple(sorted(requeued, key=str)),
        )

    def entity(self, entity_type: str, entity_id: UUID) -> LocalEntity | None:
        row = self._connection.execute(
            """
            SELECT entity_type, entity_id, canonical_revision, document_json,
                   tombstoned, last_change_id, server_epoch
            FROM canonical_entities WHERE entity_type=? AND entity_id=?
            """,
            (entity_type, str(entity_id)),
        ).fetchone()
        if row is None:
            return None
        return LocalEntity(
            entity_type=str(row["entity_type"]),
            entity_id=UUID(str(row["entity_id"])),
            canonical_revision=int(row["canonical_revision"]),
            document=_load_document(str(row["document_json"])),
            tombstoned=bool(row["tombstoned"]),
            last_change_id=int(row["last_change_id"]),
            server_epoch=int(row["server_epoch"]),
        )

    def operation_state(self, operation_id: UUID) -> DeliveryState:
        row = self._connection.execute(
            "SELECT delivery_state FROM operations WHERE operation_id=?",
            (str(operation_id),),
        ).fetchone()
        if row is None:
            raise SimulatedClientError("unknown operation")
        return DeliveryState(str(row["delivery_state"]))

    def acknowledgement_count(self, operation_id: UUID) -> int:
        row = self._connection.execute(
            """
            SELECT COUNT(*) AS count FROM operation_acknowledgements WHERE operation_id=?
            """,
            (str(operation_id),),
        ).fetchone()
        return int(row["count"])

    @contextmanager
    def _transaction(self) -> Iterator[None]:
        self._connection.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self._connection.rollback()
            raise
        else:
            self._connection.commit()

    def _initialize(self, *, device_id: UUID | None, schema_version: int) -> None:
        user_version = int(self._connection.execute("PRAGMA user_version").fetchone()[0])
        if user_version not in {0, CLIENT_SCHEMA_VERSION}:
            raise SimulatedClientError(
                f"unsupported simulated client schema version {user_version}"
            )
        self._connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS client_metadata(
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                device_id TEXT NOT NULL,
                cursor INTEGER NOT NULL CHECK(cursor>=0),
                next_device_sequence INTEGER NOT NULL CHECK(next_device_sequence>=1),
                schema_version INTEGER NOT NULL CHECK(schema_version>=1),
                server_epoch INTEGER NOT NULL CHECK(server_epoch>=1)
            );
            CREATE TABLE IF NOT EXISTS capture_requests(
                capture_id TEXT PRIMARY KEY,
                event_id TEXT NOT NULL UNIQUE,
                operation_id TEXT NOT NULL UNIQUE,
                request_json TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                delivery_state TEXT NOT NULL,
                response_json TEXT,
                created_at TEXT NOT NULL,
                confirmed_at TEXT
            );
            CREATE TABLE IF NOT EXISTS operations(
                operation_id TEXT PRIMARY KEY,
                device_sequence INTEGER NOT NULL UNIQUE,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                operation_json TEXT NOT NULL,
                delivery_state TEXT NOT NULL,
                latest_server_change_id INTEGER,
                latest_canonical_revision INTEGER,
                latest_merge_result TEXT,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS push_batches(
                idempotency_key TEXT PRIMARY KEY,
                base_cursor INTEGER NOT NULL,
                request_json TEXT NOT NULL,
                delivery_state TEXT NOT NULL,
                response_json TEXT,
                created_at TEXT NOT NULL,
                completed_at TEXT
            );
            CREATE TABLE IF NOT EXISTS push_batch_operations(
                idempotency_key TEXT NOT NULL REFERENCES push_batches(idempotency_key),
                operation_id TEXT NOT NULL REFERENCES operations(operation_id),
                ordinal INTEGER NOT NULL,
                PRIMARY KEY(idempotency_key, operation_id),
                UNIQUE(idempotency_key, ordinal)
            );
            CREATE TABLE IF NOT EXISTS operation_acknowledgements(
                acknowledgement_id INTEGER PRIMARY KEY AUTOINCREMENT,
                operation_id TEXT NOT NULL REFERENCES operations(operation_id),
                server_epoch INTEGER NOT NULL,
                server_change_id INTEGER NOT NULL,
                canonical_revision INTEGER NOT NULL,
                merge_result TEXT NOT NULL,
                response_hash TEXT NOT NULL,
                acknowledged_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS server_changes(
                server_epoch INTEGER NOT NULL,
                change_id INTEGER NOT NULL,
                change_json TEXT NOT NULL,
                PRIMARY KEY(server_epoch, change_id)
            );
            CREATE TABLE IF NOT EXISTS canonical_entities(
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                canonical_revision INTEGER NOT NULL,
                document_json TEXT NOT NULL,
                tombstoned INTEGER NOT NULL,
                last_change_id INTEGER NOT NULL,
                server_epoch INTEGER NOT NULL,
                PRIMARY KEY(entity_type, entity_id)
            );
            CREATE TABLE IF NOT EXISTS restore_reconciliations(
                reconciliation_id INTEGER PRIMARY KEY AUTOINCREMENT,
                previous_cursor INTEGER NOT NULL,
                restored_cursor INTEGER NOT NULL,
                previous_server_epoch INTEGER NOT NULL,
                server_epoch INTEGER NOT NULL,
                backup_reference TEXT NOT NULL,
                confirmed_by TEXT NOT NULL,
                requeued_operation_count INTEGER NOT NULL,
                confirmed_at TEXT NOT NULL
            );
            CREATE TRIGGER IF NOT EXISTS operations_no_delete
            BEFORE DELETE ON operations
            BEGIN SELECT RAISE(ABORT, 'operation history is immutable'); END;
            CREATE TRIGGER IF NOT EXISTS operations_core_immutable
            BEFORE UPDATE OF operation_id, device_sequence, entity_type,
                             entity_id, operation_json, created_at ON operations
            BEGIN SELECT RAISE(ABORT, 'operation content is immutable'); END;
            CREATE TRIGGER IF NOT EXISTS acknowledgements_no_update
            BEFORE UPDATE ON operation_acknowledgements
            BEGIN SELECT RAISE(ABORT, 'acknowledgement history is immutable'); END;
            CREATE TRIGGER IF NOT EXISTS acknowledgements_no_delete
            BEFORE DELETE ON operation_acknowledgements
            BEGIN SELECT RAISE(ABORT, 'acknowledgement history is immutable'); END;
            PRAGMA user_version=1;
            """
        )
        metadata = self._connection.execute(
            "SELECT device_id, schema_version FROM client_metadata WHERE singleton=1"
        ).fetchone()
        if metadata is None:
            self._connection.execute(
                """
                INSERT INTO client_metadata(
                    singleton, device_id, cursor, next_device_sequence,
                    schema_version, server_epoch
                ) VALUES (1, ?, 0, 1, ?, 1)
                """,
                (str(device_id or new_uuid7()), schema_version),
            )
            return
        if device_id is not None and str(metadata["device_id"]) != str(device_id):
            raise SimulatedClientError("existing client database belongs to another device")
        if int(metadata["schema_version"]) != schema_version:
            raise SimulatedClientError("existing client database uses another sync schema version")

    def _metadata(self) -> sqlite3.Row:
        row = self._connection.execute(
            "SELECT * FROM client_metadata WHERE singleton=1"
        ).fetchone()
        if row is None:
            raise SimulatedClientError("client metadata is missing")
        return cast(sqlite3.Row, row)

    def _next_device_sequence(self) -> int:
        return int(self._metadata()["next_device_sequence"])

    def _insert_operation(self, operation: SyncOperationInput) -> None:
        self._connection.execute(
            """
            INSERT INTO operations(
                operation_id, device_sequence, entity_type, entity_id,
                operation_json, delivery_state, created_at
            ) VALUES (?, ?, ?, ?, ?, 'pending', ?)
            """,
            (
                str(operation.operation_id),
                operation.device_sequence,
                operation.entity_type,
                str(operation.entity_id),
                operation.model_dump_json(),
                operation.created_at.isoformat(),
            ),
        )

    def _write_optimistic_entity(self, operation: SyncOperationInput) -> None:
        existing = self._connection.execute(
            """
            SELECT document_json, canonical_revision, last_change_id, server_epoch
            FROM canonical_entities WHERE entity_type=? AND entity_id=?
            """,
            (operation.entity_type, str(operation.entity_id)),
        ).fetchone()
        document = _load_document(str(existing["document_json"])) if existing else {}
        if operation.mutation_type is SyncMutationType.CREATE:
            document = dict(operation.payload)
        elif operation.mutation_type is SyncMutationType.UPDATE:
            document.update(operation.payload)
        self._connection.execute(
            """
            INSERT INTO canonical_entities(
                entity_type, entity_id, canonical_revision, document_json,
                tombstoned, last_change_id, server_epoch
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                document_json=excluded.document_json,
                tombstoned=excluded.tombstoned
            """,
            (
                operation.entity_type,
                str(operation.entity_id),
                int(existing["canonical_revision"]) if existing else 0,
                _dump_json(document),
                int(operation.mutation_type is SyncMutationType.DELETE),
                int(existing["last_change_id"]) if existing else 0,
                int(existing["server_epoch"]) if existing else self.server_epoch,
            ),
        )

    def _confirm_optimistic_entity(self, operation_id: UUID) -> None:
        row = self._connection.execute(
            """
            SELECT entity_type, entity_id, latest_canonical_revision,
                   latest_server_change_id
            FROM operations WHERE operation_id=?
            """,
            (str(operation_id),),
        ).fetchone()
        if row is None:
            raise SimulatedClientError("acknowledgement references an unknown operation")
        self._connection.execute(
            """
            UPDATE canonical_entities
            SET canonical_revision=?, last_change_id=?, server_epoch=?
            WHERE entity_type=? AND entity_id=?
            """,
            (
                row["latest_canonical_revision"],
                row["latest_server_change_id"],
                self.server_epoch,
                row["entity_type"],
                row["entity_id"],
            ),
        )

    def _apply_change(self, change: SyncChange) -> None:
        change_json = change.model_dump_json()
        existing = self._connection.execute(
            "SELECT change_json FROM server_changes WHERE server_epoch=? AND change_id=?",
            (self.server_epoch, change.change_id),
        ).fetchone()
        if existing is not None:
            if existing["change_json"] != change_json:
                raise SimulatedClientError("server reused a change ID with different content")
            return
        self._connection.execute(
            "INSERT INTO server_changes(server_epoch, change_id, change_json) VALUES (?, ?, ?)",
            (self.server_epoch, change.change_id, change_json),
        )
        self._connection.execute(
            """
            INSERT INTO canonical_entities(
                entity_type, entity_id, canonical_revision, document_json,
                tombstoned, last_change_id, server_epoch
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                canonical_revision=excluded.canonical_revision,
                document_json=excluded.document_json,
                tombstoned=excluded.tombstoned,
                last_change_id=excluded.last_change_id,
                server_epoch=excluded.server_epoch
            """,
            (
                change.entity_type,
                str(change.entity_id),
                change.canonical_revision,
                _dump_json(change.payload),
                int(change.tombstone),
                change.change_id,
                self.server_epoch,
            ),
        )
