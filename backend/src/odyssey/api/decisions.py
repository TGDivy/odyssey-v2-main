"""Owner-only deterministic decision preparation API."""

from datetime import UTC, datetime

from fastapi import APIRouter

from odyssey.api.auth import OwnerDependency
from odyssey.api.dependencies import SessionDependency
from odyssey.api.errors import OdysseyError
from odyssey.decision.preparation import (
    DecisionPreparationError,
    DecisionPreparationRequest,
    DecisionPreparationResponse,
    DecisionPreparationService,
)

router = APIRouter(prefix="/v1/decisions", tags=["decisions"])
service = DecisionPreparationService()


@router.post("/prepare", response_model=DecisionPreparationResponse)
async def prepare_decision(
    body: DecisionPreparationRequest,
    session: SessionDependency,
    owner: OwnerDependency,
) -> DecisionPreparationResponse:
    try:
        async with session.begin():
            return await service.prepare(
                session,
                owner_id=owner.owner_id,
                request=body,
                now=datetime.now(UTC),
            )
    except DecisionPreparationError as error:
        raise OdysseyError(
            code=error.code,
            message=str(error),
            status_code=error.status_code,
        ) from error
