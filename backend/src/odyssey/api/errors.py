"""Stable API error envelopes that never expose private payloads."""

from typing import Any

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from starlette.exceptions import HTTPException as StarletteHTTPException


class ErrorBody(BaseModel):
    code: str
    message: str
    retryable: bool
    correlation_id: str
    details: dict[str, Any] = Field(default_factory=dict)


class ErrorEnvelope(BaseModel):
    error: ErrorBody


class OdysseyError(Exception):
    def __init__(
        self,
        *,
        code: str,
        message: str,
        status_code: int,
        retryable: bool = False,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.retryable = retryable
        self.details = details or {}


def _correlation_id(request: Request) -> str:
    return str(getattr(request.state, "correlation_id", "unknown"))


def _response(
    request: Request,
    *,
    status_code: int,
    code: str,
    message: str,
    retryable: bool = False,
    details: dict[str, Any] | None = None,
) -> JSONResponse:
    envelope = ErrorEnvelope(
        error=ErrorBody(
            code=code,
            message=message,
            retryable=retryable,
            correlation_id=_correlation_id(request),
            details=details or {},
        )
    )
    return JSONResponse(status_code=status_code, content=envelope.model_dump(mode="json"))


async def odyssey_error_handler(request: Request, exc: Exception) -> JSONResponse:
    if not isinstance(exc, OdysseyError):
        raise TypeError("Expected OdysseyError")
    return _response(
        request,
        status_code=exc.status_code,
        code=exc.code,
        message=exc.message,
        retryable=exc.retryable,
        details=exc.details,
    )


async def http_error_handler(request: Request, exc: Exception) -> JSONResponse:
    if not isinstance(exc, StarletteHTTPException):
        raise TypeError("Expected HTTPException")
    message = str(exc.detail) if exc.status_code < 500 else "The request could not be completed."
    return _response(
        request,
        status_code=exc.status_code,
        code=f"HTTP_{exc.status_code}",
        message=message,
        retryable=exc.status_code in {429, 502, 503, 504},
    )


async def validation_error_handler(request: Request, exc: Exception) -> JSONResponse:
    if not isinstance(exc, RequestValidationError):
        raise TypeError("Expected RequestValidationError")
    fields = [".".join(str(part) for part in error["loc"]) for error in exc.errors()]
    return _response(
        request,
        status_code=422,
        code="REQUEST_VALIDATION_FAILED",
        message="The request did not match the API contract.",
        details={"fields": fields},
    )


async def unhandled_error_handler(request: Request, _exc: Exception) -> JSONResponse:
    return _response(
        request,
        status_code=500,
        code="INTERNAL_ERROR",
        message="The request could not be completed.",
        retryable=False,
    )
