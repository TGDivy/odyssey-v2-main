"""Create durable ledger and projection substrate.

Revision ID: 20260815_0001
Revises:
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "provenance_records",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("source_kind", sa.String(length=100), nullable=False),
        sa.Column("source_id", sa.String(length=500), nullable=False),
        sa.Column("source_version", sa.String(length=200)),
        sa.Column("actor_type", sa.String(length=50), nullable=False),
        sa.Column("actor_id", sa.String(length=255), nullable=False),
        sa.Column("device_id", sa.Uuid()),
        sa.Column("observed_at", sa.DateTime(timezone=True)),
        sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("transformation_chain", sa.JSON(), nullable=False),
        sa.Column("model_run_id", sa.Uuid()),
        sa.Column("confidence", sa.Float()),
        sa.Column("consent_scope", sa.String(length=500)),
        sa.Column("content_hash", sa.String(length=128)),
        sa.Column("details", sa.JSON(), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_provenance_records"),
    )
    op.create_table(
        "ledger_events",
        sa.Column(
            "sequence",
            sa.BigInteger().with_variant(sa.Integer(), "sqlite"),
            autoincrement=True,
            nullable=False,
        ),
        sa.Column("event_id", sa.Uuid(), nullable=False),
        sa.Column("event_type", sa.String(length=200), nullable=False),
        sa.Column("event_schema_version", sa.Integer(), nullable=False),
        sa.Column("aggregate_type", sa.String(length=100), nullable=False),
        sa.Column("aggregate_id", sa.Uuid(), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("actor", sa.JSON(), nullable=False),
        sa.Column("correlation_id", sa.Uuid(), nullable=False),
        sa.Column("causation_id", sa.Uuid()),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("provenance_id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(
            ["provenance_id"], ["provenance_records.id"], name="fk_ledger_provenance"
        ),
        sa.PrimaryKeyConstraint("sequence", name="pk_ledger_events"),
        sa.UniqueConstraint("event_id", name="uq_ledger_events_event_id"),
    )
    op.create_index(
        "ix_ledger_events_aggregate",
        "ledger_events",
        ["aggregate_type", "aggregate_id", "sequence"],
    )
    op.create_index("ix_ledger_events_occurred_at", "ledger_events", ["occurred_at"])
    op.create_index("ix_ledger_events_correlation_id", "ledger_events", ["correlation_id"])
    op.create_table(
        "source_records",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("source_kind", sa.String(length=100), nullable=False),
        sa.Column("external_source_id", sa.String(length=500)),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("observed_at", sa.DateTime(timezone=True)),
        sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("timezone_id", sa.String(length=100)),
        sa.Column("temporal_precision", sa.String(length=30), nullable=False),
        sa.Column("content_hash", sa.String(length=128), nullable=False),
        sa.Column("sensitivity", sa.String(length=50), nullable=False),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("provenance_id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(
            ["provenance_id"], ["provenance_records.id"], name="fk_source_record_provenance"
        ),
        sa.PrimaryKeyConstraint("id", name="pk_source_records"),
    )
    op.create_index(
        "ix_source_records_kind_occurred", "source_records", ["source_kind", "occurred_at"]
    )
    op.create_table(
        "assertions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("subject_id", sa.Uuid(), nullable=False),
        sa.Column("predicate", sa.String(length=200), nullable=False),
        sa.Column("object_value", sa.JSON(), nullable=False),
        sa.Column("valid_from", sa.DateTime(timezone=True)),
        sa.Column("valid_to", sa.DateTime(timezone=True)),
        sa.Column("epistemic_status", sa.String(length=50), nullable=False),
        sa.Column("confidence", sa.Float()),
        sa.Column("supersedes_id", sa.Uuid()),
        sa.Column("retracted_at", sa.DateTime(timezone=True)),
        sa.Column("provenance_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["provenance_id"], ["provenance_records.id"], name="fk_assertion_provenance"
        ),
        sa.ForeignKeyConstraint(
            ["supersedes_id"], ["assertions.id"], name="fk_assertion_supersedes"
        ),
        sa.PrimaryKeyConstraint("id", name="pk_assertions"),
    )
    op.create_index("ix_assertions_subject_predicate", "assertions", ["subject_id", "predicate"])
    op.create_index("ix_assertions_validity", "assertions", ["valid_from", "valid_to"])
    op.create_table(
        "projection_records",
        sa.Column("projection_name", sa.String(length=100), nullable=False),
        sa.Column("projection_key", sa.String(length=500), nullable=False),
        sa.Column("document", sa.JSON(), nullable=False),
        sa.Column("source_sequence", sa.BigInteger(), nullable=False),
        sa.Column("projection_version", sa.String(length=100), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("projection_name", "projection_key", name="pk_projection_records"),
    )
    op.create_table(
        "projection_checkpoints",
        sa.Column("projection_name", sa.String(length=100), nullable=False),
        sa.Column("last_sequence", sa.BigInteger(), nullable=False),
        sa.Column("projection_version", sa.String(length=100), nullable=False),
        sa.Column("rebuilt_at", sa.DateTime(timezone=True)),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("projection_name", name="pk_projection_checkpoints"),
    )
    op.create_table(
        "outbox_records",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("topic", sa.String(length=200), nullable=False),
        sa.Column("aggregate_id", sa.Uuid(), nullable=False),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("idempotency_key", sa.String(length=500), nullable=False),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("available_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("lease_expires_at", sa.DateTime(timezone=True)),
        sa.Column("last_error_code", sa.String(length=100)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
        sa.PrimaryKeyConstraint("id", name="pk_outbox_records"),
        sa.UniqueConstraint("idempotency_key", name="uq_outbox_records_idempotency_key"),
    )
    op.create_index(
        "ix_outbox_records_claim",
        "outbox_records",
        ["status", "available_at", "created_at"],
    )
    op.create_table(
        "kill_switches",
        sa.Column("key", sa.String(length=100), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("reason", sa.Text()),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
        sa.Column("updated_by", sa.String(length=255), nullable=False),
        sa.PrimaryKeyConstraint("key", name="pk_kill_switches"),
    )
    create_immutable_ledger_trigger()


def create_immutable_ledger_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_ledger_event_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'ledger_events is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER ledger_events_immutable
            BEFORE UPDATE OR DELETE ON ledger_events
            FOR EACH ROW EXECUTE FUNCTION reject_ledger_event_mutation();
            """
        )
    elif dialect == "sqlite":
        op.execute(
            """
            CREATE TRIGGER ledger_events_reject_update
            BEFORE UPDATE ON ledger_events
            BEGIN
              SELECT RAISE(ABORT, 'ledger_events is append-only');
            END;
            """
        )
        op.execute(
            """
            CREATE TRIGGER ledger_events_reject_delete
            BEFORE DELETE ON ledger_events
            BEGIN
              SELECT RAISE(ABORT, 'ledger_events is append-only');
            END;
            """
        )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute("DROP TRIGGER IF EXISTS ledger_events_immutable ON ledger_events")
        op.execute("DROP FUNCTION IF EXISTS reject_ledger_event_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS ledger_events_reject_update")
        op.execute("DROP TRIGGER IF EXISTS ledger_events_reject_delete")
    op.drop_table("kill_switches")
    op.drop_index("ix_outbox_records_claim", table_name="outbox_records")
    op.drop_table("outbox_records")
    op.drop_table("projection_checkpoints")
    op.drop_table("projection_records")
    op.drop_index("ix_assertions_validity", table_name="assertions")
    op.drop_index("ix_assertions_subject_predicate", table_name="assertions")
    op.drop_table("assertions")
    op.drop_index("ix_source_records_kind_occurred", table_name="source_records")
    op.drop_table("source_records")
    op.drop_index("ix_ledger_events_correlation_id", table_name="ledger_events")
    op.drop_index("ix_ledger_events_occurred_at", table_name="ledger_events")
    op.drop_index("ix_ledger_events_aggregate", table_name="ledger_events")
    op.drop_table("ledger_events")
    op.drop_table("provenance_records")
