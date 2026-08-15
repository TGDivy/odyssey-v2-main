"""Persist immutable deterministic decision preparations.

Revision ID: 20260815_0013
Revises: 20260815_0012
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0013"
down_revision: str | None = "20260815_0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "decision_preparations",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("decision_id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("context_snapshot_id", sa.Uuid(), nullable=False),
        sa.Column("question", sa.Text(), nullable=False),
        sa.Column("status", sa.String(length=50), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("response", sa.JSON(), nullable=False),
        sa.Column("prepared_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("policy_version", sa.String(length=100), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_decision_preparations"),
    )
    op.create_index(
        "ix_decision_preparations_owner_prepared",
        "decision_preparations",
        ["owner_id", "prepared_at"],
    )
    op.create_index(
        "ix_decision_preparations_context",
        "decision_preparations",
        ["context_snapshot_id"],
    )
    create_immutable_decision_preparation_trigger()


def create_immutable_decision_preparation_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_decision_preparation_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'decision_preparations is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER decision_preparations_immutable
            BEFORE UPDATE OR DELETE ON decision_preparations
            FOR EACH ROW EXECUTE FUNCTION reject_decision_preparation_mutation();
            """
        )
    elif dialect == "sqlite":
        for action in ("UPDATE", "DELETE"):
            op.execute(
                f"""
                CREATE TRIGGER decision_preparations_reject_{action.lower()}
                BEFORE {action} ON decision_preparations
                BEGIN
                  SELECT RAISE(ABORT, 'decision_preparations is append-only');
                END;
                """
            )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            "DROP TRIGGER IF EXISTS decision_preparations_immutable ON decision_preparations"
        )
        op.execute("DROP FUNCTION IF EXISTS reject_decision_preparation_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS decision_preparations_reject_update")
        op.execute("DROP TRIGGER IF EXISTS decision_preparations_reject_delete")
    op.drop_index("ix_decision_preparations_context", table_name="decision_preparations")
    op.drop_index(
        "ix_decision_preparations_owner_prepared",
        table_name="decision_preparations",
    )
    op.drop_table("decision_preparations")
