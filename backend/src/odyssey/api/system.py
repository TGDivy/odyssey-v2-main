"""Health and nonsecret environment diagnostics endpoints."""

from datetime import UTC, datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from odyssey import __version__
from odyssey.config import Settings, get_settings

router = APIRouter(tags=["system"])
SettingsDependency = Annotated[Settings, Depends(get_settings)]


class LiveResponse(BaseModel):
    status: Literal["ok"] = "ok"


class ReadyResponse(BaseModel):
    status: Literal["ready"] = "ready"
    checked_at: datetime


class DiagnosticsResponse(BaseModel):
    service: str
    version: str
    configuration: dict[str, str | bool | int]
    capabilities: dict[str, bool]


@router.get("/health/live", response_model=LiveResponse)
async def live() -> LiveResponse:
    return LiveResponse()


@router.get("/health/ready", response_model=ReadyResponse)
async def ready() -> ReadyResponse:
    return ReadyResponse(checked_at=datetime.now(UTC))


@router.get("/v1/admin/diagnostics", response_model=DiagnosticsResponse)
async def diagnostics(settings: SettingsDependency) -> DiagnosticsResponse:
    return DiagnosticsResponse(
        service="odyssey-api",
        version=__version__,
        configuration=settings.safe_diagnostics(),
        capabilities={
            "database": False,
            "object_storage": False,
            "queue": False,
            "cloud_model": settings.model_provider != "deterministic",
            "proactive_delivery": settings.proactive_enabled,
        },
    )
