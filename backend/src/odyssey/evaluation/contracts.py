"""Strict contracts for the repository evaluation corpus."""

from enum import StrEnum
from typing import Literal

from pydantic import AwareDatetime, Field, JsonValue, model_validator

from odyssey.domain.common import StrictModel


class EvalAuthorityLimit(StrEnum):
    OBSERVE = "observe"
    INFORM = "inform"
    RECOMMEND = "recommend"
    PREPARE = "prepare"
    EXECUTE_REVERSIBLE = "execute_reversible"
    COMMIT_EXTERNAL = "commit_external"


class EvalSourceKind(StrEnum):
    SYNTHETIC = "synthetic"
    RECONSTRUCTED = "reconstructed"
    OWNER_APPROVED_HISTORICAL = "owner_approved_historical"
    REGRESSION = "regression"


class GoldenReplayAdapter(StrEnum):
    AUTHORITY_POLICY = "authority_policy"
    DAY_ALIGNMENT = "day_alignment"
    INTENT_POLICY = "intent_policy"
    PATTERN_PROMOTION = "pattern_promotion"
    RECOMMENDATION_STRENGTH = "recommendation_strength"
    REENTRY = "reentry"


class EvalProvenance(StrictModel):
    source_kind: EvalSourceKind
    source_id: str = Field(min_length=1, max_length=200)
    authored_at: AwareDatetime
    spec_refs: tuple[str, ...] = Field(min_length=1)
    notes: str | None = Field(default=None, max_length=1_000)


class EvalCase(StrictModel):
    case_id: str = Field(pattern=r"^[a-z0-9][a-z0-9._-]{2,119}$")
    scenario_time: AwareDatetime
    frozen_context_snapshot: dict[str, JsonValue]
    permitted_data_scope: tuple[str, ...] = Field(min_length=1)
    question_or_trigger: str = Field(min_length=1, max_length=2_000)
    expected_invariants: tuple[str, ...] = Field(min_length=1)
    acceptable_outputs: tuple[str, ...] = Field(min_length=1)
    unacceptable_outputs: tuple[str, ...] = Field(min_length=1)
    evidence_requirements: tuple[str, ...] = Field(min_length=1)
    authority_limit: EvalAuthorityLimit
    evaluator_rubric: tuple[str, ...] = Field(min_length=1)
    provenance: EvalProvenance
    tags: tuple[str, ...] = ()

    @model_validator(mode="after")
    def validate_case(self) -> "EvalCase":
        required_context_keys = {"context_version", "facts", "missing_or_denied"}
        if not required_context_keys.issubset(self.frozen_context_snapshot):
            raise ValueError("frozen context must declare version, facts, and missing/denied data")
        sequence_fields = (
            self.permitted_data_scope,
            self.expected_invariants,
            self.acceptable_outputs,
            self.unacceptable_outputs,
            self.evidence_requirements,
            self.evaluator_rubric,
            self.tags,
        )
        if any(len(values) != len(set(values)) for values in sequence_fields):
            raise ValueError("evaluation case lists must not contain duplicates")
        if set(self.acceptable_outputs) & set(self.unacceptable_outputs):
            raise ValueError("acceptable and unacceptable outputs must be disjoint")
        return self


class EvalCaseSet(StrictModel):
    case_version: str = Field(min_length=1, max_length=100)
    cases: tuple[EvalCase, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def validate_cases(self) -> "EvalCaseSet":
        identifiers = tuple(item.case_id for item in self.cases)
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("evaluation case IDs must be unique")
        return self


class RubricDimension(StrictModel):
    dimension_id: str = Field(pattern=r"^[a-z0-9][a-z0-9._-]{2,79}$")
    description: str = Field(min_length=1, max_length=1_000)
    weight: float = Field(gt=0, le=10)
    score_anchors: dict[Literal["0", "1", "2", "3", "4"], str]
    hard_fail_if: tuple[str, ...] = ()

    @model_validator(mode="after")
    def validate_score_anchors(self) -> "RubricDimension":
        if set(self.score_anchors) != {"0", "1", "2", "3", "4"}:
            raise ValueError("rubric dimensions require score anchors from 0 through 4")
        if any(not anchor.strip() for anchor in self.score_anchors.values()):
            raise ValueError("rubric score anchors must not be blank")
        return self


class EvalRubric(StrictModel):
    rubric_id: str = Field(pattern=r"^[a-z0-9][a-z0-9._-]{2,79}$")
    title: str = Field(min_length=1, max_length=200)
    purpose: str = Field(min_length=1, max_length=1_000)
    dimensions: tuple[RubricDimension, ...] = Field(min_length=1)
    minimum_weighted_score: float = Field(ge=0, le=4)
    required_for_high_stakes: bool = False

    @model_validator(mode="after")
    def validate_dimensions(self) -> "EvalRubric":
        identifiers = tuple(item.dimension_id for item in self.dimensions)
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("rubric dimension IDs must be unique")
        return self


class EvalRubricSet(StrictModel):
    rubric_version: str = Field(min_length=1, max_length=100)
    rubrics: tuple[EvalRubric, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def validate_rubrics(self) -> "EvalRubricSet":
        identifiers = tuple(item.rubric_id for item in self.rubrics)
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("rubric IDs must be unique")
        return self


class GoldenReplayCase(StrictModel):
    case_id: str = Field(pattern=r"^[a-z0-9][a-z0-9._-]{2,119}$")
    adapter: GoldenReplayAdapter
    description: str = Field(min_length=1, max_length=1_000)
    input: dict[str, JsonValue]
    expected_output: dict[str, JsonValue]
    expected_invariants: tuple[str, ...] = Field(min_length=1)
    spec_refs: tuple[str, ...] = Field(min_length=1)


class GoldenReplaySet(StrictModel):
    replay_version: str = Field(min_length=1, max_length=100)
    cases: tuple[GoldenReplayCase, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def validate_cases(self) -> "GoldenReplaySet":
        identifiers = tuple(item.case_id for item in self.cases)
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("golden replay case IDs must be unique")
        return self


class EvalCorpusFile(StrictModel):
    path: str = Field(pattern=r"^evals/[a-z0-9_./-]+\.json$")
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


class EvalCorpusManifest(StrictModel):
    corpus_version: str = Field(min_length=1, max_length=100)
    scenario_case_count: int = Field(ge=1)
    golden_replay_count: int = Field(ge=1)
    rubric_count: int = Field(ge=1)
    files: tuple[EvalCorpusFile, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def validate_files(self) -> "EvalCorpusManifest":
        paths = tuple(item.path for item in self.files)
        if len(paths) != len(set(paths)):
            raise ValueError("evaluation corpus paths must be unique")
        return self
