"""Owner-only recommendation feedback and correction API."""

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Header

from odyssey.api.auth import OwnerDependency
from odyssey.api.dependencies import SessionDependency
from odyssey.api.errors import OdysseyError
from odyssey.decision.feedback import (
    RecommendationFeedbackError,
    RecommendationFeedbackRequest,
    RecommendationFeedbackResponse,
    RecommendationFeedbackService,
)
from odyssey.domain.common import UUID7

router = APIRouter(prefix="/v1/recommendations", tags=["recommendations"])
service = RecommendationFeedbackService()


@router.post(
    "/{recommendation_id}/feedback",
    response_model=RecommendationFeedbackResponse,
)
async def record_recommendation_feedback(
    recommendation_id: UUID7,
    body: RecommendationFeedbackRequest,
    session: SessionDependency,
    owner: OwnerDependency,
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=500)],
) -> RecommendationFeedbackResponse:
    try:
        async with session.begin():
            return await service.record(
                session,
                owner_id=owner.owner_id,
                recommendation_id=recommendation_id,
                request=body,
                idempotency_key=idempotency_key,
                now=datetime.now(UTC),
            )
    except RecommendationFeedbackError as error:
        raise OdysseyError(
            code=error.code,
            message=str(error),
            status_code=error.status_code,
        ) from error
