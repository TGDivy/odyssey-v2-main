"""Signed feature configuration and deterministic one-owner assignment."""

import base64
import binascii
import json
from dataclasses import dataclass
from hashlib import sha256

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

from odyssey.telemetry.models import (
    FeatureConfigurationEnvelope,
    FeatureConfigurationPayload,
    FeatureFlagKey,
)


@dataclass(frozen=True, slots=True)
class FeatureFlagDefinition:
    key: FeatureFlagKey
    owner: str
    purpose: str
    default_variant: str
    allowed_variants: tuple[str, ...]


FEATURE_FLAG_REGISTRY = (
    FeatureFlagDefinition(
        key=FeatureFlagKey.CAPTURE_TELEMETRY_QUESTION,
        owner="product_evaluation",
        purpose="Kill switch for the governed payload-free capture question.",
        default_variant="enabled",
        allowed_variants=("enabled", "disabled"),
    ),
    FeatureFlagDefinition(
        key=FeatureFlagKey.TOMORROW_MAP_TELEMETRY_QUESTION,
        owner="product_evaluation",
        purpose="Kill switch for the governed Tomorrow Map value question.",
        default_variant="enabled",
        allowed_variants=("enabled", "disabled"),
    ),
    FeatureFlagDefinition(
        key=FeatureFlagKey.WEEKLY_PRODUCT_REVIEW,
        owner="product_evaluation",
        purpose="Kill switch for local weekly product review generation.",
        default_variant="enabled",
        allowed_variants=("enabled", "disabled"),
    ),
    FeatureFlagDefinition(
        key=FeatureFlagKey.PROACTIVE_NOTIFICATIONS,
        owner="intervention_policy",
        purpose="Edition gate that keeps proactive notifications disabled by default.",
        default_variant="disabled",
        allowed_variants=("enabled", "disabled"),
    ),
)


class FeatureConfigurationError(RuntimeError):
    pass


def canonical_feature_payload(payload: FeatureConfigurationPayload) -> bytes:
    return json.dumps(
        payload.model_dump(mode="json"),
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()


class FeatureConfigurationSigner:
    def __init__(self, *, key_id: str, private_key_base64: str) -> None:
        if (
            not key_id
            or len(key_id) > 100
            or not all(
                character.isascii() and (character.isalnum() or character in "._-")
                for character in key_id
            )
        ):
            raise FeatureConfigurationError("feature configuration key ID is invalid")
        try:
            private_key_bytes = base64.b64decode(private_key_base64, validate=True)
        except (binascii.Error, ValueError) as error:
            raise FeatureConfigurationError(
                "feature configuration private key is not valid base64"
            ) from error
        if len(private_key_bytes) != 32:
            raise FeatureConfigurationError("feature configuration private key must be 32 bytes")
        self.key_id = key_id
        self._private_key = Ed25519PrivateKey.from_private_bytes(private_key_bytes)

    @property
    def public_key_base64(self) -> str:
        public_key = self._private_key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        return base64.b64encode(public_key).decode()

    def sign(self, payload: FeatureConfigurationPayload) -> FeatureConfigurationEnvelope:
        payload_bytes = canonical_feature_payload(payload)
        signature = self._private_key.sign(payload_bytes)
        return FeatureConfigurationEnvelope(
            key_id=self.key_id,
            payload_base64=base64.b64encode(payload_bytes).decode(),
            payload_sha256=sha256(payload_bytes).hexdigest(),
            signature_base64=base64.b64encode(signature).decode(),
        )


def verified_feature_payload(
    envelope: FeatureConfigurationEnvelope,
    *,
    public_key_base64: str,
    expected_key_id: str,
) -> FeatureConfigurationPayload:
    if envelope.key_id != expected_key_id:
        raise FeatureConfigurationError("feature configuration key ID does not match")
    try:
        payload_bytes = base64.b64decode(envelope.payload_base64, validate=True)
        signature = base64.b64decode(envelope.signature_base64, validate=True)
        public_key_bytes = base64.b64decode(public_key_base64, validate=True)
    except (binascii.Error, ValueError) as error:
        raise FeatureConfigurationError("feature configuration encoding is invalid") from error
    if len(payload_bytes) > 65_536 or len(signature) != 64 or len(public_key_bytes) != 32:
        raise FeatureConfigurationError("feature configuration size is invalid")
    if sha256(payload_bytes).hexdigest() != envelope.payload_sha256:
        raise FeatureConfigurationError("feature configuration digest does not match")
    try:
        Ed25519PublicKey.from_public_bytes(public_key_bytes).verify(signature, payload_bytes)
    except (InvalidSignature, ValueError) as error:
        raise FeatureConfigurationError("feature configuration signature is invalid") from error
    try:
        payload = FeatureConfigurationPayload.model_validate_json(payload_bytes)
    except ValueError as error:
        raise FeatureConfigurationError("feature configuration payload is invalid") from error
    if canonical_feature_payload(payload) != payload_bytes:
        raise FeatureConfigurationError("feature configuration payload is not canonical")
    return payload


def assigned_feature_variants(
    payload: FeatureConfigurationPayload | None,
    *,
    assignment_subject: str,
) -> dict[FeatureFlagKey, str]:
    definitions = {definition.key: definition for definition in FEATURE_FLAG_REGISTRY}
    assignments = {
        definition.key: definition.default_variant for definition in FEATURE_FLAG_REGISTRY
    }
    if payload is None:
        return assignments
    for rule in payload.flags:
        bucket_material = f"{rule.assignment_salt}:{rule.key.value}:{assignment_subject}".encode()
        bucket = int.from_bytes(sha256(bucket_material).digest()[:8], "big") % 10_000
        if bucket < rule.rollout_basis_points:
            assignments[rule.key] = rule.variant
        else:
            assignments[rule.key] = definitions[rule.key].default_variant
    return assignments
