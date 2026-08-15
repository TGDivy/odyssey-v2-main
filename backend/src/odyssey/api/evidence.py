"""Owner-only deterministic evidence query API."""

from datetime import UTC, datetime

from fastapi import APIRouter

from odyssey.api.auth import OwnerDependency
from odyssey.api.dependencies import SessionDependency
from odyssey.evidence.query import EvidenceQueryRequest, EvidenceQueryResponse, EvidenceQueryService

router = APIRouter(prefix="/v1/evidence", tags=["evidence"])
service = EvidenceQueryService()


@router.post("/query", response_model=EvidenceQueryResponse)
async def query_evidence(
    body: EvidenceQueryRequest,
    session: SessionDependency,
    owner: OwnerDependency,
) -> EvidenceQueryResponse:
    async with session.begin():
        return await service.query(
            session,
            owner_id=owner.owner_id,
            request=body,
            now=datetime.now(UTC),
        )
