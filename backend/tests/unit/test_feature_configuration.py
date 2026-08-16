"""Signed feature configuration contract tests."""

import base64
from datetime import UTC, datetime, timedelta

import pytest
from pydantic import ValidationError

from odyssey.domain.common import new_uuid7
from odyssey.telemetry.feature_flags import (
    FEATURE_FLAG_REGISTRY,
    FeatureConfigurationError,
    FeatureConfigurationSigner,
    assigned_feature_variants,
    verified_feature_payload,
)
from odyssey.telemetry.models import (
    FeatureConfigurationEnvelope,
    FeatureConfigurationPayload,
    FeatureFlagKey,
    FeatureFlagRule,
)

ISSUED_AT = datetime(2026, 8, 16, 12, tzinfo=UTC)
PRIVATE_KEY_BASE64 = base64.b64encode(bytes(range(1, 33))).decode()


def payload(*, rollout_basis_points: int = 10_000) -> FeatureConfigurationPayload:
    return FeatureConfigurationPayload(
        configuration_id=new_uuid7(),
        version=1,
        environment="test",
        audience="com.example.odyssey.app",
        issued_at=ISSUED_AT,
        not_before=ISSUED_AT,
        expires_at=ISSUED_AT + timedelta(days=7),
        flags=(
            FeatureFlagRule(
                key=FeatureFlagKey.PROACTIVE_NOTIFICATIONS,
                variant="enabled",
                rollout_basis_points=rollout_basis_points,
                assignment_salt="synthetic-1",
            ),
        ),
    )


def test_feature_registry_keeps_notifications_disabled_by_default() -> None:
    definitions = {definition.key: definition for definition in FEATURE_FLAG_REGISTRY}

    assert len(definitions) == len(FeatureFlagKey)
    assert definitions[FeatureFlagKey.PROACTIVE_NOTIFICATIONS].default_variant == "disabled"


def test_ed25519_envelope_verifies_canonical_payload() -> None:
    signer = FeatureConfigurationSigner(
        key_id="synthetic-key-1",
        private_key_base64=PRIVATE_KEY_BASE64,
    )
    original = payload()
    envelope = signer.sign(original)

    verified = verified_feature_payload(
        envelope,
        public_key_base64=signer.public_key_base64,
        expected_key_id="synthetic-key-1",
    )

    assert verified == original
    assert envelope.payload_sha256 != envelope.signature_base64


def test_feature_envelope_rejects_tampering_and_wrong_key() -> None:
    signer = FeatureConfigurationSigner(
        key_id="synthetic-key-1",
        private_key_base64=PRIVATE_KEY_BASE64,
    )
    envelope = signer.sign(payload())
    tampered = FeatureConfigurationEnvelope(
        key_id=envelope.key_id,
        payload_base64=envelope.payload_base64,
        payload_sha256="0" * 64,
        signature_base64=envelope.signature_base64,
    )

    with pytest.raises(FeatureConfigurationError, match="digest"):
        verified_feature_payload(
            tampered,
            public_key_base64=signer.public_key_base64,
            expected_key_id="synthetic-key-1",
        )
    with pytest.raises(FeatureConfigurationError, match="key ID"):
        verified_feature_payload(
            envelope,
            public_key_base64=signer.public_key_base64,
            expected_key_id="another-key",
        )


def test_assignment_is_deterministic_and_honors_rollout_boundaries() -> None:
    enabled = assigned_feature_variants(payload(), assignment_subject="synthetic-device")
    disabled = assigned_feature_variants(
        payload(rollout_basis_points=0),
        assignment_subject="synthetic-device",
    )
    defaults = assigned_feature_variants(None, assignment_subject="synthetic-device")

    assert enabled[FeatureFlagKey.PROACTIVE_NOTIFICATIONS] == "enabled"
    assert disabled[FeatureFlagKey.PROACTIVE_NOTIFICATIONS] == "disabled"
    assert defaults[FeatureFlagKey.CAPTURE_TELEMETRY_QUESTION] == "enabled"
    assert defaults[FeatureFlagKey.PROACTIVE_NOTIFICATIONS] == "disabled"


def test_payload_rejects_unregistered_variant_and_duplicate_rule() -> None:
    rule = FeatureFlagRule(
        key=FeatureFlagKey.WEEKLY_PRODUCT_REVIEW,
        variant="unsupported",
        rollout_basis_points=10_000,
        assignment_salt="synthetic-1",
    )
    with pytest.raises(ValidationError, match="unsupported variant"):
        FeatureConfigurationPayload(
            configuration_id=new_uuid7(),
            version=1,
            environment="test",
            audience="com.example.odyssey.app",
            issued_at=ISSUED_AT,
            not_before=ISSUED_AT,
            expires_at=ISSUED_AT + timedelta(days=7),
            flags=(rule,),
        )
