"""Owner-only deterministic context assembly API."""

from datetime import UTC, datetime

from fastapi import APIRouter

from odyssey.api.auth import OwnerDependency
from odyssey.api.dependencies import SessionDependency
from odyssey.api.errors import OdysseyError
from odyssey.context.contracts import ContextAssemblyRequest, ContextAssemblyResponse
from odyssey.context.service import ContextAssemblyError, ContextAssemblyService

router = APIRouter(prefix="/v1/context", tags=["context"])
service = ContextAssemblyService()


@router.post("/assemble", response_model=ContextAssemblyResponse)
async def assemble_context(
    body: ContextAssemblyRequest,
    session: SessionDependency,
    owner: OwnerDependency,
) -> ContextAssemblyResponse:
    try:
        async with session.begin():
            return await service.assemble(
                session,
                owner_id=owner.owner_id,
                request=body,
                now=datetime.now(UTC),
            )
    except ContextAssemblyError as error:
        raise OdysseyError(
            code=error.code,
            message=str(error),
            status_code=400,
        ) from error
