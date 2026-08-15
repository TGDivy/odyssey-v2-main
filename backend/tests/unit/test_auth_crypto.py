import asyncio
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from typing import Any, cast

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm
from pydantic import ValidationError

from odyssey.auth.apple import AppleIdentityTokenError, AppleIdentityVerifier
from odyssey.auth.tokens import (
    AccessTokenConfigurationError,
    AccessTokenError,
    AccessTokenService,
)
from odyssey.config import AuthMode, Environment, Settings
from odyssey.domain.common import new_uuid7


def apple_signing_fixture() -> tuple[rsa.RSAPrivateKey, dict[str, Any]]:
    private_key = rsa.generate_private_key(public_exponent=65_537, key_size=2048)
    public_jwk = cast(dict[str, Any], RSAAlgorithm.to_jwk(private_key.public_key(), as_dict=True))
    public_jwk.update({"alg": "RS256", "kid": "synthetic-apple-key", "use": "sig"})
    return private_key, public_jwk


def apple_token(
    private_key: rsa.RSAPrivateKey,
    *,
    nonce: str,
    now: datetime,
    audience: str = "com.example.odyssey",
    key_id: str = "synthetic-apple-key",
) -> str:
    return jwt.encode(
        {
            "iss": "https://appleid.apple.com",
            "aud": audience,
            "sub": "000999.synthetic-owner",
            "iat": int(now.timestamp()),
            "exp": int((now + timedelta(minutes=5)).timestamp()),
            "nonce": nonce,
            "email": "ignored-fixture@example.invalid",
        },
        private_key,
        algorithm="RS256",
        headers={"kid": key_id},
    )


def test_apple_identity_verifier_checks_signature_nonce_and_cache() -> None:
    async def scenario() -> None:
        private_key, public_jwk = apple_signing_fixture()
        raw_nonce = "synthetic-single-use-nonce"
        nonce_hash = sha256(raw_nonce.encode()).hexdigest()
        now = datetime.now(UTC).replace(microsecond=0)
        fetch_count = 0

        async def fetch_jwks() -> dict[str, Any]:
            nonlocal fetch_count
            fetch_count += 1
            return {"keys": [public_jwk]}

        verifier = AppleIdentityVerifier(
            audience="com.example.odyssey",
            issuer="https://appleid.apple.com",
            jwks_url="https://appleid.apple.com/auth/keys",
            cache_seconds=3600,
            request_timeout_seconds=5,
            maximum_token_age_seconds=600,
            clock_skew_seconds=30,
            jwks_fetcher=fetch_jwks,
        )
        token = apple_token(private_key, nonce=nonce_hash, now=now)

        first = await verifier.verify(token, raw_nonce=raw_nonce, now=now)
        second = await verifier.verify(token, raw_nonce=raw_nonce, now=now)

        assert first.subject == "000999.synthetic-owner"
        assert second == first
        assert fetch_count == 1
        with pytest.raises(AppleIdentityTokenError, match="identity token is invalid"):
            await verifier.verify(token, raw_nonce="wrong-nonce", now=now)
        unknown_key_token = apple_token(
            private_key,
            nonce=nonce_hash,
            now=now,
            key_id="unknown-key",
        )
        with pytest.raises(AppleIdentityTokenError, match="identity token is invalid"):
            await verifier.verify(unknown_key_token, raw_nonce=raw_nonce, now=now)
        assert fetch_count == 1

    asyncio.run(scenario())


def test_apple_identity_verifier_rejects_wrong_audience_and_old_token() -> None:
    async def scenario() -> None:
        private_key, public_jwk = apple_signing_fixture()
        raw_nonce = "synthetic-nonce"
        nonce_hash = sha256(raw_nonce.encode()).hexdigest()
        now = datetime.now(UTC).replace(microsecond=0)

        async def fetch_jwks() -> dict[str, Any]:
            return {"keys": [public_jwk]}

        verifier = AppleIdentityVerifier(
            audience="com.example.odyssey",
            issuer="https://appleid.apple.com",
            jwks_url="https://appleid.apple.com/auth/keys",
            cache_seconds=3600,
            request_timeout_seconds=5,
            maximum_token_age_seconds=600,
            clock_skew_seconds=30,
            jwks_fetcher=fetch_jwks,
        )
        wrong_audience = apple_token(
            private_key,
            nonce=nonce_hash,
            now=now,
            audience="com.example.another-app",
        )
        old_but_unexpired = apple_token(
            private_key,
            nonce=nonce_hash,
            now=now - timedelta(minutes=11),
        )

        with pytest.raises(AppleIdentityTokenError, match="identity token is invalid"):
            await verifier.verify(wrong_audience, raw_nonce=raw_nonce, now=now)
        with pytest.raises(AppleIdentityTokenError, match="identity token is invalid"):
            await verifier.verify(old_but_unexpired, raw_nonce=raw_nonce, now=now)

    asyncio.run(scenario())


def test_odyssey_access_tokens_are_short_lived_and_device_bound() -> None:
    service = AccessTokenService(
        signing_key="synthetic-signing-key-at-least-32-bytes-long",
        ttl_seconds=900,
        clock_skew_seconds=0,
    )
    now = datetime.now(UTC).replace(microsecond=0)
    device_id = new_uuid7()

    issued = service.issue(owner_id="owner", device_id=device_id, now=now)
    claims = service.verify(issued.token)

    assert claims.owner_id == "owner"
    assert claims.device_id == device_id
    assert issued.expires_at == now + timedelta(minutes=15)
    with pytest.raises(AccessTokenError, match="access token is invalid"):
        service.verify(f"{issued.token[:-1]}x")

    expired = service.issue(
        owner_id="owner",
        device_id=device_id,
        now=now - timedelta(hours=2),
    )
    with pytest.raises(AccessTokenError, match="access token is invalid"):
        service.verify(expired.token)


def test_auth_configuration_fails_closed() -> None:
    weak_service = AccessTokenService(
        signing_key="short",
        ttl_seconds=900,
        clock_skew_seconds=30,
    )
    with pytest.raises(AccessTokenConfigurationError, match="signing key"):
        weak_service.issue(owner_id="owner", device_id=new_uuid7(), now=datetime.now(UTC))

    with pytest.raises(ValidationError, match="Apple client ID"):
        Settings(
            env=Environment.PRODUCTION,
            auth_mode=AuthMode.SIGN_IN_WITH_APPLE,
            attachment_upload_signing_key="synthetic-attachment-signing-key",
        )

    settings = Settings(
        env=Environment.PRODUCTION,
        auth_mode=AuthMode.SIGN_IN_WITH_APPLE,
        apple_client_id="com.example.odyssey",
        auth_access_token_signing_key="synthetic-signing-key-at-least-32-bytes-long",
        attachment_upload_signing_key="synthetic-attachment-signing-key",
    )
    assert settings.safe_diagnostics()["apple_client_configured"] is True
    assert "synthetic-signing-key" not in repr(settings.safe_diagnostics())
