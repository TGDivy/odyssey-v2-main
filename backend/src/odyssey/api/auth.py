"""Owner authentication boundary with credential-free development mode."""

from typing import Annotated

from fastapi import Depends, Header

from odyssey.api.errors import OdysseyError
from odyssey.config import AuthMode, Settings, get_settings
from odyssey.domain.common import StrictModel


class OwnerPrincipal(StrictModel):
    owner_id: str
    authentication_method: str


async def require_owner(
    settings: Annotated[Settings, Depends(get_settings)],
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
) -> OwnerPrincipal:
    if settings.auth_mode is AuthMode.DEVELOPMENT:
        if authorization not in {None, "Bearer development-owner"}:
            raise OdysseyError(
                code="AUTHENTICATION_FAILED",
                message="The development owner credential is invalid.",
                status_code=401,
            )
        return OwnerPrincipal(
            owner_id="development-owner",
            authentication_method="development_stub",
        )
    raise OdysseyError(
        code="AUTH_VERIFIER_NOT_CONFIGURED",
        message="Production owner-token verification is not configured.",
        status_code=503,
        retryable=False,
    )


OwnerDependency = Annotated[OwnerPrincipal, Depends(require_owner)]
