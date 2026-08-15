"""Add durable device operation and canonical server change logs.

Revision ID: 20260815_0004
Revises: 20260815_0003
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0004"
down_revision: str | None = "20260815_0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    create_sync_tables()
    create_sync_indexes()
    create_immutability_triggers()


def create_sync_tables() -> None:
    op.create_table(
        "sync_devices",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("last_device_sequence", sa.BigInteger(), nullable=False),
        sa.Column("last_server_cursor", sa.BigInteger(), nullable=False),
        sa.Column("client_schema_version", sa.Integer(), nullable=False),
        sa.Column("clock_skew_seconds", sa.BigInteger()),
        sa.Column("registered_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_push_at", sa.DateTime(timezone=True)),
        sa.Column("last_pull_at", sa.DateTime(timezone=True)),
        sa.PrimaryKeyConstraint("id", name="pk_sync_devices"),
    )
    op.create_table(
        "sync_state",
        sa.Column("key", sa.String(length=50), nullable=False),
        sa.Column("last_change_id", sa.BigInteger(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("key", name="pk_sync_state"),
    )
    op.create_table(
        "sync_operations",
        sa.Column("operation_id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("device_sequence", sa.BigInteger(), nullable=False),
        sa.Column("entity_type", sa.String(length=100), nullable=False),
        sa.Column("entity_id", sa.Uuid(), nullable=False),
        sa.Column("mutation_type", sa.String(length=30), nullable=False),
        sa.Column("base_revision", sa.BigInteger()),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("idempotency_key", sa.String(length=500), nullable=False),
        sa.Column("sensitivity_class", sa.String(length=50), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("canonical_revision", sa.BigInteger()),
        sa.Column("server_change_id", sa.BigInteger()),
        sa.Column("conflict_id", sa.Uuid()),
        sa.Column("result", sa.JSON(), nullable=False),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["sync_devices.id"],
            name="fk_sync_operations_device_id_sync_devices",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("operation_id", name="pk_sync_operations"),
        sa.UniqueConstraint(
            "device_id", "device_sequence", name="uq_sync_operations_device_sequence"
        ),
        sa.UniqueConstraint(
            "device_id", "idempotency_key", name="uq_sync_operations_device_idempotency"
        ),
    )
    op.create_table(
        "canonical_entities",
        sa.Column("entity_type", sa.String(length=100), nullable=False),
        sa.Column("entity_id", sa.Uuid(), nullable=False),
        sa.Column("canonical_revision", sa.BigInteger(), nullable=False),
        sa.Column("document", sa.JSON(), nullable=False),
        sa.Column("field_versions", sa.JSON(), nullable=False),
        sa.Column("content_hash", sa.String(length=64), nullable=False),
        sa.Column("tombstoned", sa.Boolean(), nullable=False),
        sa.Column("deletion_epoch", sa.BigInteger()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_operation_id", sa.Uuid(), nullable=False),
        sa.Column("last_device_id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(
            ["last_device_id"],
            ["sync_devices.id"],
            name="fk_canonical_entities_last_device_id_sync_devices",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["last_operation_id"],
            ["sync_operations.operation_id"],
            name="fk_canonical_entities_last_operation_id_sync_operations",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("entity_type", "entity_id", name="pk_canonical_entities"),
    )
    op.create_table(
        "server_changes",
        sa.Column("change_id", sa.BigInteger(), autoincrement=False, nullable=False),
        sa.Column("entity_type", sa.String(length=100), nullable=False),
        sa.Column("entity_id", sa.Uuid(), nullable=False),
        sa.Column("canonical_revision", sa.BigInteger(), nullable=False),
        sa.Column("mutation_type", sa.String(length=30), nullable=False),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("content_hash", sa.String(length=64), nullable=False),
        sa.Column("tombstone", sa.Boolean(), nullable=False),
        sa.Column("deletion_epoch", sa.BigInteger()),
        sa.Column("merge_result", sa.String(length=100), nullable=False),
        sa.Column("origin_operation_id", sa.Uuid(), nullable=False),
        sa.Column("origin_device_id", sa.Uuid(), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["origin_device_id"],
            ["sync_devices.id"],
            name="fk_server_changes_origin_device_id_sync_devices",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["origin_operation_id"],
            ["sync_operations.operation_id"],
            name="fk_server_changes_origin_operation_id_sync_operations",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("change_id", name="pk_server_changes"),
    )
    op.create_table(
        "sync_conflicts",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("operation_id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("entity_type", sa.String(length=100), nullable=False),
        sa.Column("entity_id", sa.Uuid(), nullable=False),
        sa.Column("conflict_code", sa.String(length=100), nullable=False),
        sa.Column("base_revision", sa.BigInteger()),
        sa.Column("current_revision", sa.BigInteger()),
        sa.Column("current_document", sa.JSON(), nullable=False),
        sa.Column("incoming_document", sa.JSON(), nullable=False),
        sa.Column("conflicting_fields", sa.JSON(), nullable=False),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("resolved_at", sa.DateTime(timezone=True)),
        sa.Column("resolution", sa.JSON()),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["sync_devices.id"],
            name="fk_sync_conflicts_device_id_sync_devices",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["operation_id"],
            ["sync_operations.operation_id"],
            name="fk_sync_conflicts_operation_id_sync_operations",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_sync_conflicts"),
    )
    op.create_table(
        "sync_batch_receipts",
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("idempotency_key", sa.String(length=500), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("response", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["sync_devices.id"],
            name="fk_sync_batch_receipts_device_id_sync_devices",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("device_id", "idempotency_key", name="pk_sync_batch_receipts"),
    )


def create_sync_indexes() -> None:
    op.create_index("ix_sync_operations_entity", "sync_operations", ["entity_type", "entity_id"])
    op.create_index("ix_sync_operations_received", "sync_operations", ["received_at"])
    op.create_index("ix_canonical_entities_updated", "canonical_entities", ["updated_at"])
    op.create_index(
        "ix_canonical_entities_tombstone",
        "canonical_entities",
        ["tombstoned", "deletion_epoch"],
    )
    op.create_index(
        "ix_server_changes_entity",
        "server_changes",
        ["entity_type", "entity_id", "canonical_revision"],
    )
    op.create_index("ix_server_changes_received", "server_changes", ["received_at"])
    op.create_index("ix_sync_conflicts_pending", "sync_conflicts", ["status", "created_at"])
    op.create_index("ix_sync_conflicts_entity", "sync_conflicts", ["entity_type", "entity_id"])
    op.create_index("ix_sync_batch_receipts_created", "sync_batch_receipts", ["created_at"])


def create_immutability_triggers() -> None:
    dialect = op.get_bind().dialect.name
    immutable_tables = ("sync_operations", "server_changes", "sync_batch_receipts")
    if dialect == "postgresql":
        for table in immutable_tables:
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
        for table in immutable_tables:
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
    immutable_tables = ("sync_operations", "server_changes", "sync_batch_receipts")
    if dialect == "postgresql":
        for table in immutable_tables:
            op.execute(f"DROP TRIGGER IF EXISTS {table}_immutable ON {table}")
            op.execute(f"DROP FUNCTION IF EXISTS reject_{table}_mutation")
    elif dialect == "sqlite":
        for table in immutable_tables:
            op.execute(f"DROP TRIGGER IF EXISTS {table}_reject_update")
            op.execute(f"DROP TRIGGER IF EXISTS {table}_reject_delete")
    op.drop_index("ix_sync_batch_receipts_created", table_name="sync_batch_receipts")
    op.drop_index("ix_sync_conflicts_entity", table_name="sync_conflicts")
    op.drop_index("ix_sync_conflicts_pending", table_name="sync_conflicts")
    op.drop_index("ix_server_changes_received", table_name="server_changes")
    op.drop_index("ix_server_changes_entity", table_name="server_changes")
    op.drop_index("ix_canonical_entities_tombstone", table_name="canonical_entities")
    op.drop_index("ix_canonical_entities_updated", table_name="canonical_entities")
    op.drop_index("ix_sync_operations_received", table_name="sync_operations")
    op.drop_index("ix_sync_operations_entity", table_name="sync_operations")
    op.drop_table("sync_batch_receipts")
    op.drop_table("sync_conflicts")
    op.drop_table("server_changes")
    op.drop_table("canonical_entities")
    op.drop_table("sync_operations")
    op.drop_table("sync_state")
    op.drop_table("sync_devices")
