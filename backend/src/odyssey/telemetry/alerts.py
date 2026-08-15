"""Deterministic operator alert policies over technical telemetry."""

from dataclasses import dataclass
from enum import StrEnum


class AlertSeverity(StrEnum):
    WARNING = "warning"
    CRITICAL = "critical"


@dataclass(frozen=True, slots=True)
class OperatorAlert:
    code: str
    severity: AlertSeverity
    observed_value: float
    threshold: float


def evaluate_outbox_alerts(
    *,
    dead_letter_depth: int,
    oldest_age_seconds: float,
    backlog_alert_seconds: int,
) -> tuple[OperatorAlert, ...]:
    alerts: list[OperatorAlert] = []
    if dead_letter_depth > 0:
        alerts.append(
            OperatorAlert(
                code="OUTBOX_DEAD_LETTERS_PRESENT",
                severity=AlertSeverity.CRITICAL,
                observed_value=float(dead_letter_depth),
                threshold=1.0,
            )
        )
    if oldest_age_seconds >= backlog_alert_seconds:
        alerts.append(
            OperatorAlert(
                code="OUTBOX_BACKLOG_AGE_EXCEEDED",
                severity=AlertSeverity.WARNING,
                observed_value=oldest_age_seconds,
                threshold=float(backlog_alert_seconds),
            )
        )
    return tuple(alerts)
