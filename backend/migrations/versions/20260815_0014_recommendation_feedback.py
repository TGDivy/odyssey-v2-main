"""Persist immutable recommendation feedback and correction links.

Revision ID: 20260815_0014
Revises: 20260815_0013
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0014"
down_revision: str | None = "20260815_0013"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "recommendation_feedback",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("recommendation_id", sa.Uuid(), nullable=False),
        sa.Column("feedback_type", sa.String(length=50), nullable=False),
        sa.Column("apply_scope", sa.String(length=50), nullable=False),
        sa.Column("correction_assertion_id", sa.Uuid()),
        sa.Column("replacement_assertion_id", sa.Uuid()),
        sa.Column("ledger_event_id", sa.Uuid()),
        sa.Column("future_recommendations_affected", sa.Boolean(), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("idempotency_key_hash", sa.String(length=64), nullable=False),
        sa.Column("response", sa.JSON(), nullable=False),
        sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("policy_version", sa.String(length=100), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_recommendation_feedback"),
        sa.UniqueConstraint(
            "idempotency_key_hash",
            name="uq_recommendation_feedback_idempotency_key_hash",
        ),
    )
    op.create_index(
        "ix_recommendation_feedback_recommendation",
        "recommendation_feedback",
        ["recommendation_id", "recorded_at"],
    )
    create_immutable_recommendation_feedback_trigger()


def create_immutable_recommendation_feedback_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_recommendation_feedback_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'recommendation_feedback is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER recommendation_feedback_immutable
            BEFORE UPDATE OR DELETE ON recommendation_feedback
            FOR EACH ROW EXECUTE FUNCTION reject_recommendation_feedback_mutation();
            """
        )
    elif dialect == "sqlite":
        for action in ("UPDATE", "DELETE"):
            op.execute(
                f"""
                CREATE TRIGGER recommendation_feedback_reject_{action.lower()}
                BEFORE {action} ON recommendation_feedback
                BEGIN
                  SELECT RAISE(ABORT, 'recommendation_feedback is append-only');
                END;
                """
            )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            "DROP TRIGGER IF EXISTS recommendation_feedback_immutable ON recommendation_feedback"
        )
        op.execute("DROP FUNCTION IF EXISTS reject_recommendation_feedback_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS recommendation_feedback_reject_update")
        op.execute("DROP TRIGGER IF EXISTS recommendation_feedback_reject_delete")
    op.drop_index(
        "ix_recommendation_feedback_recommendation",
        table_name="recommendation_feedback",
    )
    op.drop_table("recommendation_feedback")
