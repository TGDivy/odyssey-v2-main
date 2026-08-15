"""Owner-only deliberate Charter, life-stage, and season acceptance API."""

from datetime import UTC, datetime
from typing import Annotated
from uuid import NAMESPACE_URL, UUID, uuid5

from fastapi import APIRouter, Query, Request
from pydantic import AwareDatetime

from odyssey.api.auth import OwnerDependency, require_matching_device
from odyssey.api.dependencies import SessionDependency
from odyssey.api.errors import OdysseyError
from odyssey.life.contracts import (
    CharterRevisionRequest,
    CurrentOrientationResponse,
    LifeModelHistoryResponse,
    LifeModelKind,
    LifeModelRevisionReceipt,
    LifeStageRevisionRequest,
    SeasonRevisionRequest,
)
from odyssey.life.service import LifeModelService, LifeModelServiceError

router = APIRouter(prefix="/v1/seasons", tags=["seasons"])
service = LifeModelService()


def correlation_uuid(value: str) -> UUID:
    try:
        return UUID(value)
    except ValueError:
        return uuid5(NAMESPACE_URL, value)


def life_model_error(error: LifeModelServiceError) -> OdysseyError:
    return OdysseyError(
        code=error.code,
        message=str(error),
        status_code=error.status_code,
    )


@router.post("/charter/revisions", response_model=LifeModelRevisionReceipt)
async def accept_charter_revision(
    body: CharterRevisionRequest,
    request: Request,
    session: SessionDependency,
    owner: OwnerDependency,
) -> LifeModelRevisionReceipt:
    require_matching_device(owner, body.device_id)
    try:
        async with session.begin():
            return await service.accept_charter(
                session,
                owner_id=owner.owner_id,
                request=body,
                correlation_id=correlation_uuid(request.state.correlation_id),
                recorded_at=datetime.now(UTC),
            )
    except LifeModelServiceError as error:
        raise life_model_error(error) from error


@router.post("/life-stage/revisions", response_model=LifeModelRevisionReceipt)
async def accept_life_stage_revision(
    body: LifeStageRevisionRequest,
    request: Request,
    session: SessionDependency,
    owner: OwnerDependency,
) -> LifeModelRevisionReceipt:
    require_matching_device(owner, body.device_id)
    try:
        async with session.begin():
            return await service.accept_life_stage(
                session,
                owner_id=owner.owner_id,
                request=body,
                correlation_id=correlation_uuid(request.state.correlation_id),
                recorded_at=datetime.now(UTC),
            )
    except LifeModelServiceError as error:
        raise life_model_error(error) from error


@router.post("/revisions", response_model=LifeModelRevisionReceipt)
async def accept_season_revision(
    body: SeasonRevisionRequest,
    request: Request,
    session: SessionDependency,
    owner: OwnerDependency,
) -> LifeModelRevisionReceipt:
    require_matching_device(owner, body.device_id)
    try:
        async with session.begin():
            return await service.accept_season(
                session,
                owner_id=owner.owner_id,
                request=body,
                correlation_id=correlation_uuid(request.state.correlation_id),
                recorded_at=datetime.now(UTC),
            )
    except LifeModelServiceError as error:
        raise life_model_error(error) from error


@router.get("/orientation", response_model=CurrentOrientationResponse)
async def get_current_orientation(
    session: SessionDependency,
    owner: OwnerDependency,
    as_of: Annotated[AwareDatetime | None, Query()] = None,
) -> CurrentOrientationResponse:
    return await service.current_orientation(
        session,
        owner_id=owner.owner_id,
        as_of=as_of,
    )


@router.get("/history", response_model=LifeModelHistoryResponse)
async def get_life_model_history(
    kind: LifeModelKind,
    session: SessionDependency,
    owner: OwnerDependency,
    limit: Annotated[int, Query(ge=1, le=200)] = 100,
) -> LifeModelHistoryResponse:
    return await service.history(
        session,
        owner_id=owner.owner_id,
        kind=kind,
        limit=limit,
    )
