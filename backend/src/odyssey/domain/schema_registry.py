"""Stable names for versioned public domain contracts."""

from pydantic import BaseModel

from odyssey.ai.models import ModelRun
from odyssey.archive.models import ChapterVersion, Episode
from odyssey.auth.models import PolicyDecision, StandingAuthorization
from odyssey.decision.models import (
    Choice,
    ConsequenceCandidate,
    Decision,
    DecisionOption,
    Recommendation,
)
from odyssey.domain.capture import Capture, Observation
from odyssey.domain.common import EntityMetadata, EpistemicState, Provenance, TemporalInterval
from odyssey.domain.context import ContextSnapshot
from odyssey.domain.events import DomainEvent
from odyssey.domain.life import (
    Action,
    CharterVersion,
    Commitment,
    Direction,
    LifeStageVersion,
    Project,
    Season,
)
from odyssey.domain.relationships import MeaningfulContact, Person, RelationshipAssertion
from odyssey.evaluation.contracts import (
    EvalCase,
    EvalCaseSet,
    EvalCorpusManifest,
    EvalRubricSet,
    GoldenReplaySet,
)
from odyssey.evidence.experiments import ExperimentResult, Hypothesis, PersonalExperiment
from odyssey.evidence.models import ClaimAppraisal, EvidenceClaim, EvidencePack, EvidenceSource
from odyssey.intent.models import Intent, Intervention, InterventionOpportunity
from odyssey.telemetry.models import (
    FeatureConfigurationEnvelope,
    FeatureConfigurationPayload,
    ProductChangeProposal,
    ProductEvent,
)
from odyssey.telemetry.registry import ProductTelemetryRegistryDocument

SCHEMA_MODELS: dict[str, type[BaseModel]] = {
    "action": Action,
    "capture": Capture,
    "chapter-version": ChapterVersion,
    "charter-version": CharterVersion,
    "choice": Choice,
    "claim-appraisal": ClaimAppraisal,
    "commitment": Commitment,
    "consequence-candidate": ConsequenceCandidate,
    "context-snapshot": ContextSnapshot,
    "decision": Decision,
    "decision-option": DecisionOption,
    "direction": Direction,
    "domain-event": DomainEvent,
    "entity-metadata": EntityMetadata,
    "epistemic-state": EpistemicState,
    "episode": Episode,
    "evidence-claim": EvidenceClaim,
    "evidence-pack": EvidencePack,
    "evidence-source": EvidenceSource,
    "eval-case": EvalCase,
    "eval-case-set": EvalCaseSet,
    "eval-corpus-manifest": EvalCorpusManifest,
    "eval-rubric-set": EvalRubricSet,
    "experiment-result": ExperimentResult,
    "feature-configuration-envelope": FeatureConfigurationEnvelope,
    "feature-configuration-payload": FeatureConfigurationPayload,
    "hypothesis": Hypothesis,
    "golden-replay-set": GoldenReplaySet,
    "intent": Intent,
    "intervention": Intervention,
    "intervention-opportunity": InterventionOpportunity,
    "life-stage-version": LifeStageVersion,
    "meaningful-contact": MeaningfulContact,
    "model-run": ModelRun,
    "observation": Observation,
    "personal-experiment": PersonalExperiment,
    "person": Person,
    "policy-decision": PolicyDecision,
    "project": Project,
    "product-change-proposal": ProductChangeProposal,
    "product-event": ProductEvent,
    "product-telemetry-registry": ProductTelemetryRegistryDocument,
    "provenance": Provenance,
    "recommendation": Recommendation,
    "relationship-assertion": RelationshipAssertion,
    "season": Season,
    "standing-authorization": StandingAuthorization,
    "temporal-interval": TemporalInterval,
}
