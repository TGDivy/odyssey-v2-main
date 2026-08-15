"""Guilt-free deterministic re-entry policy after absence."""

from datetime import timedelta
from enum import StrEnum
from typing import Literal

from pydantic import AwareDatetime, Field, model_validator

from odyssey.domain.common import UUID7, StrictModel


class ReentryOption(StrEnum):
    CONTINUE = "continue"
    REVISE_SEASON = "revise season"
    STAY_QUIET = "stay quiet"


class ReentryReason(StrEnum):
    ABSENCE_THRESHOLD_MET = "ABSENCE_THRESHOLD_MET"
    MATERIAL_CHANGES_SUMMARIZED = "MATERIAL_CHANGES_SUMMARIZED"
    STALE_OPPORTUNITIES_EXPIRED = "STALE_OPPORTUNITIES_EXPIRED"
    ONE_CLARIFICATION_SELECTED = "ONE_CLARIFICATION_SELECTED"
    NO_CURRENT_MATERIAL_CHANGE = "NO_CURRENT_MATERIAL_CHANGE"


class MaterialChange(StrictModel):
    id: UUID7
    occurred_at: AwareDatetime
    summary: str = Field(min_length=1, max_length=500)
    relevance: float = Field(ge=0, le=1)
    material: bool = True
    currently_relevant: bool = True
    unresolved: bool = False
    clarification_question: str | None = Field(default=None, min_length=1, max_length=500)
    clarification_value: float = Field(default=0, ge=0, le=1)
    source_refs: tuple[UUID7, ...] = ()

    @model_validator(mode="after")
    def validate_clarification(self) -> "MaterialChange":
        if self.clarification_question is None and self.clarification_value != 0:
            raise ValueError("clarification value requires a clarification question")
        return self


class ReentryOpportunity(StrictModel):
    id: UUID7
    expires_at: AwareDatetime
    active: bool = True


class ReentrySummaryItem(StrictModel):
    change_id: UUID7
    summary: str
    source_refs: tuple[UUID7, ...]


class ReentryPolicy(StrictModel):
    minimum_absence: timedelta = Field(default=timedelta(days=3), gt=timedelta(0))
    minimum_material_relevance: float = Field(default=0.5, ge=0, le=1)
    maximum_summary_items: int = Field(default=3, ge=1, le=3)
    policy_version: str = "reentry-policy-1.0"


class ReentrySurface(StrictModel):
    summary: tuple[ReentrySummaryItem, ...] = Field(max_length=3)
    one_question: str | None = None
    options: tuple[ReentryOption, ...]
    expired_opportunity_ids: tuple[UUID7, ...]
    suppress_backlog: Literal[True] = True
    no_absence_penalty: Literal[True] = True
    reason_codes: tuple[ReentryReason, ...]
    policy_version: str


def should_enter_reentry(
    *,
    last_seen: AwareDatetime | None,
    now: AwareDatetime,
    policy: ReentryPolicy | None = None,
) -> bool:
    if last_seen is None:
        return False
    if last_seen > now:
        raise ValueError("last_seen cannot be in the future")
    active_policy = policy or ReentryPolicy()
    return now - last_seen >= active_policy.minimum_absence


def build_reentry(
    *,
    last_seen: AwareDatetime,
    now: AwareDatetime,
    changes: tuple[MaterialChange, ...],
    opportunities: tuple[ReentryOpportunity, ...],
    policy: ReentryPolicy | None = None,
) -> ReentrySurface:
    if last_seen > now:
        raise ValueError("last_seen cannot be in the future")
    active_policy = policy or ReentryPolicy()
    eligible_changes = tuple(
        change
        for change in changes
        if last_seen < change.occurred_at <= now
        and change.material
        and change.currently_relevant
        and change.relevance >= active_policy.minimum_material_relevance
    )
    ranked_changes = sorted(
        eligible_changes,
        key=lambda change: (-change.relevance, -change.occurred_at.timestamp(), str(change.id)),
    )
    summary = tuple(
        ReentrySummaryItem(
            change_id=change.id,
            summary=change.summary,
            source_refs=change.source_refs,
        )
        for change in ranked_changes[: active_policy.maximum_summary_items]
    )
    unresolved = sorted(
        (
            change
            for change in eligible_changes
            if change.unresolved and change.clarification_question is not None
        ),
        key=lambda change: (
            -change.clarification_value,
            -change.relevance,
            -change.occurred_at.timestamp(),
            str(change.id),
        ),
    )
    question = unresolved[0].clarification_question if unresolved else None
    expired_ids = tuple(
        sorted(
            (
                opportunity.id
                for opportunity in opportunities
                if opportunity.active and opportunity.expires_at <= now
            ),
            key=str,
        )
    )
    reasons = [ReentryReason.ABSENCE_THRESHOLD_MET]
    if summary:
        reasons.append(ReentryReason.MATERIAL_CHANGES_SUMMARIZED)
    else:
        reasons.append(ReentryReason.NO_CURRENT_MATERIAL_CHANGE)
    if expired_ids:
        reasons.append(ReentryReason.STALE_OPPORTUNITIES_EXPIRED)
    if question is not None:
        reasons.append(ReentryReason.ONE_CLARIFICATION_SELECTED)
    return ReentrySurface(
        summary=summary,
        one_question=question,
        options=(
            ReentryOption.CONTINUE,
            ReentryOption.REVISE_SEASON,
            ReentryOption.STAY_QUIET,
        ),
        expired_opportunity_ids=expired_ids,
        reason_codes=tuple(reasons),
        policy_version=active_policy.policy_version,
    )
