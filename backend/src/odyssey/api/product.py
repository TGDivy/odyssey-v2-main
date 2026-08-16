"""Owner-only signed feature configuration API."""

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Query

from odyssey.api.auth import OwnerDependency
from odyssey.api.dependencies import (
    FeatureConfigurationSignerDependency,
    SessionDependency,
)
from odyssey.api.errors import OdysseyError
from odyssey.config import Settings, get_settings
from odyssey.telemetry.feature_configuration_service import (
    FeatureConfigurationService,
    FeatureConfigurationServiceError,
)
from odyssey.telemetry.models import (
    FeatureConfigurationCreateRequest,
    FeatureConfigurationEnvelope,
    FeatureConfigurationPublication,
)

router = APIRouter(prefix="/v1/product", tags=["product"])
service = FeatureConfigurationService()
SettingsDependency = Annotated[Settings, Depends(get_settings)]


def feature_configuration_error(error: FeatureConfigurationServiceError) -> OdysseyError:
    return OdysseyError(
        code=error.code,
        message=str(error),
        status_code=error.status_code,
        retryable=error.retryable,
    )


@router.post(
    "/feature-configurations",
    response_model=FeatureConfigurationPublication,
)
async def publish_feature_configuration(
    body: FeatureConfigurationCreateRequest,
    session: SessionDependency,
    owner: OwnerDependency,
    signer: FeatureConfigurationSignerDependency,
    settings: SettingsDependency,
) -> FeatureConfigurationPublication:
    created_by = (
        str(owner.device_id) if owner.device_id is not None else owner.authentication_method
    )
    try:
        async with session.begin():
            return await service.publish(
                session,
                owner_id=owner.owner_id,
                environment=settings.env.value,
                request=body,
                signer=signer,
                created_by=created_by,
                now=datetime.now(UTC),
            )
    except FeatureConfigurationServiceError as error:
        raise feature_configuration_error(error) from error


@router.get(
    "/feature-configuration",
    response_model=FeatureConfigurationEnvelope,
)
async def get_feature_configuration(
    session: SessionDependency,
    owner: OwnerDependency,
    audience: Annotated[
        str,
        Query(min_length=3, max_length=255, pattern=r"^[A-Za-z0-9][A-Za-z0-9.-]+[A-Za-z0-9]$"),
    ],
    settings: SettingsDependency,
) -> FeatureConfigurationEnvelope:
    try:
        return await service.current(
            session,
            owner_id=owner.owner_id,
            environment=settings.env.value,
            audience=audience,
            now=datetime.now(UTC),
        )
    except FeatureConfigurationServiceError as error:
        raise feature_configuration_error(error) from error
