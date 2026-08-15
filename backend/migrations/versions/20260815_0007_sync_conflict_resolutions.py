"""Add immutable sync conflict resolution records.

Revision ID: 20260815_0007
Revises: 20260815_0006
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0007"
down_revision: str | None = "20260815_0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "sync_conflict_resolutions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("conflict_id", sa.Uuid(), nullable=False),
        sa.Column("operation_id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("strategy", sa.String(length=30), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("resolved_document", sa.JSON(), nullable=False),
        sa.Column("response", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["conflict_id"],
            ["sync_conflicts.id"],
            name="fk_sync_conflict_resolutions_conflict_id_sync_conflicts",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["operation_id"],
            ["sync_operations.operation_id"],
            name="fk_sync_conflict_resolutions_operation_id_sync_operations",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["sync_devices.id"],
            name="fk_sync_conflict_resolutions_device_id_sync_devices",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_sync_conflict_resolutions"),
        sa.UniqueConstraint(
            "conflict_id",
            name="uq_sync_conflict_resolutions_conflict_id",
        ),
        sa.UniqueConstraint(
            "operation_id",
            name="uq_sync_conflict_resolutions_operation_id",
        ),
    )
    op.create_index(
        "ix_sync_conflict_resolutions_created",
        "sync_conflict_resolutions",
        ["created_at"],
    )
    create_immutable_resolution_trigger()


def create_immutable_resolution_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_sync_conflict_resolutions_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'sync_conflict_resolutions is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER sync_conflict_resolutions_immutable
            BEFORE UPDATE OR DELETE ON sync_conflict_resolutions
            FOR EACH ROW EXECUTE FUNCTION reject_sync_conflict_resolutions_mutation();
            """
        )
    elif dialect == "sqlite":
        op.execute(
            """
            CREATE TRIGGER sync_conflict_resolutions_reject_update
            BEFORE UPDATE ON sync_conflict_resolutions
            BEGIN
              SELECT RAISE(ABORT, 'sync_conflict_resolutions is append-only');
            END
            """
        )
        op.execute(
            """
            CREATE TRIGGER sync_conflict_resolutions_reject_delete
            BEFORE DELETE ON sync_conflict_resolutions
            BEGIN
              SELECT RAISE(ABORT, 'sync_conflict_resolutions is append-only');
            END
            """
        )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            "DROP TRIGGER IF EXISTS sync_conflict_resolutions_immutable "
            "ON sync_conflict_resolutions"
        )
        op.execute("DROP FUNCTION IF EXISTS reject_sync_conflict_resolutions_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS sync_conflict_resolutions_reject_update")
        op.execute("DROP TRIGGER IF EXISTS sync_conflict_resolutions_reject_delete")
    op.drop_index(
        "ix_sync_conflict_resolutions_created",
        table_name="sync_conflict_resolutions",
    )
    op.drop_table("sync_conflict_resolutions")
