"""Persist immutable intervention policy evaluations.

Revision ID: 20260815_0012
Revises: 20260815_0011
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0012"
down_revision: str | None = "20260815_0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "intervention_evaluations",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("opportunity_id", sa.Uuid(), nullable=False),
        sa.Column("semantic_key", sa.String(length=500), nullable=False),
        sa.Column("evaluated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("urgency", sa.String(length=30), nullable=False),
        sa.Column("policy", sa.String(length=30), nullable=False),
        sa.Column("reason_codes", sa.JSON(), nullable=False),
        sa.Column("surface", sa.String(length=50)),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("retry_after", sa.DateTime(timezone=True)),
        sa.Column("policy_version", sa.String(length=100), nullable=False),
        sa.Column("request_context_hash", sa.String(length=64), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_intervention_evaluations"),
    )
    op.create_index(
        "ix_intervention_evaluations_owner_time",
        "intervention_evaluations",
        ["owner_id", "evaluated_at"],
    )
    op.create_index(
        "ix_intervention_evaluations_semantic_time",
        "intervention_evaluations",
        ["semantic_key", "evaluated_at"],
    )
    create_immutable_intervention_evaluation_trigger()


def create_immutable_intervention_evaluation_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_intervention_evaluation_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'intervention_evaluations is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER intervention_evaluations_immutable
            BEFORE UPDATE OR DELETE ON intervention_evaluations
            FOR EACH ROW EXECUTE FUNCTION reject_intervention_evaluation_mutation();
            """
        )
    elif dialect == "sqlite":
        for action in ("UPDATE", "DELETE"):
            op.execute(
                f"""
                CREATE TRIGGER intervention_evaluations_reject_{action.lower()}
                BEFORE {action} ON intervention_evaluations
                BEGIN
                  SELECT RAISE(ABORT, 'intervention_evaluations is append-only');
                END;
                """
            )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            "DROP TRIGGER IF EXISTS intervention_evaluations_immutable "
            "ON intervention_evaluations"
        )
        op.execute("DROP FUNCTION IF EXISTS reject_intervention_evaluation_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS intervention_evaluations_reject_update")
        op.execute("DROP TRIGGER IF EXISTS intervention_evaluations_reject_delete")
    op.drop_index(
        "ix_intervention_evaluations_semantic_time",
        table_name="intervention_evaluations",
    )
    op.drop_index(
        "ix_intervention_evaluations_owner_time",
        table_name="intervention_evaluations",
    )
    op.drop_table("intervention_evaluations")
