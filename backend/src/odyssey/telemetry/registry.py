"""Question-driven product telemetry registry and property validation."""

from enum import StrEnum

from pydantic import Field, model_validator

from odyssey.domain.common import DataClass, StrictModel
from odyssey.telemetry.models import ProductEventName, ProductPropertyValue


class ProductQuestionID(StrEnum):
    CAPTURE_FRICTION = "capture_friction_v1"
    TOMORROW_MAP_VALUE = "tomorrow_map_value_v1"


class ExpectedFeatureFrequency(StrEnum):
    HABITUAL = "habitual"
    DAILY_WHEN_RELEVANT = "daily_when_relevant"


class ProductPropertyType(StrEnum):
    STRING = "string"
    BOOLEAN = "boolean"
    INTEGER = "integer"
    NUMBER = "number"


class ProductEventPropertyDefinition(StrictModel):
    name: str = Field(min_length=1, max_length=100, pattern=r"^[a-z0-9_]+$")
    value_type: ProductPropertyType
    required: bool = True
    allowed_values: tuple[str, ...] = ()
    minimum: int | None = None
    maximum: int | None = None

    @model_validator(mode="after")
    def validate_constraints(self) -> "ProductEventPropertyDefinition":
        if self.allowed_values and self.value_type is not ProductPropertyType.STRING:
            raise ValueError("allowed_values apply only to string properties")
        if len(set(self.allowed_values)) != len(self.allowed_values):
            raise ValueError("allowed_values must be unique")
        if any(not value or len(value) > 100 for value in self.allowed_values):
            raise ValueError("allowed_values must be bounded non-empty strings")
        if (self.minimum is not None or self.maximum is not None) and self.value_type not in {
            ProductPropertyType.INTEGER,
            ProductPropertyType.NUMBER,
        }:
            raise ValueError("numeric bounds apply only to numeric properties")
        if self.minimum is not None and self.maximum is not None and self.maximum < self.minimum:
            raise ValueError("maximum cannot be less than minimum")
        return self


class ProductQuestionDefinition(StrictModel):
    question_id: ProductQuestionID
    statement: str = Field(min_length=1, max_length=500)
    decision_use: str = Field(min_length=1, max_length=500)
    expected_frequency: ExpectedFeatureFrequency


class ProductEventDefinition(StrictModel):
    event_name: ProductEventName
    question_id: ProductQuestionID
    owner: str = Field(min_length=1, max_length=100)
    purpose: str = Field(min_length=1, max_length=500)
    sensitivity: DataClass
    retention_days: int = Field(ge=1, le=365)
    local_only_by_default: bool = True
    properties: tuple[ProductEventPropertyDefinition, ...]

    @model_validator(mode="after")
    def validate_properties(self) -> "ProductEventDefinition":
        names = [property_definition.name for property_definition in self.properties]
        if len(set(names)) != len(names):
            raise ValueError("event property names must be unique")
        return self


class ProductTelemetryRegistryDocument(StrictModel):
    registry_version: int = Field(ge=1)
    questions: tuple[ProductQuestionDefinition, ...]
    events: tuple[ProductEventDefinition, ...]

    @model_validator(mode="after")
    def validate_registry(self) -> "ProductTelemetryRegistryDocument":
        question_ids = [question.question_id for question in self.questions]
        event_names = [event.event_name for event in self.events]
        if len(set(question_ids)) != len(question_ids):
            raise ValueError("question identifiers must be unique")
        if len(set(event_names)) != len(event_names):
            raise ValueError("event names must be unique")
        known_questions = set(question_ids)
        if any(event.question_id not in known_questions for event in self.events):
            raise ValueError("every event must reference a registered question")
        return self


def _string(
    name: str,
    *allowed_values: str,
    required: bool = True,
) -> ProductEventPropertyDefinition:
    return ProductEventPropertyDefinition(
        name=name,
        value_type=ProductPropertyType.STRING,
        required=required,
        allowed_values=allowed_values,
    )


def _boolean(name: str) -> ProductEventPropertyDefinition:
    return ProductEventPropertyDefinition(name=name, value_type=ProductPropertyType.BOOLEAN)


def _integer(name: str, *, minimum: int, maximum: int) -> ProductEventPropertyDefinition:
    return ProductEventPropertyDefinition(
        name=name,
        value_type=ProductPropertyType.INTEGER,
        minimum=minimum,
        maximum=maximum,
    )


CAPTURE_KINDS = ("text", "audio", "image_reference", "file_reference")
CAPTURE_SURFACES = (
    "iphone_now",
    "iphone_global_capture",
    "app_intent",
    "share",
    "widget",
    "watch",
    "control",
    "mac",
)
DURATION_BUCKETS = (
    "under_1s",
    "1_to_3s",
    "3_to_5s",
    "5_to_10s",
    "10_to_30s",
    "30s_or_more",
)
CALENDAR_STATES = ("fresh", "stale", "missing", "denied", "unavailable")


PRODUCT_TELEMETRY_REGISTRY = ProductTelemetryRegistryDocument(
    registry_version=1,
    questions=(
        ProductQuestionDefinition(
            question_id=ProductQuestionID.CAPTURE_FRICTION,
            statement=(
                "Does capture remain fast and low-friction across supported inputs without "
                "collecting captured content?"
            ),
            decision_use=(
                "Identify bounded workflow friction or abandonment without measuring generic "
                "engagement."
            ),
            expected_frequency=ExpectedFeatureFrequency.HABITUAL,
        ),
        ProductQuestionDefinition(
            question_id=ProductQuestionID.TOMORROW_MAP_VALUE,
            statement=(
                "Does the Tomorrow Map reduce uncertainty without becoming a nightly chore?"
            ),
            decision_use=(
                "Decide whether to preserve, refine, suppress, or remove the bounded map surface."
            ),
            expected_frequency=ExpectedFeatureFrequency.DAILY_WHEN_RELEVANT,
        ),
    ),
    events=(
        ProductEventDefinition(
            event_name=ProductEventName.CAPTURE_WORKFLOW_STARTED,
            question_id=ProductQuestionID.CAPTURE_FRICTION,
            owner="product_evaluation",
            purpose="Mark a payload-free capture attempt denominator.",
            sensitivity=DataClass.PRIVATE,
            retention_days=30,
            properties=(
                _string("capture_kind", *CAPTURE_KINDS),
                _string("invoking_surface", *CAPTURE_SURFACES),
            ),
        ),
        ProductEventDefinition(
            event_name=ProductEventName.CAPTURE_WORKFLOW_FINISHED,
            question_id=ProductQuestionID.CAPTURE_FRICTION,
            owner="product_evaluation",
            purpose="Measure bounded capture completion, failure, or abandonment friction.",
            sensitivity=DataClass.PRIVATE,
            retention_days=30,
            properties=(
                _string("capture_kind", *CAPTURE_KINDS),
                _string("invoking_surface", *CAPTURE_SURFACES),
                _string("outcome", "committed", "failed", "abandoned"),
                _string("exit_stage", "entry", "selection", "saving", "local_commit"),
                _string("duration_bucket", *DURATION_BUCKETS),
            ),
        ),
        ProductEventDefinition(
            event_name=ProductEventName.CAPTURE_FEEDBACK_RECORDED,
            question_id=ProductQuestionID.CAPTURE_FRICTION,
            owner="product_evaluation",
            purpose="Record situated usefulness or friction without capture payload.",
            sensitivity=DataClass.PRIVATE,
            retention_days=30,
            properties=(
                _string("rating", "useful", "neutral", "added_friction"),
                _string(
                    "reason",
                    "fast",
                    "too_many_steps",
                    "wrong_context",
                    "bad_timing",
                    "unclear",
                    "other",
                    required=False,
                ),
            ),
        ),
        ProductEventDefinition(
            event_name=ProductEventName.TOMORROW_MAP_AVAILABILITY_EVALUATED,
            question_id=ProductQuestionID.TOMORROW_MAP_VALUE,
            owner="product_evaluation",
            purpose="Distinguish automatic availability, degradation, and intentional absence.",
            sensitivity=DataClass.PRIVATE,
            retention_days=30,
            properties=(
                _string("calendar_state", *CALENDAR_STATES),
                _boolean("intentionally_absent"),
                _integer("transition_count", minimum=0, maximum=3),
                _boolean("pressure_present"),
                _boolean("protected_open_present"),
            ),
        ),
        ProductEventDefinition(
            event_name=ProductEventName.TOMORROW_MAP_VIEWED,
            question_id=ProductQuestionID.TOMORROW_MAP_VALUE,
            owner="product_evaluation",
            purpose="Record a bounded map view and its entry point.",
            sensitivity=DataClass.PRIVATE,
            retention_days=30,
            properties=(
                _string("calendar_state", *CALENDAR_STATES),
                _string("entry_point", "automatic_now", "notification", "widget"),
            ),
        ),
        ProductEventDefinition(
            event_name=ProductEventName.TOMORROW_MAP_SESSION_FINISHED,
            question_id=ProductQuestionID.TOMORROW_MAP_VALUE,
            owner="product_evaluation",
            purpose="Measure bounded viewing effort without retaining navigation history.",
            sensitivity=DataClass.PRIVATE,
            retention_days=30,
            properties=(
                _string("duration_bucket", *DURATION_BUCKETS),
                _string("outcome", "dismissed", "feedback", "backgrounded"),
            ),
        ),
        ProductEventDefinition(
            event_name=ProductEventName.TOMORROW_MAP_FEEDBACK_RECORDED,
            question_id=ProductQuestionID.TOMORROW_MAP_VALUE,
            owner="product_evaluation",
            purpose="Record situated map usefulness or correction reason.",
            sensitivity=DataClass.PRIVATE,
            retention_days=30,
            properties=(
                _string("rating", "useful", "not_useful", "added_friction"),
                _string(
                    "reason",
                    "wrong_context",
                    "bad_timing",
                    "already_handled",
                    "too_intrusive",
                    "reasoning_wrong",
                    "fact_wrong",
                    "preference_changed",
                    "show_less",
                    "other",
                    required=False,
                ),
            ),
        ),
        ProductEventDefinition(
            event_name=ProductEventName.TOMORROW_MAP_PLAN_DEVIATION_RECORDED,
            question_id=ProductQuestionID.TOMORROW_MAP_VALUE,
            owner="product_evaluation",
            purpose="Capture a next-day deviation without recording plan content.",
            sensitivity=DataClass.PRIVATE,
            retention_days=30,
            properties=(
                _string("deviation", "none", "minor", "material", "unknown"),
                _string("map_influence", "helped", "no_effect", "added_burden", "uncertain"),
            ),
        ),
    ),
)


_EVENTS_BY_NAME = {event.event_name: event for event in PRODUCT_TELEMETRY_REGISTRY.events}


def validate_product_event(
    event_name: ProductEventName,
    properties: dict[str, ProductPropertyValue],
) -> None:
    definition = _EVENTS_BY_NAME[event_name]
    definitions = {item.name: item for item in definition.properties}
    unknown = set(properties) - set(definitions)
    if unknown:
        raise ValueError(f"unknown telemetry properties: {', '.join(sorted(unknown))}")
    missing = {
        name for name, property_definition in definitions.items() if property_definition.required
    } - set(properties)
    if missing:
        raise ValueError(f"missing telemetry properties: {', '.join(sorted(missing))}")
    for name, value in properties.items():
        _validate_property(definitions[name], value)


def _validate_property(
    definition: ProductEventPropertyDefinition,
    value: ProductPropertyValue,
) -> None:
    if definition.value_type is ProductPropertyType.STRING:
        if not isinstance(value, str) or not 1 <= len(value) <= 100:
            raise ValueError(f"{definition.name} must be a bounded string")
        if definition.allowed_values and value not in definition.allowed_values:
            raise ValueError(f"{definition.name} is not an allowed value")
        return
    if definition.value_type is ProductPropertyType.BOOLEAN:
        if not isinstance(value, bool):
            raise ValueError(f"{definition.name} must be a boolean")
        return
    if definition.value_type is ProductPropertyType.INTEGER:
        if isinstance(value, bool) or not isinstance(value, int):
            raise ValueError(f"{definition.name} must be an integer")
    elif definition.value_type is ProductPropertyType.NUMBER:
        if isinstance(value, bool) or not isinstance(value, int | float):
            raise ValueError(f"{definition.name} must be a number")
    else:
        raise AssertionError("unhandled telemetry property type")
    numeric_value = float(value)
    if definition.minimum is not None and numeric_value < definition.minimum:
        raise ValueError(f"{definition.name} is below its minimum")
    if definition.maximum is not None and numeric_value > definition.maximum:
        raise ValueError(f"{definition.name} exceeds its maximum")
