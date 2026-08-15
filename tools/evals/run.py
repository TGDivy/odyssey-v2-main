#!/usr/bin/env python3
"""Validate the evaluation corpus and replay deterministic golden cases."""

import argparse
import json
from hashlib import sha256
from pathlib import Path
from typing import Any

from odyssey.evaluation.contracts import (
    EvalAuthorityLimit,
    EvalCaseSet,
    EvalCorpusManifest,
    EvalRubricSet,
    EvalSourceKind,
    GoldenReplayAdapter,
    GoldenReplaySet,
)
from odyssey.evaluation.replay import assert_golden_invariants, execute_golden_replay

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCENARIO_PATH = REPOSITORY_ROOT / "evals/cases/scenario-stress.v1.json"
RUBRIC_PATH = REPOSITORY_ROOT / "evals/rubrics/core.v1.json"
GOLDEN_PATH = REPOSITORY_ROOT / "evals/golden/deterministic-policies.v1.json"
MANIFEST_PATH = REPOSITORY_ROOT / "evals/manifest.v1.json"
CORPUS_PATHS = (SCENARIO_PATH, RUBRIC_PATH, GOLDEN_PATH)

EXPECTED_STRESS_CASES = {f"stress-48.{index:02d}-v1": f"48.{index}" for index in range(1, 21)}
REQUIRED_RUBRICS = {
    "autonomy-and-authority",
    "evidence-and-uncertainty",
    "non-moralizing-tone",
    "privacy-and-data-minimization",
    "provenance-and-correctability",
    "resilience-and-offline-behavior",
    "temporal-and-context-correctness",
    "usefulness-and-restraint",
}


class EvaluationCorpusError(RuntimeError):
    pass


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_bytes())
    except (OSError, json.JSONDecodeError) as error:
        relative_path = path.relative_to(REPOSITORY_ROOT)
        raise EvaluationCorpusError(f"could not load {relative_path}") from error


def validate_corpus() -> dict[str, object]:
    scenarios = EvalCaseSet.model_validate(load_json(SCENARIO_PATH))
    rubrics = EvalRubricSet.model_validate(load_json(RUBRIC_PATH))
    golden = GoldenReplaySet.model_validate(load_json(GOLDEN_PATH))
    manifest = EvalCorpusManifest.model_validate(load_json(MANIFEST_PATH))

    case_by_id = {case.case_id: case for case in scenarios.cases}
    if set(case_by_id) != set(EXPECTED_STRESS_CASES):
        missing = sorted(set(EXPECTED_STRESS_CASES) - set(case_by_id))
        extra = sorted(set(case_by_id) - set(EXPECTED_STRESS_CASES))
        raise EvaluationCorpusError(f"stress scenario IDs differ; missing={missing}, extra={extra}")
    rubric_ids = {rubric.rubric_id for rubric in rubrics.rubrics}
    if rubric_ids != REQUIRED_RUBRICS:
        raise EvaluationCorpusError("core rubric IDs differ from the required evaluation layers")
    for case_id, spec_ref in EXPECTED_STRESS_CASES.items():
        case = case_by_id[case_id]
        if spec_ref not in case.provenance.spec_refs:
            raise EvaluationCorpusError(f"{case_id} does not cite master specification {spec_ref}")
        if case.provenance.source_kind is not EvalSourceKind.SYNTHETIC:
            raise EvaluationCorpusError(f"{case_id} must remain synthetic in source control")
        unknown_rubrics = set(case.evaluator_rubric) - rubric_ids
        if unknown_rubrics:
            raise EvaluationCorpusError(f"{case_id} references unknown rubrics: {unknown_rubrics}")
        if _authority_rank(case.authority_limit) > _authority_rank(EvalAuthorityLimit.PREPARE):
            raise EvaluationCorpusError(f"{case_id} grants execution authority in an eval case")

    replay_adapters = {case.adapter for case in golden.cases}
    if replay_adapters != set(GoldenReplayAdapter):
        raise EvaluationCorpusError("golden set must cover every deterministic replay adapter")

    replayed = 0
    for replay_case in golden.cases:
        actual = execute_golden_replay(replay_case)
        if actual != replay_case.expected_output:
            expected = _canonical_json(replay_case.expected_output)
            observed = _canonical_json(actual)
            detail = f"expected={expected}\nobserved={observed}"
            raise EvaluationCorpusError(f"golden replay drift for {replay_case.case_id}\n{detail}")
        assert_golden_invariants(replay_case, actual)
        replayed += 1

    manifest_files = {item.path: item.sha256 for item in manifest.files}
    expected_manifest_paths = {str(path.relative_to(REPOSITORY_ROOT)) for path in CORPUS_PATHS}
    if set(manifest_files) != expected_manifest_paths:
        raise EvaluationCorpusError("evaluation manifest file inventory differs")
    for path in CORPUS_PATHS:
        relative = str(path.relative_to(REPOSITORY_ROOT))
        if sha256(path.read_bytes()).hexdigest() != manifest_files[relative]:
            raise EvaluationCorpusError(f"evaluation corpus digest drift: {relative}")
    if manifest.scenario_case_count != len(scenarios.cases):
        raise EvaluationCorpusError("evaluation scenario count differs from manifest")
    if manifest.golden_replay_count != len(golden.cases):
        raise EvaluationCorpusError("golden replay count differs from manifest")
    if manifest.rubric_count != len(rubrics.rubrics):
        raise EvaluationCorpusError("rubric count differs from manifest")

    corpus_digest = sha256(
        "".join(manifest_files[path] for path in sorted(manifest_files)).encode()
    ).hexdigest()
    return {
        "corpus_version": manifest.corpus_version,
        "scenario_cases": len(scenarios.cases),
        "rubrics": len(rubrics.rubrics),
        "golden_replays": replayed,
        "corpus_sha256": corpus_digest,
    }


def _authority_rank(value: EvalAuthorityLimit) -> int:
    return tuple(EvalAuthorityLimit).index(value)


def _canonical_json(value: object) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Validate without writing files.")
    parser.parse_args()
    report = validate_corpus()
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
