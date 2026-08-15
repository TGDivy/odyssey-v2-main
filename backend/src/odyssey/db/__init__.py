"""Database sessions, models, and migrations."""

from odyssey.attachments import models as attachment_models
from odyssey.auth import persistence as auth_persistence
from odyssey.context import persistence as context_persistence
from odyssey.db import models as database_models
from odyssey.db.base import Base
from odyssey.db.session import Database
from odyssey.decision import persistence as decision_persistence
from odyssey.intent import persistence as intent_persistence
from odyssey.sync import models as sync_models

assert (
    attachment_models
    and auth_persistence
    and context_persistence
    and database_models
    and decision_persistence
    and intent_persistence
    and sync_models
)

__all__ = ["Base", "Database"]
