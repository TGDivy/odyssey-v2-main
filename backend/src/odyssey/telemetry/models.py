"""Governed product telemetry and product-change contracts."""

from enum import StrEnum

from pydantic import AwareDatetime, Field, model_validator

from odyssey.domain.common import UUID7, EntityMetadata, StrictModel


class ProductEventName(StrEnum):
    CAPTURE_WORKFLOW_STARTED = "capture.workflow_started.v1"
    CAPTURE_WORKFLOW_FINISHED = "capture.workflow_finished.v1"
    CAPTURE_FEEDBACK_RECORDED = "capture.feedback_recorded.v1"
    TOMORROW_MAP_AVAILABILITY_EVALUATED = "tomorrow_map.availability_evaluated.v1"
    TOMORROW_MAP_VIEWED = "tomorrow_map.viewed.v1"
    TOMORROW_MAP_SESSION_FINISHED = "tomorrow_map.session_finished.v1"
    TOMORROW_MAP_FEEDBACK_RECORDED = "tomorrow_map.feedback_recorded.v1"
    TOMORROW_MAP_PLAN_DEVIATION_RECORDED = "tomorrow_map.plan_deviation_recorded.v1"


ProductPropertyValue = str | bool | int | float


class ProductEvent(StrictModel):
    event_id: UUID7
    occurred_at: AwareDatetime
    received_at: AwareDatetime
    session_id: UUID7 | None = None
    device_id: UUID7
    app_build: str = Field(min_length=1, max_length=100)
    surface: str = Field(min_length=1, max_length=80, pattern=r"^[a-z0-9_.-]+$")
    event_name: ProductEventName
    object_type: str | None = Field(default=None, min_length=1, max_length=80)
    object_id_pseudonymous: str | None = Field(
        default=None,
        pattern=r"^[0-9a-f]{64}$",
    )
    context_version: str = Field(min_length=1, max_length=100)
    feature_flag_assignments: dict[str, str] = Field(default_factory=dict, max_length=50)
    properties_typed: dict[str, ProductPropertyValue] = Field(default_factory=dict, max_length=30)
    causal_parent_event_id: UUID7 | None = None
    local_only_flag: bool = True

    @model_validator(mode="after")
    def validate_event(self) -> "ProductEvent":
        if self.received_at < self.occurred_at:
            raise ValueError("received_at cannot precede occurred_at")
        for key, value in self.feature_flag_assignments.items():
            if not _valid_token(key, maximum=100) or not _valid_token(value, maximum=100):
                raise ValueError("feature flag assignments must use bounded tokens")
        from odyssey.telemetry.registry import validate_product_event

        validate_product_event(self.event_name, self.properties_typed)
        return self


def _valid_token(value: str, *, maximum: int) -> bool:
    return (
        1 <= len(value) <= maximum
        and value == value.strip()
        and all(
            character.isascii() and (character.isalnum() or character in "._-")
            for character in value
        )
    )


class ProductChangeStatus(StrEnum):
    PROPOSED = "proposed"
    APPROVED = "approved"
    RUNNING = "running"
    REJECTED = "rejected"
    ADOPTED = "adopted"
    REVERTED = "reverted"


class ProductChangeProposal(StrictModel):
    metadata: EntityMetadata
    observed_pattern: str
    supporting_product_event_query: str
    sample_summary: str
    counterexamples: tuple[str, ...] = ()
    alternative_explanations: tuple[str, ...]
    proposed_change: str
    affected_invariants: tuple[str, ...] = ()
    expected_benefit: str
    possible_harms: tuple[str, ...]
    experiment_plan: str
    rollback: str
    status: ProductChangeStatus


class FeatureFlagKey(StrEnum):
    CAPTURE_TELEMETRY_QUESTION = "product_telemetry.capture_question"
    TOMORROW_MAP_TELEMETRY_QUESTION = "product_telemetry.tomorrow_map_question"
    WEEKLY_PRODUCT_REVIEW = "product_telemetry.weekly_review"
    PROACTIVE_NOTIFICATIONS = "intervention.proactive_notifications"


class FeatureFlagRule(StrictModel):
    key: FeatureFlagKey
    variant: str = Field(min_length=1, max_length=100, pattern=r"^[a-z0-9_.-]+$")
    rollout_basis_points: int = Field(ge=0, le=10_000)
    assignment_salt: str = Field(min_length=1, max_length=100, pattern=r"^[A-Za-z0-9_.-]+$")


class FeatureConfigurationPayload(StrictModel):
    schema_version: int = Field(default=1, ge=1, le=1)
    configuration_id: UUID7
    version: int = Field(ge=1)
    environment: str = Field(
        min_length=1,
        max_length=30,
        pattern=r"^(local|development|staging|production|test)$",
    )
    audience: str = Field(
        min_length=3,
        max_length=255,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9.-]+[A-Za-z0-9]$",
    )
    issued_at: AwareDatetime
    not_before: AwareDatetime
    expires_at: AwareDatetime
    flags: tuple[FeatureFlagRule, ...] = Field(max_length=50)

    @model_validator(mode="after")
    def validate_configuration(self) -> "FeatureConfigurationPayload":
        if self.not_before < self.issued_at:
            raise ValueError("not_before cannot precede issued_at")
        if self.expires_at <= self.not_before:
            raise ValueError("expires_at must follow not_before")
        keys = [rule.key for rule in self.flags]
        if len(set(keys)) != len(keys):
            raise ValueError("feature flag rules must be unique by key")
        from odyssey.telemetry.feature_flags import FEATURE_FLAG_REGISTRY

        definitions = {definition.key: definition for definition in FEATURE_FLAG_REGISTRY}
        for rule in self.flags:
            if rule.variant not in definitions[rule.key].allowed_variants:
                raise ValueError(f"unsupported variant for {rule.key.value}")
        return self


class FeatureConfigurationEnvelope(StrictModel):
    schema_version: int = Field(default=1, ge=1, le=1)
    key_id: str = Field(min_length=1, max_length=100, pattern=r"^[A-Za-z0-9_.-]+$")
    payload_base64: str = Field(min_length=4, max_length=90_000)
    payload_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    signature_base64: str = Field(min_length=4, max_length=200)
