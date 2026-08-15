"""Add content-addressed attachment and resumable upload manifests.

Revision ID: 20260815_0005
Revises: 20260815_0004
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0005"
down_revision: str | None = "20260815_0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "attachment_objects",
        sa.Column("content_sha256", sa.String(length=64), nullable=False),
        sa.Column("byte_size", sa.BigInteger(), nullable=False),
        sa.Column("storage_key", sa.String(length=1024), nullable=False),
        sa.Column("verified_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("content_sha256", name="pk_attachment_objects"),
        sa.UniqueConstraint("storage_key", name="uq_attachment_objects_storage_key"),
    )
    op.create_table(
        "attachments",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=255), nullable=False),
        sa.Column("expected_content_sha256", sa.String(length=64), nullable=False),
        sa.Column("object_content_sha256", sa.String(length=64)),
        sa.Column("byte_size", sa.BigInteger(), nullable=False),
        sa.Column("media_type", sa.String(length=200), nullable=False),
        sa.Column("sensitivity_class", sa.String(length=50), nullable=False),
        sa.Column("encryption_mode", sa.String(length=30), nullable=False),
        sa.Column("encryption_metadata", sa.JSON(), nullable=False),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("committed_at", sa.DateTime(timezone=True)),
        sa.Column("deleted_at", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(
            ["object_content_sha256"],
            ["attachment_objects.content_sha256"],
            name="fk_attachments_object_content_sha256_attachment_objects",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_attachments"),
    )
    op.create_table(
        "attachment_uploads",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("attachment_id", sa.Uuid(), nullable=False),
        sa.Column("token_nonce", sa.Uuid(), nullable=False),
        sa.Column("chunk_size", sa.Integer(), nullable=False),
        sa.Column("expected_chunks", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(
            ["attachment_id"],
            ["attachments.id"],
            name="fk_attachment_uploads_attachment_id_attachments",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_attachment_uploads"),
        sa.UniqueConstraint("token_nonce", name="uq_attachment_uploads_token_nonce"),
    )
    op.create_table(
        "attachment_chunks",
        sa.Column("upload_id", sa.Uuid(), nullable=False),
        sa.Column("chunk_index", sa.Integer(), nullable=False),
        sa.Column("byte_offset", sa.BigInteger(), nullable=False),
        sa.Column("byte_size", sa.Integer(), nullable=False),
        sa.Column("content_sha256", sa.String(length=64), nullable=False),
        sa.Column("storage_key", sa.String(length=1024), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["upload_id"],
            ["attachment_uploads.id"],
            name="fk_attachment_chunks_upload_id_attachment_uploads",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("upload_id", "chunk_index", name="pk_attachment_chunks"),
    )
    op.create_index(
        "ix_attachments_owner_created",
        "attachments",
        ["owner_id", "created_at"],
    )
    op.create_index("ix_attachments_status", "attachments", ["status", "created_at"])
    op.create_index(
        "ix_attachments_expected_hash",
        "attachments",
        ["expected_content_sha256"],
    )
    op.create_index(
        "ix_attachment_uploads_attachment",
        "attachment_uploads",
        ["attachment_id", "created_at"],
    )
    op.create_index(
        "ix_attachment_uploads_status_expiry",
        "attachment_uploads",
        ["status", "expires_at"],
    )
    op.create_index(
        "ix_attachment_chunks_received",
        "attachment_chunks",
        ["received_at"],
    )
    create_immutable_manifest_triggers()


def create_immutable_manifest_triggers() -> None:
    immutable_tables = ("attachment_objects", "attachment_chunks")
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        for table in immutable_tables:
            op.execute(
                f"""
                CREATE FUNCTION reject_{table}_mutation() RETURNS trigger AS $$
                BEGIN
                  RAISE EXCEPTION '{table} is append-only';
                END;
                $$ LANGUAGE plpgsql;
                """
            )
            op.execute(
                f"""
                CREATE TRIGGER {table}_immutable
                BEFORE UPDATE OR DELETE ON {table}
                FOR EACH ROW EXECUTE FUNCTION reject_{table}_mutation();
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
                END
                """
            )
            op.execute(
                f"""
                CREATE TRIGGER {table}_reject_delete
                BEFORE DELETE ON {table}
                BEGIN
                  SELECT RAISE(ABORT, '{table} is append-only');
                END
                """
            )


def downgrade() -> None:
    immutable_tables = ("attachment_objects", "attachment_chunks")
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        for table in immutable_tables:
            op.execute(f"DROP TRIGGER IF EXISTS {table}_immutable ON {table}")
            op.execute(f"DROP FUNCTION IF EXISTS reject_{table}_mutation")
    elif dialect == "sqlite":
        for table in immutable_tables:
            op.execute(f"DROP TRIGGER IF EXISTS {table}_reject_update")
            op.execute(f"DROP TRIGGER IF EXISTS {table}_reject_delete")
    op.drop_index("ix_attachment_chunks_received", table_name="attachment_chunks")
    op.drop_index("ix_attachment_uploads_status_expiry", table_name="attachment_uploads")
    op.drop_index("ix_attachment_uploads_attachment", table_name="attachment_uploads")
    op.drop_index("ix_attachments_expected_hash", table_name="attachments")
    op.drop_index("ix_attachments_status", table_name="attachments")
    op.drop_index("ix_attachments_owner_created", table_name="attachments")
    op.drop_table("attachment_chunks")
    op.drop_table("attachment_uploads")
    op.drop_table("attachments")
    op.drop_table("attachment_objects")
