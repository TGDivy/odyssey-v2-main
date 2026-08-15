"""Odyssey API application factory."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import uuid4

import structlog
import uvicorn
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.middleware.base import RequestResponseEndpoint
from starlette.responses import Response

from odyssey import __version__
from odyssey.api.errors import (
    OdysseyError,
    http_error_handler,
    odyssey_error_handler,
    unhandled_error_handler,
    validation_error_handler,
)
from odyssey.api.router import router
from odyssey.config import Settings, get_settings
from odyssey.logging import configure_logging, correlation_id_context


def create_app(settings: Settings | None = None) -> FastAPI:
    active_settings = settings or get_settings()
    configure_logging(active_settings.log_level)
    logger = structlog.get_logger(__name__)

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        logger.info(
            "service_started",
            service="odyssey-api",
            environment=active_settings.env.value,
            version=__version__,
        )
        yield
        logger.info("service_stopped", service="odyssey-api")

    application = FastAPI(
        title="Odyssey API",
        summary="Private local-first personal navigation API",
        version=__version__,
        openapi_version="3.1.0",
        docs_url="/docs" if active_settings.api_docs_enabled else None,
        redoc_url=None,
        lifespan=lifespan,
    )

    def settings_dependency() -> Settings:
        return active_settings

    application.dependency_overrides[get_settings] = settings_dependency

    @application.middleware("http")
    async def correlation_middleware(
        request: Request, call_next: RequestResponseEndpoint
    ) -> Response:
        correlation_id = request.headers.get("X-Correlation-ID") or str(uuid4())
        request.state.correlation_id = correlation_id
        token = correlation_id_context.set(correlation_id)
        try:
            response = await call_next(request)
            response.headers["X-Correlation-ID"] = correlation_id
            return response
        finally:
            correlation_id_context.reset(token)

    application.add_exception_handler(OdysseyError, odyssey_error_handler)
    application.add_exception_handler(StarletteHTTPException, http_error_handler)
    application.add_exception_handler(RequestValidationError, validation_error_handler)
    application.add_exception_handler(Exception, unhandled_error_handler)
    application.include_router(router)
    return application


app = create_app()


def run() -> None:
    uvicorn.run("odyssey.main:app", host="127.0.0.1", port=8080, reload=False)
