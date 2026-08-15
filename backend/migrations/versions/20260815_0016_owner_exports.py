"""Add encrypted asynchronous owner export jobs.

Revision ID: 20260815_0016
Revises: 20260815_0015
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0016"
down_revision: str | None = "20260815_0015"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "export_jobs",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("phase", sa.String(length=50), nullable=False),
        sa.Column("scope", sa.String(length=100), nullable=False),
        sa.Column("formats", sa.JSON(), nullable=False),
        sa.Column("include_raw_sources", sa.Boolean(), nullable=False),
        sa.Column("include_model_traces", sa.Boolean(), nullable=False),
        sa.Column("owner_key_envelope", sa.JSON(), nullable=False),
        sa.Column("worker_key_envelope", sa.JSON(), nullable=False),
        sa.Column("artifact_nonce", sa.LargeBinary(length=12), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("idempotency_key_hash", sa.String(length=64), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("last_error_code", sa.String(length=100)),
        sa.Column("artifact_content_hash", sa.String(length=64)),
        sa.Column("artifact_bytes", sa.BigInteger()),
        sa.Column("storage_backend", sa.String(length=30)),
        sa.Column("storage_bucket", sa.String(length=255)),
        sa.Column("storage_version_id", sa.String(length=255)),
        sa.Column("manifest_sha256", sa.String(length=64)),
        sa.Column("manifest_signature", sa.String(length=128)),
        sa.Column("signing_public_key", sa.String(length=128)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
        sa.PrimaryKeyConstraint("id", name="pk_export_jobs"),
        sa.UniqueConstraint("idempotency_key_hash", name="uq_export_jobs_idempotency_key_hash"),
    )
    op.create_index(
        "ix_export_jobs_owner_created",
        "export_jobs",
        ["owner_id", "created_at"],
    )
    op.create_table(
        "export_job_audit",
        sa.Column(
            "sequence",
            sa.BigInteger().with_variant(sa.Integer(), "sqlite"),
            autoincrement=True,
            nullable=False,
        ),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("job_id", sa.Uuid(), nullable=False),
        sa.Column("event_type", sa.String(length=50), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("details", sa.JSON(), nullable=False),
        sa.PrimaryKeyConstraint("sequence", name="pk_export_job_audit"),
        sa.UniqueConstraint("id", name="uq_export_job_audit_id"),
    )
    op.create_index(
        "ix_export_job_audit_job_time",
        "export_job_audit",
        ["job_id", "occurred_at"],
    )
    create_immutable_export_audit_trigger()


def create_immutable_export_audit_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_export_job_audit_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'export_job_audit is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER export_job_audit_immutable
            BEFORE UPDATE OR DELETE ON export_job_audit
            FOR EACH ROW EXECUTE FUNCTION reject_export_job_audit_mutation();
            """
        )
    elif dialect == "sqlite":
        for action in ("UPDATE", "DELETE"):
            op.execute(
                f"""
                CREATE TRIGGER export_job_audit_reject_{action.lower()}
                BEFORE {action} ON export_job_audit
                BEGIN
                  SELECT RAISE(ABORT, 'export_job_audit is append-only');
                END;
                """
            )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute("DROP TRIGGER IF EXISTS export_job_audit_immutable ON export_job_audit")
        op.execute("DROP FUNCTION IF EXISTS reject_export_job_audit_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS export_job_audit_reject_update")
        op.execute("DROP TRIGGER IF EXISTS export_job_audit_reject_delete")
    op.drop_index("ix_export_job_audit_job_time", table_name="export_job_audit")
    op.drop_table("export_job_audit")
    op.drop_index("ix_export_jobs_owner_created", table_name="export_jobs")
    op.drop_table("export_jobs")
