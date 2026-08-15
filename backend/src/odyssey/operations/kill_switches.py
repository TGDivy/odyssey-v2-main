"""Audited operational kill switches with fail-open defaults for absent keys."""

from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.db.models import KillSwitch, KillSwitchAuditRecord
from odyssey.domain.common import new_uuid7


class KillSwitchKey(StrEnum):
    CAPTURE_WRITES = "capture_writes"
    SYNC_PUSH = "sync_push"
    SYNC_PULL = "sync_pull"
    PROACTIVE_DELIVERY = "proactive_delivery"
    AI_GENERATION = "ai_generation"
    EXTERNAL_SIDE_EFFECTS = "external_side_effects"
    DESTRUCTIVE_COMPACTION = "destructive_compaction"


@dataclass(frozen=True, slots=True)
class KillSwitchState:
    key: str
    enabled: bool
    reason: str | None
    updated_at: datetime
    updated_by: str

    def as_json(self) -> dict[str, Any]:
        instant = (
            self.updated_at
            if self.updated_at.tzinfo is not None
            else self.updated_at.replace(tzinfo=UTC)
        )
        return {
            "key": self.key,
            "enabled": self.enabled,
            "reason": self.reason,
            "updated_at": instant.astimezone(UTC).isoformat().replace("+00:00", "Z"),
            "updated_by": self.updated_by,
        }


class KillSwitchService:
    async def is_enabled(self, session: AsyncSession, key: KillSwitchKey | str) -> bool:
        record = await session.get(KillSwitch, str(key))
        return bool(record and record.enabled)

    async def list(self, session: AsyncSession) -> tuple[KillSwitchState, ...]:
        records = (await session.scalars(select(KillSwitch).order_by(KillSwitch.key.asc()))).all()
        return tuple(
            KillSwitchState(
                key=record.key,
                enabled=record.enabled,
                reason=record.reason,
                updated_at=record.updated_at,
                updated_by=record.updated_by,
            )
            for record in records
        )

    async def set(
        self,
        session: AsyncSession,
        *,
        key: KillSwitchKey | str,
        enabled: bool,
        reason: str,
        changed_by: str,
        change_source: str,
        correlation_id: str | None = None,
        changed_at: datetime | None = None,
    ) -> KillSwitchState:
        key_value = str(key)
        if not reason.strip():
            raise ValueError("kill-switch changes require a reason")
        if not changed_by.strip():
            raise ValueError("kill-switch changes require an actor")
        change_time = changed_at or datetime.now(UTC)
        record = await session.get(KillSwitch, key_value)
        if record is None:
            record = KillSwitch(
                key=key_value,
                enabled=enabled,
                reason=reason,
                updated_at=change_time,
                updated_by=changed_by,
            )
            session.add(record)
        else:
            record.enabled = enabled
            record.reason = reason
            record.updated_at = change_time
            record.updated_by = changed_by
        session.add(
            KillSwitchAuditRecord(
                id=new_uuid7(),
                key=key_value,
                enabled=enabled,
                reason=reason,
                changed_at=change_time,
                changed_by=changed_by,
                change_source=change_source,
                correlation_id=correlation_id,
            )
        )
        await session.flush()
        return KillSwitchState(
            key=record.key,
            enabled=record.enabled,
            reason=record.reason,
            updated_at=record.updated_at,
            updated_by=record.updated_by,
        )
