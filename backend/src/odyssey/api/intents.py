"""Owner-only intent opportunity policy API."""

from datetime import UTC, datetime

from fastapi import APIRouter

from odyssey.api.auth import OwnerDependency
from odyssey.api.dependencies import SessionDependency
from odyssey.api.errors import OdysseyError
from odyssey.intent.evaluation import (
    InterventionEvaluationError,
    InterventionEvaluationRequest,
    InterventionEvaluationResponse,
    InterventionEvaluationService,
)

router = APIRouter(prefix="/v1/intents", tags=["intents"])
service = InterventionEvaluationService()


@router.post("/opportunities/evaluate", response_model=InterventionEvaluationResponse)
async def evaluate_opportunity(
    body: InterventionEvaluationRequest,
    session: SessionDependency,
    owner: OwnerDependency,
) -> InterventionEvaluationResponse:
    try:
        async with session.begin():
            return await service.evaluate(
                session,
                owner_id=owner.owner_id,
                request=body,
                now=datetime.now(UTC),
            )
    except InterventionEvaluationError as error:
        raise OdysseyError(
            code=error.code,
            message=str(error),
            status_code=error.status_code,
        ) from error
