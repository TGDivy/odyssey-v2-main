"""Model-free context assembly from canonical synchronized facts."""

import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from typing import cast
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.context.contracts import (
    AssembledContextSnapshot,
    ContextAssemblyRequest,
    ContextAssemblyResponse,
    ContextDomain,
    ContextDomainSnapshot,
    ContextDomainStatus,
    ContextFact,
    ContextReason,
)
from odyssey.context.persistence import ContextSnapshotRecord
from odyssey.domain.common import new_uuid7
from odyssey.life.contracts import LifeModelKind
from odyssey.life.service import LifeModelService
from odyssey.sync.models import CanonicalEntityRecord

CONTEXT_BUILDER_VERSION = "deterministic-context-builder-1.1"

_DOMAIN_ENTITY_TYPES = {
    ContextDomain.CALENDAR: frozenset({"calendar_event", "calendar_block"}),
    ContextDomain.SLEEP: frozenset({"health_observation", "sleep_observation", "sleep_summary"}),
    ContextDomain.TRAINING: frozenset({"training_action", "training_plan", "workout"}),
    ContextDomain.SEASON: frozenset(
        {"charter", "charter_version", "life_stage", "season", "season_version", "commitment"}
    ),
    ContextDomain.LOCATION: frozenset({"location_context"}),
    ContextDomain.INTENTS: frozenset({"intent", "intervention_opportunity"}),
    ContextDomain.DECISIONS: frozenset({"decision", "decision_choice", "choice"}),
    ContextDomain.RELATIONSHIPS: frozenset(
        {"person", "relationship", "relationship_assertion", "meaningful_contact"}
    ),
    ContextDomain.TRAVEL: frozenset({"travel_context", "travel_plan"}),
    ContextDomain.WEATHER: frozenset({"weather_context"}),
}
_FRESHNESS_LIMITS: dict[ContextDomain, timedelta | None] = {
    ContextDomain.CALENDAR: timedelta(hours=24),
    ContextDomain.SLEEP: timedelta(hours=48),
    ContextDomain.TRAINING: timedelta(hours=48),
    ContextDomain.SEASON: None,
    ContextDomain.LOCATION: timedelta(hours=2),
    ContextDomain.INTENTS: timedelta(days=7),
    ContextDomain.DECISIONS: timedelta(days=7),
    ContextDomain.RELATIONSHIPS: timedelta(days=30),
    ContextDomain.TRAVEL: timedelta(hours=24),
    ContextDomain.WEATHER: timedelta(hours=6),
}
_DENIED_PERMISSION_STATES = frozenset({"denied", "restricted", "revoked"})
_ACCEPTED_LIFE_ENTITY_TYPES = frozenset(
    {"charter", "charter_version", "life_stage", "season", "season_version"}
)
_LIFE_ENTITY_TYPE = {
    LifeModelKind.CHARTER: "charter_version",
    LifeModelKind.LIFE_STAGE: "life_stage",
    LifeModelKind.SEASON: "season_version",
}


@dataclass(frozen=True, slots=True)
class ContextSourceRow:
    entity_type: str
    entity_id: UUID
    canonical_revision: int
    updated_at: datetime
    content_hash: str
    document: dict[str, object]


class ContextAssemblyError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class ContextAssemblyService:
    async def assemble(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        request: ContextAssemblyRequest,
        now: datetime | None = None,
    ) -> ContextAssemblyResponse:
        built_at = now or datetime.now(UTC)
        if request.as_of > built_at + timedelta(minutes=5):
            raise ContextAssemblyError(
                "CONTEXT_AS_OF_IN_FUTURE",
                "Context cannot be assembled for a materially future instant.",
            )
        requested_types = set().union(
            *(_DOMAIN_ENTITY_TYPES[domain] for domain in request.requested_domains)
        )
        canonical_rows = tuple(
            (
                await session.scalars(
                    select(CanonicalEntityRecord)
                    .where(
                        CanonicalEntityRecord.entity_type.in_(requested_types),
                        CanonicalEntityRecord.tombstoned.is_(False),
                        CanonicalEntityRecord.updated_at <= request.as_of,
                    )
                    .order_by(
                        CanonicalEntityRecord.entity_type,
                        CanonicalEntityRecord.entity_id,
                    )
                )
            ).all()
        )
        rows = tuple(
            ContextSourceRow(
                entity_type=row.entity_type,
                entity_id=row.entity_id,
                canonical_revision=row.canonical_revision,
                updated_at=row.updated_at,
                content_hash=row.content_hash,
                document=cast(dict[str, object], row.document),
            )
            for row in canonical_rows
            if row.entity_type not in _ACCEPTED_LIFE_ENTITY_TYPES
        )
        if ContextDomain.SEASON in request.requested_domains:
            accepted_life = await LifeModelService.current_records(
                session,
                owner_id=owner_id,
                as_of=request.as_of,
            )
            rows += tuple(
                ContextSourceRow(
                    entity_type=_LIFE_ENTITY_TYPE[kind],
                    entity_id=record.id,
                    canonical_revision=record.version_number,
                    updated_at=record.accepted_at,
                    content_hash=record.content_hash,
                    document=cast(dict[str, object], record.document),
                )
                for kind, record in sorted(accepted_life.items(), key=lambda item: item[0].value)
            )
        permission_rows = tuple(
            (
                await session.scalars(
                    select(CanonicalEntityRecord).where(
                        CanonicalEntityRecord.entity_type.in_(
                            ("permission", "integration_permission")
                        ),
                        CanonicalEntityRecord.tombstoned.is_(False),
                    )
                )
            ).all()
        )
        denied_domains: set[ContextDomain] = set()
        for row in permission_rows:
            domain = _context_domain(row.document.get("domain"))
            status = str(row.document.get("status", "")).casefold()
            if domain is not None and status in _DENIED_PERMISSION_STATES:
                denied_domains.add(domain)

        domain_snapshots = tuple(
            self._assemble_domain(
                domain=domain,
                rows=rows,
                denied=domain in denied_domains,
                as_of=request.as_of,
                client_freshness=request.client_known_freshness.get(domain),
            )
            for domain in request.requested_domains
        )
        source_fact_ids = tuple(
            dict.fromkeys(
                fact.entity_id
                for domain_snapshot in domain_snapshots
                for fact in domain_snapshot.facts
            )
        )
        snapshot_id = new_uuid7()
        snapshot_content = {
            "id": str(snapshot_id),
            "as_of": request.as_of.isoformat(),
            "built_at": built_at.isoformat(),
            "horizon": request.horizon,
            "purpose": request.purpose,
            "domains": [domain.model_dump(mode="json") for domain in domain_snapshots],
            "source_fact_ids": [str(fact_id) for fact_id in source_fact_ids],
            "builder_version": CONTEXT_BUILDER_VERSION,
        }
        content_hash = sha256(
            json.dumps(snapshot_content, separators=(",", ":"), sort_keys=True).encode()
        ).hexdigest()
        snapshot = AssembledContextSnapshot(
            id=snapshot_id,
            as_of=request.as_of,
            built_at=built_at,
            horizon=request.horizon,
            purpose=request.purpose,
            domains=domain_snapshots,
            source_fact_ids=source_fact_ids,
            builder_version=CONTEXT_BUILDER_VERSION,
            content_hash=content_hash,
        )
        response = ContextAssemblyResponse(
            snapshot=snapshot,
            missing_domains=tuple(
                item.domain
                for item in domain_snapshots
                if item.status is ContextDomainStatus.MISSING
            ),
            denied_domains=tuple(
                item.domain
                for item in domain_snapshots
                if item.status is ContextDomainStatus.DENIED
            ),
            stale_domains=tuple(
                item.domain for item in domain_snapshots if item.status is ContextDomainStatus.STALE
            ),
        )
        session.add(
            ContextSnapshotRecord(
                id=snapshot.id,
                owner_id=owner_id,
                as_of=snapshot.as_of,
                built_at=snapshot.built_at,
                horizon=snapshot.horizon,
                purpose=snapshot.purpose,
                builder_version=snapshot.builder_version,
                content_hash=snapshot.content_hash,
                document=response.model_dump(mode="json"),
            )
        )
        await session.flush()
        return response

    @staticmethod
    def _assemble_domain(
        *,
        domain: ContextDomain,
        rows: tuple[ContextSourceRow, ...],
        denied: bool,
        as_of: datetime,
        client_freshness: datetime | None,
    ) -> ContextDomainSnapshot:
        if denied:
            return ContextDomainSnapshot(
                domain=domain,
                status=ContextDomainStatus.DENIED,
                facts=(),
                reason_codes=(ContextReason.PERMISSION_DENIED,),
            )
        domain_rows = tuple(row for row in rows if row.entity_type in _DOMAIN_ENTITY_TYPES[domain])
        if not domain_rows:
            return ContextDomainSnapshot(
                domain=domain,
                status=ContextDomainStatus.MISSING,
                facts=(),
                reason_codes=(ContextReason.SOURCE_MISSING,),
            )
        facts = tuple(
            ContextFact(
                entity_type=row.entity_type,
                entity_id=row.entity_id,
                canonical_revision=row.canonical_revision,
                updated_at=_aware(row.updated_at),
                content_hash=row.content_hash,
                document=row.document,
            )
            for row in domain_rows
        )
        freshest = max(fact.updated_at for fact in facts)
        reasons = [ContextReason.SOURCE_AVAILABLE]
        limit = _FRESHNESS_LIMITS[domain]
        stale = limit is not None and as_of - freshest > limit
        if stale:
            reasons.append(ContextReason.SOURCE_STALE)
        if client_freshness is not None and client_freshness > freshest:
            stale = True
            reasons.append(ContextReason.SERVER_OLDER_THAN_CLIENT)
        return ContextDomainSnapshot(
            domain=domain,
            status=ContextDomainStatus.STALE if stale else ContextDomainStatus.FRESH,
            facts=facts,
            freshest_source_at=freshest,
            reason_codes=tuple(reasons),
        )


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def _context_domain(value: object) -> ContextDomain | None:
    try:
        return ContextDomain(str(value))
    except ValueError:
        return None
