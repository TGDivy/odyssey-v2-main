"""Persist immutable owner-accepted life-model versions.

Revision ID: 20260815_0017
Revises: 20260815_0016
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0017"
down_revision: str | None = "20260815_0016"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "life_model_versions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("kind", sa.String(length=30), nullable=False),
        sa.Column("logical_id", sa.Uuid(), nullable=False),
        sa.Column("version_number", sa.Integer(), nullable=False),
        sa.Column("acceptance_sequence", sa.Integer(), nullable=False),
        sa.Column("supersedes_version_id", sa.Uuid(), nullable=True),
        sa.Column("status", sa.String(length=30), nullable=True),
        sa.Column("acceptance_method", sa.String(length=40), nullable=False),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("content_hash", sa.String(length=64), nullable=False),
        sa.Column("document", sa.JSON(), nullable=False),
        sa.Column("event_id", sa.Uuid(), nullable=False),
        sa.Column("event_type", sa.String(length=100), nullable=False),
        sa.Column("ledger_sequence", sa.BigInteger(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "kind IN ('charter', 'life_stage', 'season')",
            name="ck_life_model_versions_life_model_versions_kind",
        ),
        sa.CheckConstraint(
            "version_number >= 1",
            name="ck_life_model_versions_life_model_versions_version_positive",
        ),
        sa.CheckConstraint(
            "acceptance_sequence >= 1",
            name="ck_life_model_versions_life_model_versions_acceptance_sequence_positive",
        ),
        sa.ForeignKeyConstraint(
            ["supersedes_version_id"],
            ["life_model_versions.id"],
            name="fk_life_model_versions_supersedes_version_id_life_model_versions",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_life_model_versions"),
        sa.UniqueConstraint("event_id", name="uq_life_model_versions_event_id"),
        sa.UniqueConstraint("ledger_sequence", name="uq_life_model_versions_ledger_sequence"),
        sa.UniqueConstraint(
            "owner_id",
            "kind",
            "acceptance_sequence",
            name="uq_life_model_versions_acceptance_sequence",
        ),
        sa.UniqueConstraint(
            "owner_id",
            "kind",
            "logical_id",
            "version_number",
            name="uq_life_model_versions_logical_version",
        ),
    )
    op.create_index(
        "ix_life_model_versions_owner_kind_accepted",
        "life_model_versions",
        ["owner_id", "kind", "accepted_at"],
    )
    op.create_index(
        "ix_life_model_versions_logical",
        "life_model_versions",
        ["kind", "logical_id", "version_number"],
    )
    create_immutable_life_model_trigger()


def create_immutable_life_model_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_life_model_version_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'life_model_versions is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER life_model_versions_immutable
            BEFORE UPDATE OR DELETE ON life_model_versions
            FOR EACH ROW EXECUTE FUNCTION reject_life_model_version_mutation();
            """
        )
    elif dialect == "sqlite":
        for action in ("UPDATE", "DELETE"):
            op.execute(
                f"""
                CREATE TRIGGER life_model_versions_reject_{action.lower()}
                BEFORE {action} ON life_model_versions
                BEGIN
                  SELECT RAISE(ABORT, 'life_model_versions is append-only');
                END;
                """
            )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute("DROP TRIGGER IF EXISTS life_model_versions_immutable ON life_model_versions")
        op.execute("DROP FUNCTION IF EXISTS reject_life_model_version_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS life_model_versions_reject_update")
        op.execute("DROP TRIGGER IF EXISTS life_model_versions_reject_delete")
    op.drop_index("ix_life_model_versions_logical", table_name="life_model_versions")
    op.drop_index(
        "ix_life_model_versions_owner_kind_accepted",
        table_name="life_model_versions",
    )
    op.drop_table("life_model_versions")
