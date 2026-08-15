"""API contracts for deliberate owner acceptance of orientation state."""

from enum import StrEnum

from pydantic import AwareDatetime, Field, JsonValue, model_validator

from odyssey.domain.common import UUID7, StrictModel
from odyssey.domain.life import CharterVersion, LifeStageVersion, Season


class LifeModelKind(StrEnum):
    CHARTER = "charter"
    LIFE_STAGE = "life_stage"
    SEASON = "season"


class AcceptanceMethod(StrEnum):
    OWNER_AUTHORED = "owner_authored"
    OWNER_REVIEWED_ASSISTED = "owner_reviewed_assisted"
    OWNER_APPROVED_IMPORT = "owner_approved_import"


class CharterRevisionRequest(StrictModel):
    event_id: UUID7
    device_id: UUID7
    expected_current_version_id: UUID7 | None = None
    acceptance_method: AcceptanceMethod
    charter: CharterVersion


class LifeStageRevisionRequest(StrictModel):
    event_id: UUID7
    device_id: UUID7
    expected_current_version_id: UUID7 | None = None
    acceptance_method: AcceptanceMethod
    accepted_at: AwareDatetime
    life_stage: LifeStageVersion


class SeasonRevisionRequest(StrictModel):
    event_id: UUID7
    device_id: UUID7
    season_id: UUID7
    expected_current_version_id: UUID7 | None = None
    acceptance_method: AcceptanceMethod
    accepted_at: AwareDatetime
    season: Season

    @model_validator(mode="after")
    def validate_creation_source(self) -> "SeasonRevisionRequest":
        expected_method = {
            "user": AcceptanceMethod.OWNER_AUTHORED,
            "assisted": AcceptanceMethod.OWNER_REVIEWED_ASSISTED,
            "imported": AcceptanceMethod.OWNER_APPROVED_IMPORT,
        }[self.season.created_from.value]
        if self.acceptance_method is not expected_method:
            raise ValueError("season created_from must match its owner acceptance method")
        return self


class LifeModelVersionEnvelope(StrictModel):
    kind: LifeModelKind
    version_id: UUID7
    logical_id: UUID7
    version_number: int = Field(ge=1)
    acceptance_sequence: int = Field(ge=1)
    event_id: UUID7
    ledger_sequence: int = Field(ge=1)
    supersedes_version_id: UUID7 | None
    status: str | None
    acceptance_method: AcceptanceMethod
    accepted_at: AwareDatetime
    content_hash: str = Field(pattern=r"^[0-9a-f]{64}$")
    document: dict[str, JsonValue]


class LifeModelRevisionReceipt(StrictModel):
    version: LifeModelVersionEnvelope
    event_id: UUID7
    ledger_sequence: int = Field(ge=1)
    created: bool
    warnings: tuple[str, ...] = ()
    policy_version: str


class CurrentOrientationResponse(StrictModel):
    as_of: AwareDatetime
    charter: LifeModelVersionEnvelope | None
    life_stage: LifeModelVersionEnvelope | None
    season: LifeModelVersionEnvelope | None
    policy_version: str


class LifeModelHistoryResponse(StrictModel):
    kind: LifeModelKind
    versions: tuple[LifeModelVersionEnvelope, ...]
    policy_version: str
