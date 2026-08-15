"""Persist owner-device sync queue diagnostics.

Revision ID: 20260815_0006
Revises: 20260815_0005
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0006"
down_revision: str | None = "20260815_0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "sync_devices",
        sa.Column(
            "local_queued_operations",
            sa.Integer(),
            server_default=sa.text("0"),
            nullable=False,
        ),
    )
    op.add_column(
        "sync_devices",
        sa.Column("local_oldest_unsynced_at", sa.DateTime(timezone=True)),
    )
    op.add_column(
        "sync_devices",
        sa.Column(
            "local_attachment_backlog",
            sa.Integer(),
            server_default=sa.text("0"),
            nullable=False,
        ),
    )
    op.add_column(
        "sync_devices",
        sa.Column("diagnostics_reported_at", sa.DateTime(timezone=True)),
    )


def downgrade() -> None:
    op.drop_column("sync_devices", "diagnostics_reported_at")
    op.drop_column("sync_devices", "local_attachment_backlog")
    op.drop_column("sync_devices", "local_oldest_unsynced_at")
    op.drop_column("sync_devices", "local_queued_operations")
