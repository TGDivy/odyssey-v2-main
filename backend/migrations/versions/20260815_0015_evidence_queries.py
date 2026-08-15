"""Persist immutable evidence query replay records.

Revision ID: 20260815_0015
Revises: 20260815_0014
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0015"
down_revision: str | None = "20260815_0014"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "evidence_queries",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("question", sa.Text(), nullable=False),
        sa.Column("personal_scope", sa.String(length=200), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("response", sa.JSON(), nullable=False),
        sa.Column("source_entity_ids", sa.JSON(), nullable=False),
        sa.Column("assembled_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("retrieval_version", sa.String(length=100), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_evidence_queries"),
    )
    op.create_index(
        "ix_evidence_queries_owner_time",
        "evidence_queries",
        ["owner_id", "assembled_at"],
    )
    create_immutable_evidence_query_trigger()


def create_immutable_evidence_query_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_evidence_query_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'evidence_queries is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER evidence_queries_immutable
            BEFORE UPDATE OR DELETE ON evidence_queries
            FOR EACH ROW EXECUTE FUNCTION reject_evidence_query_mutation();
            """
        )
    elif dialect == "sqlite":
        for action in ("UPDATE", "DELETE"):
            op.execute(
                f"""
                CREATE TRIGGER evidence_queries_reject_{action.lower()}
                BEFORE {action} ON evidence_queries
                BEGIN
                  SELECT RAISE(ABORT, 'evidence_queries is append-only');
                END;
                """
            )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute("DROP TRIGGER IF EXISTS evidence_queries_immutable ON evidence_queries")
        op.execute("DROP FUNCTION IF EXISTS reject_evidence_query_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS evidence_queries_reject_update")
        op.execute("DROP TRIGGER IF EXISTS evidence_queries_reject_delete")
    op.drop_index("ix_evidence_queries_owner_time", table_name="evidence_queries")
    op.drop_table("evidence_queries")
