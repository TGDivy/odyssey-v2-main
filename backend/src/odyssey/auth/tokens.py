"""Short-lived Odyssey access-token issuance and verification."""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID

import jwt
from jwt.exceptions import InvalidTokenError

from odyssey.domain.common import new_uuid7

AUTH_ISSUER = "odyssey-api"
AUTH_AUDIENCE = "odyssey-owner-api"


class AccessTokenError(RuntimeError):
    pass


class AccessTokenConfigurationError(AccessTokenError):
    pass


@dataclass(frozen=True, slots=True)
class IssuedAccessToken:
    token: str
    expires_at: datetime


@dataclass(frozen=True, slots=True)
class AccessTokenClaims:
    owner_id: str
    device_id: UUID
    expires_at: datetime
    token_id: str


class AccessTokenService:
    def __init__(
        self,
        *,
        signing_key: str,
        ttl_seconds: int,
        clock_skew_seconds: int,
    ) -> None:
        self._signing_key = signing_key
        self.ttl_seconds = ttl_seconds
        self.clock_skew_seconds = clock_skew_seconds

    def issue(
        self,
        *,
        owner_id: str,
        device_id: UUID,
        now: datetime,
    ) -> IssuedAccessToken:
        self._require_key()
        expires_at = now + timedelta(seconds=self.ttl_seconds)
        token = jwt.encode(
            {
                "iss": AUTH_ISSUER,
                "aud": AUTH_AUDIENCE,
                "sub": owner_id,
                "device_id": str(device_id),
                "iat": int(now.timestamp()),
                "exp": int(expires_at.timestamp()),
                "jti": str(new_uuid7()),
                "token_type": "access",
                "version": 1,
            },
            self._signing_key,
            algorithm="HS256",
        )
        return IssuedAccessToken(token=token, expires_at=expires_at)

    def verify(self, token: str) -> AccessTokenClaims:
        self._require_key()
        try:
            claims = jwt.decode(
                token,
                self._signing_key,
                algorithms=["HS256"],
                audience=AUTH_AUDIENCE,
                issuer=AUTH_ISSUER,
                leeway=self.clock_skew_seconds,
                options={
                    "require": [
                        "aud",
                        "device_id",
                        "exp",
                        "iat",
                        "iss",
                        "jti",
                        "sub",
                        "token_type",
                        "version",
                    ]
                },
            )
            if claims.get("token_type") != "access" or claims.get("version") != 1:
                raise ValueError("unexpected access token type")
            owner_id = claims["sub"]
            device_id = UUID(claims["device_id"])
            expires_at_value = claims["exp"]
            token_id = claims["jti"]
            if (
                not isinstance(owner_id, str)
                or not owner_id
                or device_id.version != 7
                or not isinstance(expires_at_value, int)
                or not isinstance(token_id, str)
            ):
                raise ValueError("invalid access token claims")
        except (InvalidTokenError, KeyError, TypeError, ValueError) as error:
            raise AccessTokenError("Odyssey access token is invalid") from error
        return AccessTokenClaims(
            owner_id=owner_id,
            device_id=device_id,
            expires_at=datetime.fromtimestamp(expires_at_value, UTC),
            token_id=token_id,
        )

    def _require_key(self) -> None:
        if len(self._signing_key.encode()) < 32:
            raise AccessTokenConfigurationError("access-token signing key is not configured")
