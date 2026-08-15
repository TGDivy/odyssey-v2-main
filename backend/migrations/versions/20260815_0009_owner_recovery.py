"""Add one-time owner recovery credentials.

Revision ID: 20260815_0009
Revises: 20260815_0008
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0009"
down_revision: str | None = "20260815_0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "owner_recovery_credentials",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("credential_hash", sa.String(length=64), nullable=False),
        sa.Column("label", sa.String(length=100), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_by", sa.String(length=100), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True)),
        sa.Column("consumed_by_device_id", sa.Uuid()),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.Column("revoked_by", sa.String(length=100)),
        sa.ForeignKeyConstraint(
            ["owner_id"],
            ["owner_identities.owner_id"],
            name="fk_owner_recovery_credentials_owner_id_owner_identities",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_owner_recovery_credentials"),
        sa.UniqueConstraint(
            "credential_hash",
            name="uq_owner_recovery_credentials_hash",
        ),
    )
    op.create_index(
        "ix_owner_recovery_credentials_expires",
        "owner_recovery_credentials",
        ["expires_at"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_owner_recovery_credentials_expires",
        table_name="owner_recovery_credentials",
    )
    op.drop_table("owner_recovery_credentials")
