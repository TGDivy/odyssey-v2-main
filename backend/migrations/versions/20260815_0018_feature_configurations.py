"""Persist append-only signed feature configurations.

Revision ID: 20260815_0018
Revises: 20260815_0017
Create Date: 2026-08-16
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0018"
down_revision: str | None = "20260815_0017"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "feature_configurations",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("environment", sa.String(length=30), nullable=False),
        sa.Column("audience", sa.String(length=255), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("issued_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("not_before", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("key_id", sa.String(length=100), nullable=False),
        sa.Column("public_key", sa.LargeBinary(length=32), nullable=False),
        sa.Column("payload", sa.LargeBinary(length=65_536), nullable=False),
        sa.Column("payload_sha256", sa.String(length=64), nullable=False),
        sa.Column("signature", sa.LargeBinary(length=64), nullable=False),
        sa.Column("request_sha256", sa.String(length=64), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("created_by", sa.String(length=255), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "version >= 1",
            name="ck_feature_configurations_feature_configurations_version_positive",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_feature_configurations"),
        sa.UniqueConstraint(
            "owner_id",
            "environment",
            "audience",
            "version",
            name="uq_feature_configurations_owner_environment_audience_version",
        ),
    )
    op.create_index(
        "ix_feature_configurations_current",
        "feature_configurations",
        ["owner_id", "environment", "audience", "not_before", "expires_at", "version"],
    )
    create_immutable_feature_configuration_trigger()


def create_immutable_feature_configuration_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_feature_configuration_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'feature_configurations is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER feature_configurations_immutable
            BEFORE UPDATE OR DELETE ON feature_configurations
            FOR EACH ROW EXECUTE FUNCTION reject_feature_configuration_mutation();
            """
        )
    elif dialect == "sqlite":
        for action in ("UPDATE", "DELETE"):
            op.execute(
                f"""
                CREATE TRIGGER feature_configurations_reject_{action.lower()}
                BEFORE {action} ON feature_configurations
                BEGIN
                  SELECT RAISE(ABORT, 'feature_configurations is append-only');
                END;
                """
            )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            "DROP TRIGGER IF EXISTS feature_configurations_immutable ON feature_configurations"
        )
        op.execute("DROP FUNCTION IF EXISTS reject_feature_configuration_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS feature_configurations_reject_update")
        op.execute("DROP TRIGGER IF EXISTS feature_configurations_reject_delete")
    op.drop_index("ix_feature_configurations_current", table_name="feature_configurations")
    op.drop_table("feature_configurations")
