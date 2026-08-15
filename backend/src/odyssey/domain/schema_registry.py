"""Stable names for versioned public domain contracts."""

from pydantic import BaseModel

from odyssey.domain.capture import Capture, Observation
from odyssey.domain.common import EntityMetadata, EpistemicState, Provenance, TemporalInterval
from odyssey.domain.context import ContextSnapshot
from odyssey.domain.life import (
    Action,
    CharterVersion,
    Commitment,
    Direction,
    LifeStageVersion,
    Project,
    Season,
)

SCHEMA_MODELS: dict[str, type[BaseModel]] = {
    "action": Action,
    "capture": Capture,
    "charter-version": CharterVersion,
    "commitment": Commitment,
    "context-snapshot": ContextSnapshot,
    "direction": Direction,
    "entity-metadata": EntityMetadata,
    "epistemic-state": EpistemicState,
    "life-stage-version": LifeStageVersion,
    "observation": Observation,
    "project": Project,
    "provenance": Provenance,
    "season": Season,
    "temporal-interval": TemporalInterval,
}
