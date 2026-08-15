"""Provider-neutral model execution contracts."""

from pydantic import AwareDatetime

from odyssey.domain.common import UUID7, DataClass, EntityMetadata, StrictModel


class ModelUsage(StrictModel):
    input_tokens: int = 0
    output_tokens: int = 0
    cached_tokens: int = 0
    estimated_cost_minor_units: int = 0
    currency: str = "USD"


class ModelRun(StrictModel):
    metadata: EntityMetadata
    capability: str
    capability_version: str
    provider: str
    model_snapshot: str
    prompt_hash: str
    output_schema_version: str
    retrieval_pack_id: UUID7 | None = None
    tool_call_ids: tuple[UUID7, ...] = ()
    input_data_classes: tuple[DataClass, ...]
    route_policy: str
    started_at: AwareDatetime
    completed_at: AwareDatetime | None = None
    usage_and_cost: ModelUsage
    output_ref: str | None = None
    validation_result: str
    fallback_chain: tuple[str, ...] = ()
    user_feedback_refs: tuple[UUID7, ...] = ()
