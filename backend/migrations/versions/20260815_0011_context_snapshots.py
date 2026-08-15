"""Persist immutable reproducible context snapshots.

Revision ID: 20260815_0011
Revises: 20260815_0010
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0011"
down_revision: str | None = "20260815_0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "context_snapshots",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("as_of", sa.DateTime(timezone=True), nullable=False),
        sa.Column("built_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("horizon", sa.String(length=30), nullable=False),
        sa.Column("purpose", sa.String(length=200), nullable=False),
        sa.Column("builder_version", sa.String(length=100), nullable=False),
        sa.Column("content_hash", sa.String(length=64), nullable=False),
        sa.Column("document", sa.JSON(), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_context_snapshots"),
        sa.UniqueConstraint("content_hash", name="uq_context_snapshots_content_hash"),
    )
    op.create_index(
        "ix_context_snapshots_owner_built",
        "context_snapshots",
        ["owner_id", "built_at"],
    )
    create_immutable_context_snapshot_trigger()


def create_immutable_context_snapshot_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_context_snapshot_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'context_snapshots is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER context_snapshots_immutable
            BEFORE UPDATE OR DELETE ON context_snapshots
            FOR EACH ROW EXECUTE FUNCTION reject_context_snapshot_mutation();
            """
        )
    elif dialect == "sqlite":
        for action in ("UPDATE", "DELETE"):
            op.execute(
                f"""
                CREATE TRIGGER context_snapshots_reject_{action.lower()}
                BEFORE {action} ON context_snapshots
                BEGIN
                  SELECT RAISE(ABORT, 'context_snapshots is append-only');
                END;
                """
            )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute("DROP TRIGGER IF EXISTS context_snapshots_immutable ON context_snapshots")
        op.execute("DROP FUNCTION IF EXISTS reject_context_snapshot_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS context_snapshots_reject_update")
        op.execute("DROP TRIGGER IF EXISTS context_snapshots_reject_delete")
    op.drop_index("ix_context_snapshots_owner_built", table_name="context_snapshots")
    op.drop_table("context_snapshots")
