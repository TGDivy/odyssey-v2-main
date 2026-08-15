#!/usr/bin/env python3
"""Generate deterministic, source-linked synthetic Odyssey history."""

import argparse
import json
import random
import sys
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from hashlib import sha256
from pathlib import Path
from typing import Any
from uuid import UUID, uuid5

from odyssey.domain.common import ActorRef, ActorType, Provenance
from odyssey.domain.events import EVENT_DEFINITIONS, DomainEvent, EventDefinition

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = REPOSITORY_ROOT / "fixtures" / "synthetic-life" / "generated" / "v1"
SYNTHETIC_NAMESPACE = UUID("e35875f5-970d-4be4-8f5f-9f8ab7aa77e0")
EVENT_BY_TYPE = {definition.event_type: definition for definition in EVENT_DEFINITIONS}


def canonical_line(value: dict[str, Any]) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def serialize_lines(values: list[dict[str, Any]]) -> bytes:
    return ("\n".join(canonical_line(value) for value in values) + "\n").encode()


class DeterministicIdentifiers:
    def __init__(self, seed: int) -> None:
        self.random = random.Random(seed)
        self.counter = 0

    def uuid7(self, occurred_at: datetime) -> UUID:
        self.counter += 1
        timestamp_ms = int(occurred_at.timestamp() * 1_000) & ((1 << 48) - 1)
        random_a = self.random.getrandbits(12)
        random_b = self.random.getrandbits(62) ^ self.counter
        value = timestamp_ms << 80
        value |= 0x7 << 76
        value |= random_a << 64
        value |= 0b10 << 62
        value |= random_b & ((1 << 62) - 1)
        return UUID(int=value)

    def correlation_id(self, label: str) -> UUID:
        return uuid5(SYNTHETIC_NAMESPACE, label)


@dataclass
class GeneratedHistory:
    events: list[dict[str, Any]]
    records: list[dict[str, Any]]
    scenario_counts: dict[str, int]


class HistoryBuilder:
    def __init__(self, *, start: date, years: int, seed: int) -> None:
        self.start = start
        self.end = date(start.year + years, start.month, start.day) - timedelta(days=1)
        self.identifiers = DeterministicIdentifiers(seed)
        self.random = random.Random(seed)
        self.owner = ActorRef(actor_type=ActorType.USER, actor_id="synthetic-owner")
        self.events: list[DomainEvent] = []
        self.records: list[dict[str, Any]] = []
        self.scenario_counts: dict[str, int] = {}
        self.current_season_id: UUID | None = None

    def timestamp(self, day: date, hour: int, minute: int = 0) -> datetime:
        return datetime.combine(day, time(hour=hour, minute=minute), tzinfo=UTC)

    def count(self, scenario: str) -> None:
        self.scenario_counts[scenario] = self.scenario_counts.get(scenario, 0) + 1

    def record(
        self, *, occurred_at: datetime, record_type: str, scenario: str, **data: Any
    ) -> UUID:
        record_id = self.identifiers.uuid7(occurred_at)
        document = {
            "id": str(record_id),
            "record_type": record_type,
            "scenario": scenario,
            "occurred_at": occurred_at.isoformat().replace("+00:00", "Z"),
            "synthetic": True,
            "data": data,
        }
        self.records.append(document)
        self.count(scenario)
        return record_id

    def emit(
        self,
        *,
        event_type: str,
        occurred_at: datetime,
        aggregate_id: UUID,
        payload: dict[str, str],
        source_record_id: UUID,
        causation_id: UUID | None = None,
    ) -> UUID:
        definition = EVENT_BY_TYPE[event_type]
        self.validate_payload(definition, payload)
        event_id = self.identifiers.uuid7(occurred_at)
        provenance = Provenance(
            id=self.identifiers.uuid7(occurred_at),
            source_kind="synthetic_fixture",
            source_id=str(source_record_id),
            captured_at=occurred_at,
            actor=self.owner,
            transformation_chain=("synthetic-life-generator.v1",),
            content_hash=sha256(canonical_line(payload).encode()).hexdigest(),
            details={"contains_real_personal_data": False},
        )
        event = DomainEvent(
            event_id=event_id,
            event_type=event_type,
            event_schema_version=1,
            aggregate_type=definition.aggregate_type,
            aggregate_id=aggregate_id,
            occurred_at=occurred_at,
            recorded_at=occurred_at + timedelta(seconds=self.random.randint(0, 5)),
            actor=self.owner,
            correlation_id=self.identifiers.correlation_id(
                f"{occurred_at.date()}:{event_type}:{aggregate_id}"
            ),
            causation_id=causation_id,
            payload=payload,
            provenance=provenance,
        )
        self.events.append(event)
        return event_id

    @staticmethod
    def validate_payload(definition: EventDefinition, payload: dict[str, str]) -> None:
        keys = set(payload)
        required = set(definition.required_payload_fields)
        allowed = required | set(definition.optional_payload_fields)
        if not required.issubset(keys) or not keys.issubset(allowed):
            raise ValueError(f"Invalid payload for {definition.event_type}: {sorted(keys)}")

    def add_orientation(self) -> None:
        occurred_at = self.timestamp(self.start, 9)
        charter_version_id = self.record(
            occurred_at=occurred_at,
            record_type="charter_version",
            scenario="orientation",
            title="Synthetic Charter",
            values=["agency", "relationships", "health", "craft", "wonder"],
            anti_optimization=["No universal life score", "Protect meaningful exceptions"],
        )
        self.emit(
            event_type="charter.revised.v1",
            occurred_at=occurred_at,
            aggregate_id=charter_version_id,
            payload={"charter_version_id": str(charter_version_id)},
            source_record_id=charter_version_id,
        )
        self.activate_season(self.start, title="Durable foundations", previous=None)

    def activate_season(self, day: date, *, title: str, previous: UUID | None) -> None:
        occurred_at = self.timestamp(day, 10)
        season_id = self.record(
            occurred_at=occurred_at,
            record_type="season",
            scenario="season_transition" if previous else "orientation",
            title=title,
            primary_directions=["craft", "endurance"],
            foundations=["sleep", "relationships"],
            dormant=["financial_aggregation", "public_sharing"],
        )
        if previous is not None:
            self.emit(
                event_type="season.transitioned.v1",
                occurred_at=occurred_at,
                aggregate_id=season_id,
                payload={"from_season_id": str(previous), "to_season_id": str(season_id)},
                source_record_id=season_id,
            )
        self.emit(
            event_type="season.activated.v1",
            occurred_at=occurred_at + timedelta(seconds=1),
            aggregate_id=season_id,
            payload={"season_id": str(season_id)},
            source_record_id=season_id,
        )
        self.current_season_id = season_id

    def add_daily_observation(self, day: date) -> None:
        occurred_at = self.timestamp(day, 7, 15)
        if self.random.random() < 0.045:
            self.record(
                occurred_at=occurred_at,
                record_type="data_quality_gap",
                scenario="missing_data",
                domain="sleep",
                reason="synthetic_device_unavailable",
            )
            return
        sleep_hours = round(max(4.8, min(9.2, self.random.gauss(7.35, 0.7))), 2)
        caffeine_mg = max(0, int(self.random.gauss(145, 70)))
        source_record_id = self.record(
            occurred_at=occurred_at,
            record_type="health_observation",
            scenario="ordinary_day",
            sleep_hours=sleep_hours,
            caffeine_mg=caffeine_mg,
            source="synthetic_health_adapter",
            timezone="Europe/London",
        )
        observation_id = self.identifiers.uuid7(occurred_at)
        self.emit(
            event_type="observation.normalized.v1",
            occurred_at=occurred_at,
            aggregate_id=observation_id,
            payload={
                "observation_id": str(observation_id),
                "source_record_id": str(source_record_id),
            },
            source_record_id=source_record_id,
        )

    def add_workday(self, day: date) -> None:
        if day.weekday() >= 5:
            return
        occurred_at = self.timestamp(day, 9)
        source_record_id = self.record(
            occurred_at=occurred_at,
            record_type="calendar_context",
            scenario="ordinary_workday",
            meetings=self.random.randint(1, 7),
            focus_blocks=self.random.randint(0, 3),
            location="office" if day.weekday() < 3 else "home",
        )
        assertion_id = self.identifiers.uuid7(occurred_at)
        self.emit(
            event_type="assertion.created.v1",
            occurred_at=occurred_at,
            aggregate_id=assertion_id,
            payload={
                "assertion_id": str(assertion_id),
                "subject_id": str(source_record_id),
                "assertion_type": "calendar_context",
            },
            source_record_id=source_record_id,
        )

    def add_weekly_capture(self, day: date) -> None:
        if day.weekday() != 6:
            return
        occurred_at = self.timestamp(day, 18, 30)
        capture_id = self.record(
            occurred_at=occurred_at,
            record_type="capture",
            scenario="weekly_reflection",
            kind="text",
            text="Synthetic weekly reflection with no real personal content.",
            invoking_surface="iphone",
        )
        self.emit(
            event_type="capture.recorded.v1",
            occurred_at=occurred_at,
            aggregate_id=capture_id,
            payload={"capture_id": str(capture_id)},
            source_record_id=capture_id,
        )

    def add_training(self, day: date) -> None:
        if day.weekday() not in {1, 3, 5}:
            return
        occurred_at = self.timestamp(day, 6, 30)
        action_id = self.record(
            occurred_at=occurred_at,
            record_type="training_action",
            scenario="race_training",
            discipline="running" if day.weekday() != 3 else "strength",
            duration_minutes=self.random.choice([35, 45, 60, 80]),
            status="completed",
        )
        self.emit(
            event_type="action.status_changed.v1",
            occurred_at=occurred_at,
            aggregate_id=action_id,
            payload={
                "action_id": str(action_id),
                "previous_status": "scheduled",
                "new_status": "completed",
            },
            source_record_id=action_id,
        )

    def add_annual_scenarios(self, day: date) -> None:
        if day.month == self.start.month and day.day == self.start.day and day != self.start:
            previous = self.current_season_id
            self.activate_season(day, title=f"Synthetic season {day.year}", previous=previous)
        if (day.month, day.day) == (2, 12):
            self.add_interview(day)
        if (day.month, day.day) == (5, 18):
            self.add_illness(day)
        if (day.month, day.day) == (8, 20):
            self.add_travel(day)
        if (day.month, day.day) == (11, 6):
            self.add_relationship_commitment(day)
        if (day.month, day.day) == (12, 27):
            self.add_archive_episode(day)
        if (day.month, day.day) == (3, 3):
            self.add_conflicting_season_edit(day)

    def add_interview(self, day: date) -> None:
        occurred_at = self.timestamp(day, 11)
        decision_id = self.record(
            occurred_at=occurred_at,
            record_type="decision",
            scenario="interview",
            question="How should the synthetic owner prepare for tomorrow's interview?",
            stakes="high",
            options=["focused preparation", "rest", "request missing information"],
        )
        detected_event_id = self.emit(
            event_type="decision.detected.v1",
            occurred_at=occurred_at,
            aggregate_id=decision_id,
            payload={"decision_id": str(decision_id)},
            source_record_id=decision_id,
        )
        recommendation_id = self.record(
            occurred_at=occurred_at + timedelta(minutes=1),
            record_type="recommendation",
            scenario="interview",
            method="deterministic",
            recommendation="Prepare two examples, then protect sleep.",
            uncertainty="moderate",
        )
        self.emit(
            event_type="decision.recommendation_prepared.v1",
            occurred_at=occurred_at + timedelta(minutes=1),
            aggregate_id=decision_id,
            payload={
                "decision_id": str(decision_id),
                "recommendation_id": str(recommendation_id),
            },
            source_record_id=recommendation_id,
            causation_id=detected_event_id,
        )

    def add_illness(self, day: date) -> None:
        occurred_at = self.timestamp(day, 8)
        source_record_id = self.record(
            occurred_at=occurred_at,
            record_type="health_constraint",
            scenario="illness",
            symptoms=["fatigue", "sore throat"],
            user_confirmed=True,
            clinical_recommendation=False,
        )
        assertion_id = self.identifiers.uuid7(occurred_at)
        self.emit(
            event_type="assertion.created.v1",
            occurred_at=occurred_at,
            aggregate_id=assertion_id,
            payload={
                "assertion_id": str(assertion_id),
                "subject_id": str(source_record_id),
                "assertion_type": "temporary_health_constraint",
            },
            source_record_id=source_record_id,
        )

    def add_travel(self, day: date) -> None:
        occurred_at = self.timestamp(day, 5, 45)
        source_record_id = self.record(
            occurred_at=occurred_at,
            record_type="travel_context",
            scenario="travel_timezone",
            from_timezone="Europe/London",
            to_timezone="America/New_York",
            duration_days=8,
            exact_location_history=False,
        )
        observation_id = self.identifiers.uuid7(occurred_at)
        self.emit(
            event_type="observation.normalized.v1",
            occurred_at=occurred_at,
            aggregate_id=observation_id,
            payload={
                "observation_id": str(observation_id),
                "source_record_id": str(source_record_id),
            },
            source_record_id=source_record_id,
        )

    def add_relationship_commitment(self, day: date) -> None:
        occurred_at = self.timestamp(day, 17)
        source_record_id = self.record(
            occurred_at=occurred_at,
            record_type="relationship_commitment",
            scenario="relationship_commitment",
            person_label="Synthetic close friend",
            commitment="Attend explicitly recorded birthday dinner",
            inferred_obligation=False,
            person_ranked=False,
        )
        assertion_id = self.identifiers.uuid7(occurred_at)
        self.emit(
            event_type="assertion.created.v1",
            occurred_at=occurred_at,
            aggregate_id=assertion_id,
            payload={
                "assertion_id": str(assertion_id),
                "subject_id": str(source_record_id),
                "assertion_type": "explicit_relationship_commitment",
            },
            source_record_id=source_record_id,
        )

    def add_archive_episode(self, day: date) -> None:
        occurred_at = self.timestamp(day, 20)
        episode_id = self.record(
            occurred_at=occurred_at,
            record_type="episode_candidate",
            scenario="archive",
            title="Synthetic year-end gathering",
            source_link_count=5,
            fabricated_quotes=False,
            status="candidate",
        )
        self.emit(
            event_type="episode.proposed.v1",
            occurred_at=occurred_at,
            aggregate_id=episode_id,
            payload={"episode_id": str(episode_id)},
            source_record_id=episode_id,
        )

    def add_conflicting_season_edit(self, day: date) -> None:
        occurred_at = self.timestamp(day, 13)
        conflict_record_id = self.record(
            occurred_at=occurred_at,
            record_type="sync_conflict_fixture",
            scenario="conflicting_season_edits",
            device_a_end_date=f"{day.year}-11-30",
            device_b_end_date=f"{day.year}-12-15",
            requires_owner_resolution=True,
        )
        assertion_id = self.identifiers.uuid7(occurred_at)
        superseding_id = self.identifiers.uuid7(occurred_at + timedelta(seconds=1))
        created_event = self.emit(
            event_type="assertion.created.v1",
            occurred_at=occurred_at,
            aggregate_id=assertion_id,
            payload={
                "assertion_id": str(assertion_id),
                "subject_id": str(conflict_record_id),
                "assertion_type": "conflicting_season_end_date",
            },
            source_record_id=conflict_record_id,
        )
        self.emit(
            event_type="assertion.superseded.v1",
            occurred_at=occurred_at + timedelta(seconds=1),
            aggregate_id=assertion_id,
            payload={
                "assertion_id": str(assertion_id),
                "superseded_by_assertion_id": str(superseding_id),
            },
            source_record_id=conflict_record_id,
            causation_id=created_event,
        )

    def add_intervention_examples(self) -> None:
        day = self.start + timedelta(days=10)
        occurred_at = self.timestamp(day, 21)
        intent_id = self.record(
            occurred_at=occurred_at,
            record_type="intent",
            scenario="intervention_policy",
            intent_class="sleep_wind_down",
            active=True,
        )
        opportunity_id = self.record(
            occurred_at=occurred_at,
            record_type="opportunity",
            scenario="intervention_policy",
            confidence="moderate",
            expiry=(occurred_at + timedelta(hours=1)).isoformat(),
        )
        context_snapshot_id = self.identifiers.uuid7(occurred_at)
        detected_event = self.emit(
            event_type="intent.opportunity_detected.v1",
            occurred_at=occurred_at,
            aggregate_id=intent_id,
            payload={
                "intent_id": str(intent_id),
                "opportunity_id": str(opportunity_id),
                "context_snapshot_id": str(context_snapshot_id),
            },
            source_record_id=opportunity_id,
        )
        self.emit(
            event_type="intervention.suppressed.v1",
            occurred_at=occurred_at + timedelta(seconds=1),
            aggregate_id=opportunity_id,
            payload={"opportunity_id": str(opportunity_id), "reason_code": "GLOBAL_PAUSE"},
            source_record_id=opportunity_id,
            causation_id=detected_event,
        )

    def build(self) -> GeneratedHistory:
        self.add_orientation()
        self.add_intervention_examples()
        day = self.start
        while day <= self.end:
            self.add_daily_observation(day)
            self.add_workday(day)
            self.add_weekly_capture(day)
            self.add_training(day)
            self.add_annual_scenarios(day)
            day += timedelta(days=1)
        self.events.sort(key=lambda event: (event.occurred_at, str(event.event_id)))
        self.records.sort(key=lambda record: (record["occurred_at"], record["id"]))
        return GeneratedHistory(
            events=[event.model_dump(mode="json") for event in self.events],
            records=self.records,
            scenario_counts=dict(sorted(self.scenario_counts.items())),
        )


def generated_artifacts(*, start: date, years: int, seed: int) -> dict[str, bytes]:
    history = HistoryBuilder(start=start, years=years, seed=seed).build()
    ledger = serialize_lines(history.events)
    records = serialize_lines(history.records)
    manifest = {
        "fixture_version": 1,
        "synthetic_only": True,
        "contains_real_personal_data": False,
        "seed": seed,
        "start_date": start.isoformat(),
        "years": years,
        "end_date": (
            date(start.year + years, start.month, start.day) - timedelta(days=1)
        ).isoformat(),
        "event_count": len(history.events),
        "record_count": len(history.records),
        "scenario_counts": history.scenario_counts,
        "artifacts": {
            "ledger.jsonl": sha256(ledger).hexdigest(),
            "source-records.jsonl": sha256(records).hexdigest(),
        },
    }
    return {
        "ledger.jsonl": ledger,
        "source-records.jsonl": records,
        "manifest.json": (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode(),
    }


def write(output: Path, artifacts: dict[str, bytes]) -> None:
    output.mkdir(parents=True, exist_ok=True)
    for name, content in artifacts.items():
        (output / name).write_bytes(content)


def check(output: Path, artifacts: dict[str, bytes]) -> int:
    stale = [
        name
        for name, expected in artifacts.items()
        if not (output / name).exists() or (output / name).read_bytes() != expected
    ]
    if stale:
        print("Synthetic fixtures are stale:", file=sys.stderr)
        for name in stale:
            print(f"  {output / name}", file=sys.stderr)
        print("Run `make fixtures` and commit the result.", file=sys.stderr)
        return 1
    print(f"Verified {len(artifacts)} deterministic synthetic-life artifacts.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--start", type=date.fromisoformat, default=date(2023, 1, 1))
    parser.add_argument("--years", type=int, default=3)
    parser.add_argument("--seed", type=int, default=20_260_815)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    if arguments.years < 1:
        parser.error("--years must be at least 1")
    artifacts = generated_artifacts(
        start=arguments.start,
        years=arguments.years,
        seed=arguments.seed,
    )
    if arguments.check:
        return check(arguments.output, artifacts)
    write(arguments.output, artifacts)
    print(f"Generated {len(artifacts)} synthetic-life artifacts in {arguments.output}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
