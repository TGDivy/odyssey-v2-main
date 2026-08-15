"""Deliberate, immutable owner acceptance for Charter, life stage, and season."""

import json
from datetime import UTC, datetime
from hashlib import sha256
from typing import cast
from uuid import UUID

from pydantic import JsonValue, TypeAdapter
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.db.models import LedgerEventRecord
from odyssey.db.repositories import (
    LedgerRepository,
    ProvenanceConflictError,
    SourceRecordConflictError,
    SourceRecordWrite,
)
from odyssey.domain.common import UUID7, ActorType, Provenance
from odyssey.domain.events import DomainEvent
from odyssey.domain.life import (
    CharterVersion,
    LifeStageVersion,
    Season,
    SeasonStatus,
)
from odyssey.life.contracts import (
    AcceptanceMethod,
    CharterRevisionRequest,
    CurrentOrientationResponse,
    LifeModelHistoryResponse,
    LifeModelKind,
    LifeModelRevisionReceipt,
    LifeModelVersionEnvelope,
    LifeStageRevisionRequest,
    SeasonRevisionRequest,
)
from odyssey.life.persistence import LifeModelVersionRecord

LIFE_MODEL_POLICY_VERSION = "life-model-acceptance-policy-1.0"
_UUID7_ADAPTER = TypeAdapter(UUID7)
_TERMINAL_SEASON_STATUSES = {SeasonStatus.COMPLETE, SeasonStatus.ABANDONED}
_SEASON_TRANSITIONS = {
    SeasonStatus.DRAFT: {
        SeasonStatus.DRAFT,
        SeasonStatus.CALIBRATION,
        SeasonStatus.ACTIVE,
        SeasonStatus.ABANDONED,
    },
    SeasonStatus.CALIBRATION: {
        SeasonStatus.CALIBRATION,
        SeasonStatus.ACTIVE,
        SeasonStatus.ABANDONED,
    },
    SeasonStatus.ACTIVE: {
        SeasonStatus.ACTIVE,
        SeasonStatus.TRANSITIONING,
        SeasonStatus.ABANDONED,
    },
    SeasonStatus.TRANSITIONING: {
        SeasonStatus.TRANSITIONING,
        SeasonStatus.COMPLETE,
        SeasonStatus.ACTIVE,
    },
    SeasonStatus.COMPLETE: set(),
    SeasonStatus.ABANDONED: set(),
}


class LifeModelServiceError(RuntimeError):
    def __init__(self, code: str, message: str, *, status_code: int) -> None:
        super().__init__(message)
        self.code = code
        self.status_code = status_code


class LifeModelService:
    def __init__(self, repository: LedgerRepository | None = None) -> None:
        self.repository = repository or LedgerRepository()

    async def accept_charter(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        request: CharterRevisionRequest,
        correlation_id: UUID,
        recorded_at: datetime | None = None,
    ) -> LifeModelRevisionReceipt:
        charter = request.charter
        self._validate_metadata(
            charter.metadata,
            owner_id=owner_id,
            accepted_at=charter.accepted_at,
        )
        if not charter.values:
            self._invalid(
                "CHARTER_VALUES_REQUIRED", "An accepted Charter needs at least one value."
            )
        if not charter.anti_optimization_statements:
            self._invalid(
                "CHARTER_BOUNDARY_REQUIRED",
                "An accepted Charter needs at least one anti-optimization statement.",
            )
        if charter.version_number != charter.metadata.revision:
            self._invalid(
                "CHARTER_VERSION_MISMATCH",
                "Charter version_number must equal metadata revision.",
            )
        return await self._accept(
            session,
            owner_id=owner_id,
            kind=LifeModelKind.CHARTER,
            logical_id=charter.charter_id,
            document=charter,
            event_id=request.event_id,
            expected_current_version_id=request.expected_current_version_id,
            acceptance_method=request.acceptance_method,
            accepted_at=charter.accepted_at,
            device_id=request.device_id,
            correlation_id=correlation_id,
            recorded_at=recorded_at,
            embedded_supersedes=charter.supersedes_version_id,
        )

    async def accept_life_stage(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        request: LifeStageRevisionRequest,
        correlation_id: UUID,
        recorded_at: datetime | None = None,
    ) -> LifeModelRevisionReceipt:
        self._validate_metadata(
            request.life_stage.metadata,
            owner_id=owner_id,
            accepted_at=request.accepted_at,
        )
        return await self._accept(
            session,
            owner_id=owner_id,
            kind=LifeModelKind.LIFE_STAGE,
            logical_id=request.life_stage.stage_id,
            document=request.life_stage,
            event_id=request.event_id,
            expected_current_version_id=request.expected_current_version_id,
            acceptance_method=request.acceptance_method,
            accepted_at=request.accepted_at,
            device_id=request.device_id,
            correlation_id=correlation_id,
            recorded_at=recorded_at,
        )

    async def accept_season(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        request: SeasonRevisionRequest,
        correlation_id: UUID,
        recorded_at: datetime | None = None,
    ) -> LifeModelRevisionReceipt:
        self._validate_metadata(
            request.season.metadata,
            owner_id=owner_id,
            accepted_at=request.accepted_at,
        )
        charter_record = await self._current_for_update(
            session,
            owner_id=owner_id,
            kind=LifeModelKind.CHARTER,
        )
        if charter_record is None or charter_record.id != request.season.charter_revision_id:
            raise LifeModelServiceError(
                "CHARTER_REVISION_NOT_ACCEPTED",
                "A season must reference the currently accepted owner Charter revision.",
                status_code=409,
            )
        warnings = self._season_warnings(request.season)
        return await self._accept(
            session,
            owner_id=owner_id,
            kind=LifeModelKind.SEASON,
            logical_id=request.season_id,
            document=request.season,
            event_id=request.event_id,
            expected_current_version_id=request.expected_current_version_id,
            acceptance_method=request.acceptance_method,
            accepted_at=request.accepted_at,
            device_id=request.device_id,
            correlation_id=correlation_id,
            recorded_at=recorded_at,
            warnings=warnings,
        )

    async def current_orientation(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        as_of: datetime | None = None,
    ) -> CurrentOrientationResponse:
        current_as_of = as_of or datetime.now(UTC)
        records = await self.current_records(session, owner_id=owner_id, as_of=current_as_of)
        return CurrentOrientationResponse(
            as_of=current_as_of,
            charter=self._envelope(records.get(LifeModelKind.CHARTER)),
            life_stage=self._envelope(records.get(LifeModelKind.LIFE_STAGE)),
            season=self._envelope(records.get(LifeModelKind.SEASON)),
            policy_version=LIFE_MODEL_POLICY_VERSION,
        )

    async def history(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        kind: LifeModelKind,
        limit: int,
    ) -> LifeModelHistoryResponse:
        records = tuple(
            (
                await session.scalars(
                    select(LifeModelVersionRecord)
                    .where(
                        LifeModelVersionRecord.owner_id == owner_id,
                        LifeModelVersionRecord.kind == kind,
                    )
                    .order_by(LifeModelVersionRecord.acceptance_sequence.desc())
                    .limit(limit)
                )
            ).all()
        )
        return LifeModelHistoryResponse(
            kind=kind,
            versions=tuple(self._envelope(record) for record in records if record is not None),
            policy_version=LIFE_MODEL_POLICY_VERSION,
        )

    @staticmethod
    async def current_records(
        session: AsyncSession,
        *,
        owner_id: str,
        as_of: datetime,
    ) -> dict[LifeModelKind, LifeModelVersionRecord]:
        records = tuple(
            (
                await session.scalars(
                    select(LifeModelVersionRecord)
                    .where(
                        LifeModelVersionRecord.owner_id == owner_id,
                        LifeModelVersionRecord.accepted_at <= as_of,
                    )
                    .order_by(
                        LifeModelVersionRecord.kind,
                        LifeModelVersionRecord.acceptance_sequence.desc(),
                    )
                )
            ).all()
        )
        current: dict[LifeModelKind, LifeModelVersionRecord] = {}
        for record in records:
            current.setdefault(LifeModelKind(record.kind), record)
        return current

    async def _accept(
        self,
        session: AsyncSession,
        *,
        owner_id: str,
        kind: LifeModelKind,
        logical_id: UUID,
        document: CharterVersion | LifeStageVersion | Season,
        event_id: UUID,
        expected_current_version_id: UUID | None,
        acceptance_method: AcceptanceMethod,
        accepted_at: datetime,
        device_id: UUID,
        correlation_id: UUID,
        recorded_at: datetime | None,
        embedded_supersedes: UUID | None = None,
        warnings: tuple[str, ...] = (),
    ) -> LifeModelRevisionReceipt:
        document_json = cast(dict[str, JsonValue], document.model_dump(mode="json"))
        content_hash = self._content_hash(document_json)
        existing = await session.scalar(
            select(LifeModelVersionRecord).where(LifeModelVersionRecord.event_id == event_id)
        )
        if existing is not None:
            if (
                existing.owner_id != owner_id
                or existing.kind != kind
                or existing.logical_id != logical_id
                or existing.content_hash != content_hash
                or existing.acceptance_method != acceptance_method.value
                or _aware(existing.accepted_at) != _aware(accepted_at)
            ):
                raise LifeModelServiceError(
                    "LIFE_MODEL_EVENT_ID_REUSED",
                    "The event ID was already used for a different life-model command.",
                    status_code=409,
                )
            return self._receipt(existing, created=False, warnings=warnings)
        existing_ledger_event = await session.scalar(
            select(LedgerEventRecord.event_id).where(LedgerEventRecord.event_id == event_id)
        )
        if existing_ledger_event is not None:
            raise LifeModelServiceError(
                "LIFE_MODEL_EVENT_ID_REUSED",
                "The event ID was already used by another durable event.",
                status_code=409,
            )

        current = await self._current_for_update(session, owner_id=owner_id, kind=kind)
        self._validate_expected_current(current, expected_current_version_id)
        if current is not None and _aware(accepted_at) < _aware(current.accepted_at):
            self._invalid(
                "LIFE_MODEL_ACCEPTANCE_OUT_OF_ORDER",
                "A new accepted version cannot precede the version it supersedes.",
            )
        if (
            kind is LifeModelKind.CHARTER
            and current is not None
            and current.logical_id != logical_id
        ):
            self._invalid(
                "CHARTER_ID_CHANGED",
                "A Charter revision must preserve the accepted Charter identity.",
            )
        if kind is LifeModelKind.CHARTER and embedded_supersedes != (
            current.id if current is not None else None
        ):
            self._invalid(
                "LIFE_MODEL_SUPERSESSION_MISMATCH",
                "The embedded supersedes_version_id must match the accepted current version.",
            )

        latest_logical = await session.scalar(
            select(LifeModelVersionRecord)
            .where(
                LifeModelVersionRecord.owner_id == owner_id,
                LifeModelVersionRecord.kind == kind,
                LifeModelVersionRecord.logical_id == logical_id,
            )
            .order_by(LifeModelVersionRecord.version_number.desc())
            .limit(1)
            .with_for_update()
        )
        version_number = 1 if latest_logical is None else latest_logical.version_number + 1
        acceptance_sequence = 1 if current is None else current.acceptance_sequence + 1
        self._validate_revision_metadata(document, latest_logical, version_number)
        if kind is LifeModelKind.SEASON:
            self._validate_season_transition(
                cast(Season, document),
                logical_id=logical_id,
                current=current,
            )

        event_type, payload = self._event_details(
            kind=kind,
            logical_id=logical_id,
            document=document,
            current=current,
        )
        now = recorded_at or datetime.now(UTC)
        provenance_id = _UUID7_ADAPTER.validate_python(document.metadata.provenance_id)
        provenance = Provenance(
            id=provenance_id,
            source_kind=f"owner_accepted_{kind.value}",
            source_id=str(document.metadata.id),
            captured_at=accepted_at,
            actor=document.metadata.created_by,
            transformation_chain=(LIFE_MODEL_POLICY_VERSION,),
            content_hash=content_hash,
            details={
                "acceptance_method": acceptance_method.value,
                "device_id": str(device_id),
                "contains_real_personal_data": True,
            },
        )
        event = DomainEvent(
            event_id=event_id,
            event_type=event_type,
            event_schema_version=1,
            aggregate_type=kind.value,
            aggregate_id=_UUID7_ADAPTER.validate_python(logical_id),
            occurred_at=accepted_at,
            recorded_at=now,
            actor=document.metadata.created_by,
            correlation_id=correlation_id,
            payload=payload,
            provenance=provenance,
        )
        source = SourceRecordWrite(
            id=document.metadata.id,
            source_kind=f"accepted_{kind.value}_version",
            occurred_at=accepted_at,
            recorded_at=now,
            temporal_precision="exact",
            content_hash=content_hash,
            sensitivity=document.metadata.sensitivity.value,
            payload={
                "document": document_json,
                "acceptance_method": acceptance_method.value,
            },
            provenance_id=provenance.id,
            timezone_id=document.effective_interval.timezone_id,
        )
        try:
            append_result = await self.repository.append_source_event(
                session,
                source=source,
                event=event,
            )
            if not append_result.created:
                raise LifeModelServiceError(
                    "LIFE_MODEL_CONCURRENT_ACCEPTANCE",
                    "The event was accepted concurrently; reload before retrying.",
                    status_code=409,
                )
            record = LifeModelVersionRecord(
                id=document.metadata.id,
                owner_id=owner_id,
                kind=kind.value,
                logical_id=logical_id,
                version_number=version_number,
                acceptance_sequence=acceptance_sequence,
                supersedes_version_id=current.id if current is not None else None,
                status=document.status.value if isinstance(document, Season) else None,
                acceptance_method=acceptance_method.value,
                accepted_at=accepted_at,
                content_hash=content_hash,
                document=document_json,
                event_id=event_id,
                event_type=event_type,
                ledger_sequence=append_result.sequence,
                created_at=now,
            )
            session.add(record)
            await session.flush()
        except (ProvenanceConflictError, SourceRecordConflictError) as error:
            raise LifeModelServiceError(
                "LIFE_MODEL_IDENTIFIER_REUSED",
                "A version or provenance ID was already used for different immutable content.",
                status_code=409,
            ) from error
        except IntegrityError as error:
            raise LifeModelServiceError(
                "LIFE_MODEL_CONCURRENT_ACCEPTANCE",
                "Another life-model version was accepted concurrently; reload before retrying.",
                status_code=409,
            ) from error
        return self._receipt(record, created=True, warnings=warnings)

    @staticmethod
    def _validate_metadata(metadata: object, *, owner_id: str, accepted_at: datetime) -> None:
        from odyssey.domain.common import EntityMetadata

        typed_metadata = cast(EntityMetadata, metadata)
        if (
            typed_metadata.created_by.actor_type is not ActorType.USER
            or typed_metadata.created_by.actor_id != owner_id
        ):
            raise LifeModelServiceError(
                "OWNER_ACCEPTANCE_REQUIRED",
                "Accepted life-model state must be explicitly authored or reviewed by the owner.",
                status_code=403,
            )
        if typed_metadata.tombstoned_at is not None:
            LifeModelService._invalid(
                "TOMBSTONED_VERSION_NOT_ACCEPTABLE",
                "A tombstoned life-model version cannot become current.",
            )
        if accepted_at < typed_metadata.last_revised_at:
            LifeModelService._invalid(
                "ACCEPTANCE_PRECEDES_REVISION",
                "Acceptance cannot precede the document revision time.",
            )
        try:
            _UUID7_ADAPTER.validate_python(typed_metadata.provenance_id)
        except ValueError as error:
            raise LifeModelServiceError(
                "PROVENANCE_ID_INVALID",
                "Accepted life-model metadata must reference a UUIDv7 provenance record.",
                status_code=400,
            ) from error

    @staticmethod
    def _validate_revision_metadata(
        document: CharterVersion | LifeStageVersion | Season,
        latest_logical: LifeModelVersionRecord | None,
        version_number: int,
    ) -> None:
        if document.metadata.revision != version_number:
            LifeModelService._invalid(
                "LIFE_MODEL_REVISION_MISMATCH",
                "Metadata revision must increase exactly once for each accepted logical version.",
            )
        if latest_logical is not None:
            previous = latest_logical.document.get("metadata")
            previous_created_at = previous.get("created_at") if isinstance(previous, dict) else None
            current_created_at = document.metadata.model_dump(mode="json")["created_at"]
            if previous_created_at != current_created_at:
                LifeModelService._invalid(
                    "LIFE_MODEL_CREATED_AT_CHANGED",
                    "A logical entity revision must preserve its original created_at.",
                )

    @staticmethod
    def _validate_expected_current(
        current: LifeModelVersionRecord | None,
        expected_current_version_id: UUID | None,
    ) -> None:
        actual = current.id if current is not None else None
        if expected_current_version_id != actual:
            raise LifeModelServiceError(
                "LIFE_MODEL_CURRENT_VERSION_CONFLICT",
                "The accepted current version changed; review it before creating another revision.",
                status_code=409,
            )

    @staticmethod
    def _validate_season_transition(
        season: Season,
        *,
        logical_id: UUID,
        current: LifeModelVersionRecord | None,
    ) -> None:
        if current is None:
            if season.supersedes_season_id is not None:
                LifeModelService._invalid(
                    "SEASON_SUPERSESSION_MISMATCH",
                    "The first accepted season cannot supersede an unknown season.",
                )
            if season.status in _TERMINAL_SEASON_STATUSES | {SeasonStatus.TRANSITIONING}:
                LifeModelService._invalid(
                    "SEASON_INITIAL_STATUS_INVALID",
                    "A first accepted season must start as draft, calibration, or active.",
                )
            return

        if current.status is None:
            raise RuntimeError("accepted season record is missing status")
        previous_status = SeasonStatus(current.status)
        if current.logical_id == logical_id:
            previous_document = Season.model_validate(current.document)
            if season.supersedes_season_id != previous_document.supersedes_season_id:
                LifeModelService._invalid(
                    "SEASON_SUPERSESSION_CHANGED",
                    "A season revision cannot rewrite which prior season it superseded.",
                )
            if season.status not in _SEASON_TRANSITIONS[previous_status]:
                LifeModelService._invalid(
                    "SEASON_TRANSITION_INVALID",
                    f"Season status cannot transition from {previous_status} to {season.status}.",
                )
            return

        if previous_status not in _TERMINAL_SEASON_STATUSES:
            LifeModelService._invalid(
                "SEASON_SUCCESSOR_PREMATURE",
                "A successor can become accepted only after the current season is terminal.",
            )
        if season.supersedes_season_id != current.logical_id:
            LifeModelService._invalid(
                "SEASON_SUPERSESSION_MISMATCH",
                "A new season must explicitly supersede the currently accepted season.",
            )
        if season.status in _TERMINAL_SEASON_STATUSES | {SeasonStatus.TRANSITIONING}:
            LifeModelService._invalid(
                "SEASON_SUCCESSOR_STATUS_INVALID",
                "A successor season must begin as draft, calibration, or active.",
            )

    @staticmethod
    def _season_warnings(season: Season) -> tuple[str, ...]:
        warnings: list[str] = []
        primary_count = sum(item.role.value == "primary" for item in season.portfolio_items)
        foundation_count = sum(item.role.value == "foundation" for item in season.portfolio_items)
        supporting_count = sum(
            item.role.value in {"maintenance", "exploration"} for item in season.portfolio_items
        )
        if primary_count != 1:
            warnings.append("ATYPICAL_PRIMARY_DIRECTION_COUNT")
        if supporting_count > 2:
            warnings.append("SUPPORTING_DIRECTION_SOFT_LIMIT_EXCEEDED")
        if foundation_count > 5:
            warnings.append("FOUNDATION_SOFT_LIMIT_EXCEEDED")
        return tuple(warnings)

    @staticmethod
    def _event_details(
        *,
        kind: LifeModelKind,
        logical_id: UUID,
        document: CharterVersion | LifeStageVersion | Season,
        current: LifeModelVersionRecord | None,
    ) -> tuple[str, dict[str, str]]:
        if kind is LifeModelKind.CHARTER:
            payload = {"charter_version_id": str(document.metadata.id)}
            if current is not None:
                payload["supersedes_version_id"] = str(current.id)
            return "charter.revised.v1", payload
        if kind is LifeModelKind.LIFE_STAGE:
            payload = {"life_stage_version_id": str(document.metadata.id)}
            if current is not None:
                payload["supersedes_version_id"] = str(current.id)
            return "life_stage.revised.v1", payload

        season = cast(Season, document)
        if current is not None and current.logical_id != logical_id:
            return "season.transitioned.v1", {
                "from_season_id": str(current.logical_id),
                "to_season_id": str(logical_id),
            }
        if season.status is SeasonStatus.ACTIVE and (
            current is None or current.status != SeasonStatus.ACTIVE.value
        ):
            return "season.activated.v1", {"season_id": str(logical_id)}
        payload = {
            "season_version_id": str(season.metadata.id),
            "season_id": str(logical_id),
            "new_status": season.status.value,
        }
        if current is not None:
            payload["supersedes_version_id"] = str(current.id)
            payload["previous_status"] = str(current.status)
        return "season.revised.v1", payload

    @staticmethod
    async def _current_for_update(
        session: AsyncSession,
        *,
        owner_id: str,
        kind: LifeModelKind,
    ) -> LifeModelVersionRecord | None:
        return cast(
            LifeModelVersionRecord | None,
            await session.scalar(
                select(LifeModelVersionRecord)
                .where(
                    LifeModelVersionRecord.owner_id == owner_id,
                    LifeModelVersionRecord.kind == kind,
                )
                .order_by(LifeModelVersionRecord.acceptance_sequence.desc())
                .limit(1)
                .with_for_update()
            ),
        )

    @staticmethod
    def _content_hash(document: dict[str, JsonValue]) -> str:
        canonical = json.dumps(document, separators=(",", ":"), sort_keys=True).encode()
        return sha256(canonical).hexdigest()

    @staticmethod
    def _receipt(
        record: LifeModelVersionRecord,
        *,
        created: bool,
        warnings: tuple[str, ...],
    ) -> LifeModelRevisionReceipt:
        return LifeModelRevisionReceipt(
            version=LifeModelService._envelope(record),
            event_id=record.event_id,
            ledger_sequence=record.ledger_sequence,
            created=created,
            warnings=warnings,
            policy_version=LIFE_MODEL_POLICY_VERSION,
        )

    @staticmethod
    def _envelope(record: LifeModelVersionRecord | None) -> LifeModelVersionEnvelope | None:
        if record is None:
            return None
        return LifeModelVersionEnvelope(
            kind=LifeModelKind(record.kind),
            version_id=_UUID7_ADAPTER.validate_python(record.id),
            logical_id=_UUID7_ADAPTER.validate_python(record.logical_id),
            version_number=record.version_number,
            acceptance_sequence=record.acceptance_sequence,
            supersedes_version_id=(
                _UUID7_ADAPTER.validate_python(record.supersedes_version_id)
                if record.supersedes_version_id is not None
                else None
            ),
            status=record.status,
            acceptance_method=AcceptanceMethod(record.acceptance_method),
            accepted_at=_aware(record.accepted_at),
            content_hash=record.content_hash,
            document=cast(dict[str, JsonValue], record.document),
        )

    @staticmethod
    def _invalid(code: str, message: str) -> None:
        raise LifeModelServiceError(code, message, status_code=400)


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
