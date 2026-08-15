"""Bounded deterministic temporal-consequence propagation."""

from collections import defaultdict, deque
from datetime import datetime, timedelta
from enum import StrEnum

from pydantic import AwareDatetime, Field, model_validator

from odyssey.decision.models import AccumulationModel, ConsequenceDirection
from odyssey.domain.common import UUID7, StrictModel


class CausalStatus(StrEnum):
    CAUSAL = "causal"
    ASSOCIATIONAL = "associational"
    HYPOTHESIZED = "hypothesized"
    UNKNOWN = "unknown"


class RelationDirection(StrEnum):
    POSITIVE = "positive"
    NEGATIVE = "negative"
    NON_MONOTONIC = "non_monotonic"
    UNKNOWN = "unknown"


class MagnitudeBand(StrEnum):
    NEGLIGIBLE = "negligible"
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    VERY_HIGH = "very_high"


class HorizonBucket(StrEnum):
    IMMEDIATE = "immediate"
    TOMORROW = "tomorrow"
    NEAR = "near"
    BLOCK = "block"
    SEASON = "season"
    LONG_TERM = "long_term"


class DirectEffect(StrictModel):
    affected_state: str = Field(min_length=1, max_length=200)
    direction: ConsequenceDirection
    magnitude: MagnitudeBand
    probability: float = Field(ge=0, le=1)
    uncertainty: float = Field(ge=0, le=1)
    effect_at: AwareDatetime
    charter_relevance: float = Field(default=0.5, ge=0, le=1)
    irreversibility: float = Field(default=0.5, ge=0, le=1)
    accumulation_modifier: float = Field(default=1, ge=0, le=2)
    causal_status: CausalStatus
    evidence_refs: tuple[UUID7, ...] = ()
    assumptions: tuple[str, ...] = ()
    correlation_group: str | None = None
    input_keys: tuple[str, ...] = ()
    method_version: str


class DependencyRule(StrictModel):
    rule_id: str = Field(min_length=1, max_length=200)
    source_state_type: str = Field(min_length=1, max_length=200)
    target_state_type: str = Field(min_length=1, max_length=200)
    direction: RelationDirection
    magnitude_multiplier: float = Field(gt=0, le=2)
    transition_probability: float = Field(ge=0, le=1)
    lag: timedelta = Field(ge=timedelta(0))
    relation_confidence: float = Field(ge=0, le=1)
    applicability: float = Field(ge=0, le=1)
    causal_status: CausalStatus
    accumulation_model: AccumulationModel = AccumulationModel.NONE
    evidence_refs: tuple[UUID7, ...] = ()
    required_conditions: tuple[str, ...] = ()
    allowed_for_consequence_reasoning: bool = True
    correlation_group: str | None = None
    method_version: str


class DependencyGraph(StrictModel):
    rules: tuple[DependencyRule, ...]

    @model_validator(mode="after")
    def validate_unique_rule_ids(self) -> "DependencyGraph":
        rule_ids = [rule.rule_id for rule in self.rules]
        if len(rule_ids) != len(set(rule_ids)):
            raise ValueError("dependency rule ids must be unique")
        return self


class ConsequenceContext(StrictModel):
    now: AwareDatetime
    latest_relevant_at: AwareDatetime
    active_conditions: frozenset[str] = frozenset()
    input_quality: dict[str, float] = Field(default_factory=dict)
    model_calibration: dict[str, float] = Field(default_factory=dict)
    season_relevance: dict[str, float] = Field(default_factory=dict)
    state_irreversibility: dict[str, float] = Field(default_factory=dict)
    default_input_quality: float = Field(default=0.5, ge=0, le=1)
    default_model_calibration: float = Field(default=0.5, ge=0, le=1)

    @model_validator(mode="after")
    def validate_context(self) -> "ConsequenceContext":
        if self.latest_relevant_at <= self.now:
            raise ValueError("latest_relevant_at must be after now")
        for values in (
            self.input_quality,
            self.model_calibration,
            self.season_relevance,
            self.state_irreversibility,
        ):
            if any(value < 0 or value > 1 for value in values.values()):
                raise ValueError(
                    "context quality and relevance values must be between zero and one"
                )
        return self


class ConsequencePolicy(StrictModel):
    max_depth: int = Field(default=4, ge=0, le=12)
    max_paths_examined: int = Field(default=256, ge=1, le=10_000)
    max_results: int = Field(default=25, ge=1, le=500)
    too_high_uncertainty: float = Field(default=0.8, ge=0, le=1)
    immediate_horizon: timedelta = Field(default=timedelta(hours=12), gt=timedelta(0))
    tomorrow_horizon: timedelta = Field(default=timedelta(hours=36), gt=timedelta(0))
    near_horizon: timedelta = Field(default=timedelta(days=7), gt=timedelta(0))
    block_horizon: timedelta = Field(default=timedelta(days=42), gt=timedelta(0))
    season_horizon: timedelta = Field(default=timedelta(days=180), gt=timedelta(0))
    policy_version: str = "consequence-policy-1.0"

    @model_validator(mode="after")
    def validate_horizons(self) -> "ConsequencePolicy":
        horizons = (
            self.immediate_horizon,
            self.tomorrow_horizon,
            self.near_horizon,
            self.block_horizon,
            self.season_horizon,
        )
        if tuple(sorted(horizons)) != horizons:
            raise ValueError("consequence horizons must be strictly ordered")
        if len(set(horizons)) != len(horizons):
            raise ValueError("consequence horizons must be strictly ordered")
        return self


class DerivedConsequence(StrictModel):
    affected_state: str
    direction: ConsequenceDirection
    magnitude: MagnitudeBand
    probability: float = Field(ge=0, le=1)
    uncertainty: float = Field(ge=0, le=1)
    effect_at: AwareDatetime
    horizon: HorizonBucket
    charter_relevance: float = Field(ge=0, le=1)
    irreversibility: float = Field(ge=0, le=1)
    causal_status: CausalStatus
    state_path: tuple[str, ...]
    rule_path: tuple[str, ...]
    edge_causal_statuses: tuple[CausalStatus, ...]
    evidence_refs: tuple[UUID7, ...]
    assumptions: tuple[str, ...]
    method_versions: tuple[str, ...]
    correlation_group: str | None = None
    supporting_path_count: int = Field(default=1, ge=1)
    rank_score: float = Field(ge=0)
    policy_version: str


class ConsequenceDerivation(StrictModel):
    consequences: tuple[DerivedConsequence, ...]
    paths_examined: int = Field(ge=0)
    truncated: bool
    policy_version: str


class _Path(StrictModel):
    affected_state: str
    direction: ConsequenceDirection
    magnitude_value: float = Field(ge=0, le=4)
    probability: float = Field(ge=0, le=1)
    uncertainty: float = Field(ge=0, le=1)
    effect_at: AwareDatetime
    charter_relevance: float = Field(ge=0, le=1)
    irreversibility: float = Field(ge=0, le=1)
    accumulation_modifier: float = Field(ge=0, le=2)
    causal_status: CausalStatus
    state_path: tuple[str, ...]
    rule_path: tuple[str, ...]
    edge_causal_statuses: tuple[CausalStatus, ...]
    evidence_refs: tuple[UUID7, ...]
    assumptions: tuple[str, ...]
    method_versions: tuple[str, ...]
    correlation_group: str | None = None
    depth: int = Field(ge=0)


_MAGNITUDE_VALUE = {
    MagnitudeBand.NEGLIGIBLE: 0.25,
    MagnitudeBand.LOW: 1.0,
    MagnitudeBand.MEDIUM: 2.0,
    MagnitudeBand.HIGH: 3.0,
    MagnitudeBand.VERY_HIGH: 4.0,
}
_CAUSAL_RANK = {
    CausalStatus.UNKNOWN: 0,
    CausalStatus.HYPOTHESIZED: 1,
    CausalStatus.ASSOCIATIONAL: 2,
    CausalStatus.CAUSAL: 3,
}


def derive_consequences(
    *,
    action_type: str,
    direct_effects: tuple[DirectEffect, ...],
    context: ConsequenceContext,
    graph: DependencyGraph,
    policy: ConsequencePolicy | None = None,
) -> ConsequenceDerivation:
    active_policy = policy or ConsequencePolicy()
    outgoing: dict[str, list[DependencyRule]] = defaultdict(list)
    for rule in graph.rules:
        outgoing[rule.source_state_type].append(rule)
    for rules in outgoing.values():
        rules.sort(key=lambda rule: rule.rule_id)

    frontier: deque[_Path] = deque()
    for effect in sorted(
        direct_effects,
        key=lambda item: (item.effect_at, item.affected_state, item.direction.value),
    ):
        if effect.effect_at < context.now or effect.effect_at > context.latest_relevant_at:
            continue
        input_quality = _minimum_quality(effect.input_keys, context)
        uncertainty = _combine_uncertainty(effect.uncertainty, input_quality)
        frontier.append(
            _Path(
                affected_state=effect.affected_state,
                direction=effect.direction,
                magnitude_value=_MAGNITUDE_VALUE[effect.magnitude],
                probability=effect.probability,
                uncertainty=uncertainty,
                effect_at=effect.effect_at,
                charter_relevance=effect.charter_relevance,
                irreversibility=effect.irreversibility,
                accumulation_modifier=effect.accumulation_modifier,
                causal_status=effect.causal_status,
                state_path=(action_type, effect.affected_state),
                rule_path=(),
                edge_causal_statuses=(effect.causal_status,),
                evidence_refs=effect.evidence_refs,
                assumptions=effect.assumptions,
                method_versions=(effect.method_version,),
                correlation_group=effect.correlation_group,
                depth=0,
            )
        )

    candidates: list[DerivedConsequence] = []
    paths_examined = 0
    truncated = False
    while frontier:
        if paths_examined >= active_policy.max_paths_examined:
            truncated = True
            break
        path = frontier.popleft()
        paths_examined += 1
        material = _is_material(path.magnitude_value, path.uncertainty, active_policy)
        if material:
            candidates.append(_to_derived(path, context, active_policy))
        if not material or path.depth >= active_policy.max_depth:
            continue

        for rule in outgoing.get(path.affected_state, ()):
            if not rule.allowed_for_consequence_reasoning:
                continue
            if not set(rule.required_conditions).issubset(context.active_conditions):
                continue
            if _cycle_disallowed(path, rule):
                continue
            propagated = _propagate(path, rule, context)
            if propagated.effect_at > context.latest_relevant_at:
                continue
            frontier.append(propagated)

    collapsed = _collapse_correlated_paths(candidates)
    ranked = sorted(
        collapsed,
        key=lambda item: (-item.rank_score, item.effect_at, item.affected_state),
    )
    if len(ranked) > active_policy.max_results:
        truncated = True
        ranked = ranked[: active_policy.max_results]
    return ConsequenceDerivation(
        consequences=tuple(ranked),
        paths_examined=paths_examined,
        truncated=truncated,
        policy_version=active_policy.policy_version,
    )


def _propagate(
    path: _Path,
    rule: DependencyRule,
    context: ConsequenceContext,
) -> _Path:
    quality = min(
        context.input_quality.get(path.affected_state, context.default_input_quality),
        context.input_quality.get(rule.target_state_type, context.default_input_quality),
    )
    calibration = context.model_calibration.get(
        rule.target_state_type,
        context.default_model_calibration,
    )
    edge_confidence = min(rule.relation_confidence, rule.applicability, quality, calibration)
    uncertainty = _combine_uncertainty(path.uncertainty, edge_confidence)
    magnitude = min(4.0, path.magnitude_value * rule.magnitude_multiplier)
    effect_at = path.effect_at + rule.lag
    causal_status = min(
        (path.causal_status, rule.causal_status),
        key=_CAUSAL_RANK.__getitem__,
    )
    relevance = context.season_relevance.get(rule.target_state_type, path.charter_relevance)
    irreversibility = context.state_irreversibility.get(
        rule.target_state_type,
        path.irreversibility,
    )
    accumulation = path.accumulation_modifier
    if rule.accumulation_model is not AccumulationModel.NONE:
        accumulation = min(2.0, accumulation * 1.1)
    return _Path(
        affected_state=rule.target_state_type,
        direction=_propagated_direction(path.direction, rule.direction),
        magnitude_value=magnitude,
        probability=path.probability * rule.transition_probability,
        uncertainty=uncertainty,
        effect_at=effect_at,
        charter_relevance=relevance,
        irreversibility=irreversibility,
        accumulation_modifier=accumulation,
        causal_status=causal_status,
        state_path=(*path.state_path, rule.target_state_type),
        rule_path=(*path.rule_path, rule.rule_id),
        edge_causal_statuses=(*path.edge_causal_statuses, rule.causal_status),
        evidence_refs=_ordered_union(path.evidence_refs, rule.evidence_refs),
        assumptions=path.assumptions,
        method_versions=_ordered_union(path.method_versions, (rule.method_version,)),
        correlation_group=rule.correlation_group or path.correlation_group,
        depth=path.depth + 1,
    )


def _cycle_disallowed(path: _Path, rule: DependencyRule) -> bool:
    occurrences = path.state_path.count(rule.target_state_type)
    if occurrences == 0:
        return False
    if rule.accumulation_model is AccumulationModel.NONE:
        return True
    return occurrences >= 2 or path.rule_path.count(rule.rule_id) >= 1


def _to_derived(
    path: _Path,
    context: ConsequenceContext,
    policy: ConsequencePolicy,
) -> DerivedConsequence:
    horizon = _horizon(path.effect_at, context.now, policy)
    time_weight = {
        HorizonBucket.IMMEDIATE: 1.0,
        HorizonBucket.TOMORROW: 0.95,
        HorizonBucket.NEAR: 0.85,
        HorizonBucket.BLOCK: 0.7,
        HorizonBucket.SEASON: 0.55,
        HorizonBucket.LONG_TERM: 0.35,
    }[horizon]
    score = (
        path.magnitude_value
        * path.probability
        * time_weight
        * (0.5 + 0.5 * path.charter_relevance)
        * (0.5 + 0.5 * path.irreversibility)
        * path.accumulation_modifier
        * (1 - path.uncertainty)
    )
    return DerivedConsequence(
        affected_state=path.affected_state,
        direction=path.direction,
        magnitude=_magnitude_band(path.magnitude_value),
        probability=path.probability,
        uncertainty=path.uncertainty,
        effect_at=path.effect_at,
        horizon=horizon,
        charter_relevance=path.charter_relevance,
        irreversibility=path.irreversibility,
        causal_status=path.causal_status,
        state_path=path.state_path,
        rule_path=path.rule_path,
        edge_causal_statuses=path.edge_causal_statuses,
        evidence_refs=path.evidence_refs,
        assumptions=path.assumptions,
        method_versions=path.method_versions,
        correlation_group=path.correlation_group,
        rank_score=round(score, 8),
        policy_version=policy.policy_version,
    )


def _collapse_correlated_paths(
    candidates: list[DerivedConsequence],
) -> tuple[DerivedConsequence, ...]:
    groups: dict[
        tuple[str, ConsequenceDirection, HorizonBucket],
        list[DerivedConsequence],
    ] = defaultdict(list)
    for candidate in candidates:
        key = (candidate.affected_state, candidate.direction, candidate.horizon)
        groups[key].append(candidate)

    collapsed: list[DerivedConsequence] = []
    for group in groups.values():
        strongest = min(
            group,
            key=lambda item: (-item.rank_score, item.effect_at, item.rule_path),
        )
        causal_status = min(
            (item.causal_status for item in group),
            key=_CAUSAL_RANK.__getitem__,
        )
        collapsed.append(
            strongest.model_copy(
                update={
                    "causal_status": causal_status,
                    "evidence_refs": _ordered_union(
                        *(item.evidence_refs for item in group)
                    ),
                    "supporting_path_count": len(group),
                }
            )
        )
    return tuple(collapsed)


def _is_material(
    magnitude_value: float,
    uncertainty: float,
    policy: ConsequencePolicy,
) -> bool:
    return magnitude_value >= _MAGNITUDE_VALUE[MagnitudeBand.MEDIUM] or (
        uncertainty <= policy.too_high_uncertainty
        and magnitude_value >= _MAGNITUDE_VALUE[MagnitudeBand.LOW]
    )


def _minimum_quality(keys: tuple[str, ...], context: ConsequenceContext) -> float:
    if not keys:
        return context.default_input_quality
    return min(context.input_quality.get(key, context.default_input_quality) for key in keys)


def _combine_uncertainty(existing_uncertainty: float, added_confidence: float) -> float:
    combined_confidence = (1 - existing_uncertainty) * added_confidence
    return min(1.0, max(0.0, 1 - combined_confidence))


def _propagated_direction(
    current: ConsequenceDirection,
    relation: RelationDirection,
) -> ConsequenceDirection:
    if relation is RelationDirection.POSITIVE:
        return current
    if relation is RelationDirection.NEGATIVE:
        if current is ConsequenceDirection.BENEFICIAL:
            return ConsequenceDirection.HARMFUL
        if current is ConsequenceDirection.HARMFUL:
            return ConsequenceDirection.BENEFICIAL
        return current
    return ConsequenceDirection.MIXED


def _magnitude_band(value: float) -> MagnitudeBand:
    if value >= 3.5:
        return MagnitudeBand.VERY_HIGH
    if value >= 2.5:
        return MagnitudeBand.HIGH
    if value >= 1.5:
        return MagnitudeBand.MEDIUM
    if value >= 0.75:
        return MagnitudeBand.LOW
    return MagnitudeBand.NEGLIGIBLE


def _horizon(
    effect_at: datetime,
    now: datetime,
    policy: ConsequencePolicy,
) -> HorizonBucket:
    delta = effect_at - now
    if delta <= policy.immediate_horizon:
        return HorizonBucket.IMMEDIATE
    if delta <= policy.tomorrow_horizon:
        return HorizonBucket.TOMORROW
    if delta <= policy.near_horizon:
        return HorizonBucket.NEAR
    if delta <= policy.block_horizon:
        return HorizonBucket.BLOCK
    if delta <= policy.season_horizon:
        return HorizonBucket.SEASON
    return HorizonBucket.LONG_TERM


def _ordered_union[T](first: tuple[T, ...], *rest: tuple[T, ...]) -> tuple[T, ...]:
    return tuple(dict.fromkeys(item for values in (first, *rest) for item in values))
