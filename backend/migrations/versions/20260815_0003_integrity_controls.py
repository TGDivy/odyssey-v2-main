"""Protect raw records and persist append-only integrity runs.

Revision ID: 20260815_0003
Revises: 20260815_0002
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0003"
down_revision: str | None = "20260815_0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "integrity_runs",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("checker_version", sa.String(length=100), nullable=False),
        sa.Column("checks", sa.JSON(), nullable=False),
        sa.Column("failure_codes", sa.JSON(), nullable=False),
        sa.Column("report_hash", sa.String(length=64), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_integrity_runs"),
    )
    op.create_index("ix_integrity_runs_completed", "integrity_runs", ["completed_at"])
    create_immutability_triggers()


def create_immutability_triggers() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        for table in ("source_records", "provenance_records", "integrity_runs"):
            function = f"reject_{table}_mutation"
            trigger = f"{table}_immutable"
            op.execute(
                f"""
                CREATE FUNCTION {function}() RETURNS trigger AS $$
                BEGIN
                  RAISE EXCEPTION '{table} is append-only';
                END;
                $$ LANGUAGE plpgsql;
                """
            )
            op.execute(
                f"""
                CREATE TRIGGER {trigger}
                BEFORE UPDATE OR DELETE ON {table}
                FOR EACH ROW EXECUTE FUNCTION {function}();
                """
            )
    elif dialect == "sqlite":
        for table in ("source_records", "provenance_records", "integrity_runs"):
            op.execute(
                f"""
                CREATE TRIGGER {table}_reject_update
                BEFORE UPDATE ON {table}
                BEGIN
                  SELECT RAISE(ABORT, '{table} is append-only');
                END;
                """
            )
            op.execute(
                f"""
                CREATE TRIGGER {table}_reject_delete
                BEFORE DELETE ON {table}
                BEGIN
                  SELECT RAISE(ABORT, '{table} is append-only');
                END;
                """
            )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        for table in ("source_records", "provenance_records", "integrity_runs"):
            op.execute(f"DROP TRIGGER IF EXISTS {table}_immutable ON {table}")
            op.execute(f"DROP FUNCTION IF EXISTS reject_{table}_mutation")
    elif dialect == "sqlite":
        for table in ("source_records", "provenance_records", "integrity_runs"):
            op.execute(f"DROP TRIGGER IF EXISTS {table}_reject_update")
            op.execute(f"DROP TRIGGER IF EXISTS {table}_reject_delete")
    op.drop_index("ix_integrity_runs_completed", table_name="integrity_runs")
    op.drop_table("integrity_runs")
