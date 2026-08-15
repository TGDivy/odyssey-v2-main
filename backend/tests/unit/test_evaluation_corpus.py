import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from odyssey.evaluation.contracts import (
    EvalCaseSet,
    EvalRubricSet,
    GoldenReplayAdapter,
    GoldenReplaySet,
    RubricDimension,
)
from odyssey.evaluation.replay import assert_golden_invariants, execute_golden_replay

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SCENARIO_PATH = REPOSITORY_ROOT / "evals/cases/scenario-stress.v1.json"
RUBRIC_PATH = REPOSITORY_ROOT / "evals/rubrics/core.v1.json"
GOLDEN_PATH = REPOSITORY_ROOT / "evals/golden/deterministic-policies.v1.json"


def test_repository_evaluation_corpus_is_complete_and_replayable() -> None:
    scenarios = EvalCaseSet.model_validate_json(SCENARIO_PATH.read_text())
    rubrics = EvalRubricSet.model_validate_json(RUBRIC_PATH.read_text())
    golden = GoldenReplaySet.model_validate_json(GOLDEN_PATH.read_text())

    assert {case.case_id for case in scenarios.cases} == {
        f"stress-48.{index:02d}-v1" for index in range(1, 21)
    }
    assert len(rubrics.rubrics) == 8
    assert {case.adapter for case in golden.cases} == set(GoldenReplayAdapter)
    for case in golden.cases:
        output = execute_golden_replay(case)
        assert output == case.expected_output
        assert_golden_invariants(case, output)


def test_rubric_dimension_requires_every_score_anchor() -> None:
    raw_dimension = json.loads(RUBRIC_PATH.read_text())["rubrics"][0]["dimensions"][0]
    raw_dimension["score_anchors"].pop("4")

    with pytest.raises(ValidationError, match="score anchors from 0 through 4"):
        RubricDimension.model_validate(raw_dimension)


def test_case_contract_rejects_duplicate_scope_entries() -> None:
    raw_case = json.loads(SCENARIO_PATH.read_text())["cases"][0]
    raw_case["permitted_data_scope"].append(raw_case["permitted_data_scope"][0])

    with pytest.raises(ValidationError, match="must not contain duplicates"):
        EvalCaseSet.model_validate({"case_version": "invalid", "cases": [raw_case]})


def test_unknown_golden_invariant_fails_closed() -> None:
    golden = GoldenReplaySet.model_validate_json(GOLDEN_PATH.read_text())
    case = golden.cases[0].model_copy(update={"expected_invariants": ("unknown-invariant",)})

    with pytest.raises(ValueError, match="unknown golden invariant"):
        assert_golden_invariants(case, execute_golden_replay(case))
