"""Owner-safe synchronization diagnostics and client queue reporting."""

from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.attachments.contracts import AttachmentStatus
from odyssey.attachments.models import AttachmentRecord
from odyssey.db.models import OutboxRecord
from odyssey.operations.kill_switches import KillSwitchKey, KillSwitchService
from odyssey.sync.contracts import (
    SchemaCompatibility,
    SyncDeviceDiagnostics,
    SyncDeviceDiagnosticsInput,
    SyncDiagnosticsResponse,
    SyncRepairOptions,
    format_cursor,
    parse_cursor,
)
from odyssey.sync.models import SyncConflictRecord, SyncDeviceRecord, SyncStateRecord
from odyssey.sync.service import SYNC_STATE_KEY, CursorAheadError


class SyncDiagnosticsService:
    def __init__(
        self,
        *,
        minimum_client_schema_version: int,
        current_schema_version: int,
        stale_after: timedelta = timedelta(hours=24),
    ) -> None:
        self.minimum_client_schema_version = minimum_client_schema_version
        self.current_schema_version = current_schema_version
        self.stale_after = stale_after

    async def report_device(
        self,
        session: AsyncSession,
        *,
        device_id: UUID,
        report: SyncDeviceDiagnosticsInput,
        now: datetime,
    ) -> SyncDeviceDiagnostics:
        state = await session.get(SyncStateRecord, SYNC_STATE_KEY)
        server_cursor = state.last_change_id if state is not None else 0
        device_cursor = parse_cursor(report.device_cursor)
        if device_cursor > server_cursor:
            raise CursorAheadError("reported device cursor is ahead of the server")
        device = await session.scalar(
            select(SyncDeviceRecord).where(SyncDeviceRecord.id == device_id).with_for_update()
        )
        if device is None:
            device = SyncDeviceRecord(
                id=device_id,
                last_device_sequence=0,
                last_server_cursor=device_cursor,
                client_schema_version=report.client_schema_version,
                registered_at=now,
                local_queued_operations=report.operations_queued,
                local_oldest_unsynced_at=report.oldest_unsynced_operation_at,
                local_attachment_backlog=report.attachment_backlog,
                diagnostics_reported_at=now,
            )
            session.add(device)
        else:
            device.client_schema_version = report.client_schema_version
            device.last_server_cursor = device_cursor
            device.local_queued_operations = report.operations_queued
            device.local_oldest_unsynced_at = report.oldest_unsynced_operation_at
            device.local_attachment_backlog = report.attachment_backlog
            device.diagnostics_reported_at = now
        await session.flush()
        return self.device_contract(device, server_cursor=server_cursor, now=now)

    async def snapshot(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        now: datetime,
    ) -> SyncDiagnosticsResponse:
        state = await session.get(SyncStateRecord, SYNC_STATE_KEY)
        server_cursor = state.last_change_id if state is not None else 0
        devices = tuple(
            (
                await session.scalars(
                    select(SyncDeviceRecord).order_by(
                        SyncDeviceRecord.registered_at,
                        SyncDeviceRecord.id,
                    )
                )
            ).all()
        )
        pending_conflicts = int(
            await session.scalar(
                select(func.count())
                .select_from(SyncConflictRecord)
                .where(SyncConflictRecord.status == "pending")
            )
            or 0
        )
        pending_attachments = int(
            await session.scalar(
                select(func.count())
                .select_from(AttachmentRecord)
                .where(
                    AttachmentRecord.owner_id == owner_id,
                    AttachmentRecord.status == AttachmentStatus.PENDING_UPLOAD,
                )
            )
            or 0
        )
        pending_outbox = int(
            await session.scalar(
                select(func.count())
                .select_from(OutboxRecord)
                .where(OutboxRecord.status.in_(("pending", "retry", "processing")))
            )
            or 0
        )
        switches = KillSwitchService()
        push_disabled = await switches.is_enabled(session, KillSwitchKey.SYNC_PUSH)
        pull_disabled = await switches.is_enabled(session, KillSwitchKey.SYNC_PULL)
        return SyncDiagnosticsResponse(
            server_time=now,
            server_cursor=format_cursor(server_cursor),
            server_schema_version=self.current_schema_version,
            minimum_client_schema_version=self.minimum_client_schema_version,
            pending_conflicts=pending_conflicts,
            pending_attachment_uploads=pending_attachments,
            pending_outbox_jobs=pending_outbox,
            sync_push_enabled=not push_disabled,
            sync_pull_enabled=not pull_disabled,
            devices=tuple(
                self.device_contract(device, server_cursor=server_cursor, now=now)
                for device in devices
            ),
            repair=SyncRepairOptions(
                projection_rebuild_available=True,
                projection_rebuild_command="make rebuild-projections",
                integrity_check_command=(
                    "cd backend && uv run python ../tools/integrity/check_database.py"
                ),
            ),
        )

    def device_contract(
        self,
        device: SyncDeviceRecord,
        *,
        server_cursor: int,
        now: datetime,
    ) -> SyncDeviceDiagnostics:
        reported_at = (
            self.aware(device.diagnostics_reported_at)
            if device.diagnostics_reported_at is not None
            else None
        )
        return SyncDeviceDiagnostics(
            device_id=device.id,
            client_schema_version=device.client_schema_version,
            schema_compatibility=self.compatibility(device.client_schema_version),
            last_successful_push_at=(
                self.aware(device.last_push_at) if device.last_push_at is not None else None
            ),
            last_successful_pull_at=(
                self.aware(device.last_pull_at) if device.last_pull_at is not None else None
            ),
            operations_queued=device.local_queued_operations,
            oldest_unsynced_operation_at=(
                self.aware(device.local_oldest_unsynced_at)
                if device.local_oldest_unsynced_at is not None
                else None
            ),
            attachment_backlog=device.local_attachment_backlog,
            last_device_sequence=device.last_device_sequence,
            device_cursor=format_cursor(device.last_server_cursor),
            server_cursor=format_cursor(server_cursor),
            clock_skew_seconds=device.clock_skew_seconds,
            diagnostics_reported_at=reported_at,
            diagnostics_stale=(reported_at is None or now - reported_at > self.stale_after),
        )

    def compatibility(self, client_schema_version: int) -> SchemaCompatibility:
        if client_schema_version < self.minimum_client_schema_version:
            return SchemaCompatibility.CLIENT_UPGRADE_REQUIRED
        if client_schema_version > self.current_schema_version:
            return SchemaCompatibility.SERVER_UPGRADE_REQUIRED
        return SchemaCompatibility.COMPATIBLE

    @staticmethod
    def aware(value: datetime) -> datetime:
        return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
