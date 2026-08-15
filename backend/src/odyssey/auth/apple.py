"""Sign in with Apple identity-token verification with bounded JWKS caching."""

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from hashlib import sha256
from hmac import compare_digest
from time import monotonic
from typing import Any

import httpx
import jwt
from jwt import PyJWK
from jwt.exceptions import InvalidTokenError, PyJWKError


class AppleIdentityError(RuntimeError):
    pass


class AppleIdentityConfigurationError(AppleIdentityError):
    pass


class AppleIdentityKeysUnavailableError(AppleIdentityError):
    pass


class AppleIdentityTokenError(AppleIdentityError):
    pass


@dataclass(frozen=True, slots=True)
class AppleIdentity:
    subject: str
    issued_at: datetime
    expires_at: datetime


JwksFetcher = Callable[[], Awaitable[dict[str, Any]]]


class AppleIdentityVerifier:
    def __init__(
        self,
        *,
        audience: str,
        issuer: str,
        jwks_url: str,
        cache_seconds: int,
        request_timeout_seconds: int,
        maximum_token_age_seconds: int,
        clock_skew_seconds: int,
        jwks_fetcher: JwksFetcher | None = None,
    ) -> None:
        self.audience = audience
        self.issuer = issuer
        self.jwks_url = jwks_url
        self.cache_seconds = cache_seconds
        self.request_timeout_seconds = request_timeout_seconds
        self.maximum_token_age_seconds = maximum_token_age_seconds
        self.clock_skew_seconds = clock_skew_seconds
        self._jwks_fetcher = jwks_fetcher or self._fetch_jwks
        self._keys: dict[str, PyJWK] = {}
        self._cache_expires_at = 0.0
        self._last_refresh_at = 0.0
        self._refresh_lock = asyncio.Lock()

    async def verify(
        self,
        identity_token: str,
        *,
        raw_nonce: str,
        now: datetime,
    ) -> AppleIdentity:
        if not self.audience:
            raise AppleIdentityConfigurationError("Apple identity audience is not configured")
        try:
            header = jwt.get_unverified_header(identity_token)
        except InvalidTokenError as error:
            raise AppleIdentityTokenError("Apple identity token is invalid") from error
        if header.get("alg") != "RS256" or not isinstance(header.get("kid"), str):
            raise AppleIdentityTokenError("Apple identity token is invalid")
        key = await self._key(header["kid"])
        try:
            claims = jwt.decode(
                identity_token,
                key=key,
                algorithms=["RS256"],
                audience=self.audience,
                issuer=self.issuer,
                leeway=self.clock_skew_seconds,
                options={"require": ["aud", "exp", "iat", "iss", "nonce", "sub"]},
            )
        except InvalidTokenError as error:
            raise AppleIdentityTokenError("Apple identity token is invalid") from error
        subject = claims.get("sub")
        issued_at_value = claims.get("iat")
        expires_at_value = claims.get("exp")
        nonce = claims.get("nonce")
        if (
            not isinstance(subject, str)
            or not subject
            or len(subject) > 255
            or not isinstance(issued_at_value, int)
            or not isinstance(expires_at_value, int)
            or not isinstance(nonce, str)
        ):
            raise AppleIdentityTokenError("Apple identity token is invalid")
        expected_nonce = sha256(raw_nonce.encode()).hexdigest()
        if not compare_digest(nonce, expected_nonce):
            raise AppleIdentityTokenError("Apple identity token is invalid")
        issued_at = datetime.fromtimestamp(issued_at_value, UTC)
        expires_at = datetime.fromtimestamp(expires_at_value, UTC)
        age_seconds = (now - issued_at).total_seconds()
        if age_seconds < -self.clock_skew_seconds or age_seconds > self.maximum_token_age_seconds:
            raise AppleIdentityTokenError("Apple identity token is invalid")
        return AppleIdentity(subject=subject, issued_at=issued_at, expires_at=expires_at)

    async def _key(self, key_id: str) -> PyJWK:
        current_time = monotonic()
        key = self._keys.get(key_id)
        if key is not None and current_time < self._cache_expires_at:
            return key
        async with self._refresh_lock:
            current_time = monotonic()
            key = self._keys.get(key_id)
            if key is not None and current_time < self._cache_expires_at:
                return key
            if (
                self._keys
                and current_time < self._cache_expires_at
                and current_time - self._last_refresh_at < 60
            ):
                raise AppleIdentityTokenError("Apple identity token is invalid")
            await self._refresh_keys(current_time)
            key = self._keys.get(key_id)
            if key is None:
                raise AppleIdentityTokenError("Apple identity token is invalid")
            return key

    async def _refresh_keys(self, refreshed_at: float) -> None:
        try:
            payload = await self._jwks_fetcher()
            raw_keys = payload.get("keys")
            if not isinstance(raw_keys, list) or len(raw_keys) > 20:
                raise ValueError("invalid JWKS key collection")
            keys: dict[str, PyJWK] = {}
            for raw_key in raw_keys:
                if not isinstance(raw_key, dict) or raw_key.get("alg") not in {None, "RS256"}:
                    continue
                key = PyJWK.from_dict(raw_key, algorithm="RS256")
                if key.key_id:
                    keys[key.key_id] = key
            if not keys:
                raise ValueError("empty JWKS key collection")
        except (AppleIdentityKeysUnavailableError, PyJWKError, TypeError, ValueError) as error:
            raise AppleIdentityKeysUnavailableError(
                "Apple identity keys are unavailable"
            ) from error
        self._keys = keys
        self._last_refresh_at = refreshed_at
        self._cache_expires_at = refreshed_at + self.cache_seconds

    async def _fetch_jwks(self) -> dict[str, Any]:
        try:
            async with httpx.AsyncClient(
                timeout=self.request_timeout_seconds,
                follow_redirects=False,
            ) as client:
                response = await client.get(
                    self.jwks_url,
                    headers={"Accept": "application/json"},
                )
                response.raise_for_status()
                if len(response.content) > 1_000_000:
                    raise AppleIdentityKeysUnavailableError("Apple identity keys are unavailable")
                payload = response.json()
        except (httpx.HTTPError, ValueError) as error:
            raise AppleIdentityKeysUnavailableError(
                "Apple identity keys are unavailable"
            ) from error
        if not isinstance(payload, dict):
            raise AppleIdentityKeysUnavailableError("Apple identity keys are unavailable")
        return payload
