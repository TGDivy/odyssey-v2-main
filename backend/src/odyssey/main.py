"""Odyssey API application factory."""

import re
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from time import perf_counter
from uuid import uuid4

import structlog
import uvicorn
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from opentelemetry.trace import SpanKind
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
from odyssey.attachments.service import UploadTokenSigner
from odyssey.attachments.storage import AttachmentStore
from odyssey.attachments.storage_factory import create_attachment_store
from odyssey.auth.apple import AppleIdentityVerifier
from odyssey.auth.service import AuthService
from odyssey.config import Environment, Settings, get_settings
from odyssey.db.session import Database
from odyssey.logging import configure_logging, correlation_id_context
from odyssey.telemetry.runtime import TelemetryRuntime, create_telemetry_runtime

SAFE_CORRELATION_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")


def create_app(
    settings: Settings | None = None,
    database: Database | None = None,
    attachment_store: AttachmentStore | None = None,
    upload_token_signer: UploadTokenSigner | None = None,
    telemetry: TelemetryRuntime | None = None,
    apple_identity_verifier: AppleIdentityVerifier | None = None,
) -> FastAPI:
    active_settings = settings or get_settings()
    active_database = database or Database(
        "sqlite+aiosqlite:///:memory:"
        if active_settings.env is Environment.TEST
        else active_settings.database_url
    )
    active_attachment_store = attachment_store or create_attachment_store(active_settings)
    signing_secret = active_settings.attachment_upload_signing_key.get_secret_value().encode()
    active_upload_token_signer = upload_token_signer or UploadTokenSigner(signing_secret or None)
    active_auth_service = AuthService(
        settings=active_settings,
        database=active_database,
        apple_verifier=apple_identity_verifier,
    )
    active_telemetry = telemetry or create_telemetry_runtime(
        active_settings,
        service_name="odyssey-api",
        service_version=__version__,
    )
    configure_logging(active_settings.log_level)
    logger = structlog.get_logger(__name__)

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        await active_attachment_store.validate_configuration()
        logger.info(
            "service_started",
            service="odyssey-api",
            environment=active_settings.env.value,
            version=__version__,
        )
        try:
            yield
        finally:
            await active_database.dispose()
            logger.info("service_stopped", service="odyssey-api")
            active_telemetry.shutdown()

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
    application.state.database = active_database
    application.state.attachment_store = active_attachment_store
    application.state.upload_token_signer = active_upload_token_signer
    application.state.telemetry = active_telemetry
    application.state.auth_service = active_auth_service

    @application.middleware("http")
    async def correlation_middleware(
        request: Request, call_next: RequestResponseEndpoint
    ) -> Response:
        supplied_correlation_id = request.headers.get("X-Correlation-ID", "")
        correlation_id = (
            supplied_correlation_id
            if SAFE_CORRELATION_ID.fullmatch(supplied_correlation_id)
            else str(uuid4())
        )
        request.state.correlation_id = correlation_id
        token = correlation_id_context.set(correlation_id)
        try:
            parent_context = active_telemetry.extract_context(request.headers)
            with active_telemetry.span(
                f"{request.method} request",
                context=parent_context,
                kind=SpanKind.SERVER,
                attributes={"http.request.method": request.method},
            ) as span:
                started_at = perf_counter()
                status_code = 500
                error_type: str | None = None
                trace_id, span_id = active_telemetry.span_ids(span)
                request.state.trace_id = trace_id
                try:
                    response = await call_next(request)
                    status_code = response.status_code
                    response.headers["X-Correlation-ID"] = correlation_id
                    response.headers["X-Trace-ID"] = trace_id
                    response.headers["X-Span-ID"] = span_id
                    for header, value in active_telemetry.inject_context().items():
                        response.headers[header] = value
                    return response
                except Exception as error:
                    error_type = type(error).__name__
                    active_telemetry.mark_error(span, error_type)
                    raise
                finally:
                    duration_seconds = perf_counter() - started_at
                    route = request.scope.get("route")
                    route_path = getattr(route, "path", "unmatched")
                    span.update_name(f"{request.method} {route_path}")
                    span.set_attribute("http.route", route_path)
                    span.set_attribute("http.response.status_code", status_code)
                    if status_code >= 500 and error_type is None:
                        active_telemetry.mark_error(span, f"HTTP_{status_code}")
                    active_telemetry.record_http_request(
                        method=request.method,
                        route=route_path,
                        status_code=status_code,
                        duration_seconds=duration_seconds,
                    )
                    logger.info(
                        "http_request_completed",
                        method=request.method,
                        route=route_path,
                        status_code=status_code,
                        duration_ms=round(duration_seconds * 1000, 2),
                        trace_id=trace_id,
                        span_id=span_id,
                        error_type=error_type,
                    )
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
    uvicorn.run(
        "odyssey.main:app",
        host="127.0.0.1",
        port=8080,
        reload=False,
        access_log=False,
    )
