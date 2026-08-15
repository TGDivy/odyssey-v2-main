from datetime import UTC, datetime, timedelta

from odyssey.decision.consequences import (
    CausalStatus,
    ConsequenceContext,
    ConsequencePolicy,
    DependencyGraph,
    DependencyRule,
    DirectEffect,
    HorizonBucket,
    MagnitudeBand,
    RelationDirection,
    derive_consequences,
)
from odyssey.decision.models import AccumulationModel, ConsequenceDirection
from odyssey.domain.common import new_uuid7

NOW = datetime(2026, 8, 15, 12, tzinfo=UTC)


def context(**overrides: object) -> ConsequenceContext:
    values: dict[str, object] = {
        "now": NOW,
        "latest_relevant_at": NOW + timedelta(days=365),
        "input_quality": {"sleep_opportunity": 1, "alertness": 1, "practice": 1},
        "model_calibration": {"alertness": 1, "practice": 1},
        "season_relevance": {"practice": 1},
        "state_irreversibility": {"practice": 0.8},
        "default_input_quality": 1,
        "default_model_calibration": 1,
    }
    values.update(overrides)
    return ConsequenceContext.model_validate(values)


def direct(**overrides: object) -> DirectEffect:
    values: dict[str, object] = {
        "affected_state": "sleep_opportunity",
        "direction": ConsequenceDirection.HARMFUL,
        "magnitude": MagnitudeBand.HIGH,
        "probability": 0.9,
        "uncertainty": 0.1,
        "effect_at": NOW + timedelta(hours=2),
        "causal_status": CausalStatus.CAUSAL,
        "evidence_refs": (new_uuid7(),),
        "input_keys": ("sleep_opportunity",),
        "method_version": "direct-sleep-1",
    }
    values.update(overrides)
    return DirectEffect.model_validate(values)


def rule(rule_id: str, source: str, target: str, **overrides: object) -> DependencyRule:
    values: dict[str, object] = {
        "rule_id": rule_id,
        "source_state_type": source,
        "target_state_type": target,
        "direction": RelationDirection.POSITIVE,
        "magnitude_multiplier": 0.8,
        "transition_probability": 0.8,
        "lag": timedelta(hours=10),
        "relation_confidence": 0.9,
        "applicability": 0.9,
        "causal_status": CausalStatus.ASSOCIATIONAL,
        "evidence_refs": (new_uuid7(),),
        "method_version": f"{rule_id}-v1",
    }
    values.update(overrides)
    return DependencyRule.model_validate(values)


def test_propagates_bounded_paths_and_preserves_causal_status() -> None:
    graph = DependencyGraph(
        rules=(
            rule(
                "sleep-alertness",
                "sleep_opportunity",
                "alertness",
                lag=timedelta(hours=12),
            ),
            rule(
                "alertness-practice",
                "alertness",
                "practice",
                lag=timedelta(hours=14),
                causal_status=CausalStatus.HYPOTHESIZED,
            ),
        )
    )
    result = derive_consequences(
        action_type="late_bedtime",
        direct_effects=(direct(),),
        context=context(),
        graph=graph,
    )

    by_state = {item.affected_state: item for item in result.consequences}
    assert set(by_state) == {"sleep_opportunity", "alertness", "practice"}
    assert by_state["sleep_opportunity"].horizon is HorizonBucket.IMMEDIATE
    assert by_state["alertness"].horizon is HorizonBucket.TOMORROW
    assert by_state["practice"].causal_status is CausalStatus.HYPOTHESIZED
    assert by_state["practice"].edge_causal_statuses == (
        CausalStatus.CAUSAL,
        CausalStatus.ASSOCIATIONAL,
        CausalStatus.HYPOTHESIZED,
    )
    assert by_state["practice"].rule_path == (
        "sleep-alertness",
        "alertness-practice",
    )


def test_cycle_without_accumulation_model_is_not_followed() -> None:
    result = derive_consequences(
        action_type="action",
        direct_effects=(direct(affected_state="a"),),
        context=context(),
        graph=DependencyGraph(
            rules=(
                rule("a-b", "a", "b"),
                rule("b-a", "b", "a", accumulation_model=AccumulationModel.NONE),
            )
        ),
    )

    assert {item.affected_state for item in result.consequences} == {"a", "b"}
    assert result.paths_examined == 2


def test_accumulation_cycle_is_allowed_once_and_still_bounded() -> None:
    result = derive_consequences(
        action_type="action",
        direct_effects=(direct(affected_state="repetition"),),
        context=context(),
        graph=DependencyGraph(
            rules=(
                rule(
                    "repeat",
                    "repetition",
                    "repetition",
                    accumulation_model=AccumulationModel.COUNT,
                    lag=timedelta(days=1),
                ),
            )
        ),
        policy=ConsequencePolicy(max_depth=10),
    )

    assert result.paths_examined == 2
    assert sum(item.supporting_path_count for item in result.consequences) == 2


def test_high_uncertainty_nonmaterial_effect_is_suppressed() -> None:
    result = derive_consequences(
        action_type="action",
        direct_effects=(
            direct(
                magnitude=MagnitudeBand.LOW,
                uncertainty=0.95,
                input_keys=(),
            ),
        ),
        context=context(default_input_quality=0.1),
        graph=DependencyGraph(rules=()),
    )

    assert result.consequences == ()


def test_material_effect_survives_high_uncertainty_with_uncertainty_visible() -> None:
    result = derive_consequences(
        action_type="action",
        direct_effects=(direct(magnitude=MagnitudeBand.HIGH, uncertainty=0.95),),
        context=context(),
        graph=DependencyGraph(rules=()),
    )

    assert len(result.consequences) == 1
    assert result.consequences[0].uncertainty >= 0.95


def test_correlated_paths_collapse_without_adding_scores() -> None:
    first_evidence = new_uuid7()
    second_evidence = new_uuid7()
    result = derive_consequences(
        action_type="action",
        direct_effects=(
            direct(evidence_refs=(first_evidence,), correlation_group="same-signal"),
            direct(
                probability=0.6,
                evidence_refs=(second_evidence,),
                correlation_group="same-signal",
            ),
        ),
        context=context(),
        graph=DependencyGraph(rules=()),
    )

    assert len(result.consequences) == 1
    collapsed = result.consequences[0]
    assert collapsed.supporting_path_count == 2
    assert collapsed.probability == 0.9
    assert set(collapsed.evidence_refs) == {first_evidence, second_evidence}


def test_path_and_result_limits_report_truncation() -> None:
    graph = DependencyGraph(
        rules=tuple(
            rule(f"branch-{index}", "sleep_opportunity", f"branch-{index}")
            for index in range(5)
        )
    )
    result = derive_consequences(
        action_type="action",
        direct_effects=(direct(),),
        context=context(),
        graph=graph,
        policy=ConsequencePolicy(max_paths_examined=3, max_results=2),
    )

    assert result.truncated is True
    assert result.paths_examined == 3
    assert len(result.consequences) <= 2


def test_conditions_time_bounds_and_disabled_rules_are_respected() -> None:
    result = derive_consequences(
        action_type="action",
        direct_effects=(direct(),),
        context=context(
            latest_relevant_at=NOW + timedelta(days=2),
            active_conditions=frozenset({"travel"}),
        ),
        graph=DependencyGraph(
            rules=(
                rule(
                    "condition-missing",
                    "sleep_opportunity",
                    "missing",
                    required_conditions=("at_home",),
                ),
                rule(
                    "disabled",
                    "sleep_opportunity",
                    "disabled",
                    allowed_for_consequence_reasoning=False,
                ),
                rule(
                    "too-late",
                    "sleep_opportunity",
                    "future",
                    lag=timedelta(days=10),
                ),
                rule(
                    "travel",
                    "sleep_opportunity",
                    "travel_effect",
                    required_conditions=("travel",),
                ),
            )
        ),
    )

    assert {item.affected_state for item in result.consequences} == {
        "sleep_opportunity",
        "travel_effect",
    }


def test_negative_dependency_inverts_direction() -> None:
    result = derive_consequences(
        action_type="action",
        direct_effects=(direct(direction=ConsequenceDirection.BENEFICIAL),),
        context=context(),
        graph=DependencyGraph(
            rules=(
                rule(
                    "inverse",
                    "sleep_opportunity",
                    "risk",
                    direction=RelationDirection.NEGATIVE,
                ),
            )
        ),
    )

    by_state = {item.affected_state: item for item in result.consequences}
    assert by_state["risk"].direction is ConsequenceDirection.HARMFUL
