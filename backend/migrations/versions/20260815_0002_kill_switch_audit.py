"""Add append-only operational kill-switch audit records.

Revision ID: 20260815_0002
Revises: 20260815_0001
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0002"
down_revision: str | None = "20260815_0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "kill_switch_audit",
        sa.Column(
            "sequence",
            sa.BigInteger().with_variant(sa.Integer(), "sqlite"),
            autoincrement=True,
            nullable=False,
        ),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("key", sa.String(length=100), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("changed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("changed_by", sa.String(length=255), nullable=False),
        sa.Column("change_source", sa.String(length=100), nullable=False),
        sa.Column("correlation_id", sa.String(length=255)),
        sa.ForeignKeyConstraint(
            ["key"], ["kill_switches.key"], name="fk_kill_switch_audit_key_kill_switches"
        ),
        sa.PrimaryKeyConstraint("sequence", name="pk_kill_switch_audit"),
        sa.UniqueConstraint("id", name="uq_kill_switch_audit_id"),
    )
    op.create_index(
        "ix_kill_switch_audit_key_changed",
        "kill_switch_audit",
        ["key", "changed_at"],
    )
    create_immutable_audit_trigger()


def create_immutable_audit_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_kill_switch_audit_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'kill_switch_audit is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER kill_switch_audit_immutable
            BEFORE UPDATE OR DELETE ON kill_switch_audit
            FOR EACH ROW EXECUTE FUNCTION reject_kill_switch_audit_mutation();
            """
        )
    elif dialect == "sqlite":
        op.execute(
            """
            CREATE TRIGGER kill_switch_audit_reject_update
            BEFORE UPDATE ON kill_switch_audit
            BEGIN
              SELECT RAISE(ABORT, 'kill_switch_audit is append-only');
            END;
            """
        )
        op.execute(
            """
            CREATE TRIGGER kill_switch_audit_reject_delete
            BEFORE DELETE ON kill_switch_audit
            BEGIN
              SELECT RAISE(ABORT, 'kill_switch_audit is append-only');
            END;
            """
        )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute("DROP TRIGGER IF EXISTS kill_switch_audit_immutable ON kill_switch_audit")
        op.execute("DROP FUNCTION IF EXISTS reject_kill_switch_audit_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS kill_switch_audit_reject_update")
        op.execute("DROP TRIGGER IF EXISTS kill_switch_audit_reject_delete")
    op.drop_index("ix_kill_switch_audit_key_changed", table_name="kill_switch_audit")
    op.drop_table("kill_switch_audit")
