"""Database sessions, models, and migrations."""

from odyssey.attachments import models as attachment_models
from odyssey.auth import persistence as auth_persistence
from odyssey.context import persistence as context_persistence
from odyssey.db import models as database_models
from odyssey.db.base import Base
from odyssey.db.session import Database
from odyssey.decision import feedback_persistence as feedback_persistence
from odyssey.decision import persistence as decision_persistence
from odyssey.evidence import query_persistence as evidence_query_persistence
from odyssey.exports import persistence as export_persistence
from odyssey.intent import persistence as intent_persistence
from odyssey.life import persistence as life_persistence
from odyssey.sync import models as sync_models

assert (
    attachment_models
    and auth_persistence
    and context_persistence
    and database_models
    and decision_persistence
    and feedback_persistence
    and evidence_query_persistence
    and export_persistence
    and intent_persistence
    and life_persistence
    and sync_models
)

__all__ = ["Base", "Database"]
