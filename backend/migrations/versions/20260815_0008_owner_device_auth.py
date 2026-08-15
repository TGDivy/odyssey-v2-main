"""Add single-owner identity and revocable device authentication.

Revision ID: 20260815_0008
Revises: 20260815_0007
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0008"
down_revision: str | None = "20260815_0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "owner_identities",
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("apple_subject", sa.String(length=255), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_authenticated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("owner_id = 'owner'", name="single_owner_identity"),
        sa.PrimaryKeyConstraint("owner_id", name="pk_owner_identities"),
        sa.UniqueConstraint("apple_subject", name="uq_owner_identities_apple_subject"),
    )
    op.create_table(
        "apple_auth_challenges",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("nonce_hash", sa.String(length=64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True)),
        sa.Column("identity_token_hash", sa.String(length=64)),
        sa.PrimaryKeyConstraint("id", name="pk_apple_auth_challenges"),
        sa.UniqueConstraint("nonce_hash", name="uq_apple_auth_challenges_nonce_hash"),
    )
    op.create_index(
        "ix_apple_auth_challenges_expires",
        "apple_auth_challenges",
        ["expires_at"],
    )
    op.create_table(
        "auth_devices",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.String(length=50), nullable=False),
        sa.Column("display_name", sa.String(length=100), nullable=False),
        sa.Column("platform", sa.String(length=30), nullable=False),
        sa.Column("app_version", sa.String(length=100), nullable=False),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("enrolled_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_authenticated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.Column("revocation_reason", sa.String(length=50)),
        sa.ForeignKeyConstraint(
            ["owner_id"],
            ["owner_identities.owner_id"],
            name="fk_auth_devices_owner_id_owner_identities",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_auth_devices"),
    )
    op.create_index("ix_auth_devices_last_seen", "auth_devices", ["last_seen_at"])
    op.create_index(
        "ix_auth_devices_owner_status",
        "auth_devices",
        ["owner_id", "status"],
    )
    op.create_table(
        "auth_device_credentials",
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("credential_hash", sa.String(length=64), nullable=False),
        sa.Column("issued_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_used_at", sa.DateTime(timezone=True)),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["auth_devices.id"],
            name="fk_auth_device_credentials_device_id_auth_devices",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("device_id", name="pk_auth_device_credentials"),
        sa.UniqueConstraint(
            "credential_hash",
            name="uq_auth_device_credentials_hash",
        ),
    )
    op.create_index(
        "ix_auth_device_credentials_expires",
        "auth_device_credentials",
        ["expires_at"],
    )
    op.create_table(
        "auth_device_audit",
        sa.Column(
            "sequence",
            sa.BigInteger().with_variant(sa.Integer(), "sqlite"),
            autoincrement=True,
            nullable=False,
        ),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("event_type", sa.String(length=50), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("actor_device_id", sa.Uuid()),
        sa.Column("reason_code", sa.String(length=50)),
        sa.Column("details", sa.JSON(), nullable=False),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["auth_devices.id"],
            name="fk_auth_device_audit_device_id_auth_devices",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("sequence", name="pk_auth_device_audit"),
        sa.UniqueConstraint("id", name="uq_auth_device_audit_id"),
    )
    op.create_index(
        "ix_auth_device_audit_device_occurred",
        "auth_device_audit",
        ["device_id", "occurred_at"],
    )
    create_immutable_auth_audit_trigger()


def create_immutable_auth_audit_trigger() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute(
            """
            CREATE FUNCTION reject_auth_device_audit_mutation() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'auth_device_audit is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """
        )
        op.execute(
            """
            CREATE TRIGGER auth_device_audit_immutable
            BEFORE UPDATE OR DELETE ON auth_device_audit
            FOR EACH ROW EXECUTE FUNCTION reject_auth_device_audit_mutation();
            """
        )
    elif dialect == "sqlite":
        for action in ("UPDATE", "DELETE"):
            op.execute(
                f"""
                CREATE TRIGGER auth_device_audit_reject_{action.lower()}
                BEFORE {action} ON auth_device_audit
                BEGIN
                  SELECT RAISE(ABORT, 'auth_device_audit is append-only');
                END;
                """
            )


def downgrade() -> None:
    dialect = op.get_bind().dialect.name
    if dialect == "postgresql":
        op.execute("DROP TRIGGER IF EXISTS auth_device_audit_immutable ON auth_device_audit")
        op.execute("DROP FUNCTION IF EXISTS reject_auth_device_audit_mutation")
    elif dialect == "sqlite":
        op.execute("DROP TRIGGER IF EXISTS auth_device_audit_reject_update")
        op.execute("DROP TRIGGER IF EXISTS auth_device_audit_reject_delete")
    op.drop_index("ix_auth_device_audit_device_occurred", table_name="auth_device_audit")
    op.drop_table("auth_device_audit")
    op.drop_index("ix_auth_device_credentials_expires", table_name="auth_device_credentials")
    op.drop_table("auth_device_credentials")
    op.drop_index("ix_auth_devices_owner_status", table_name="auth_devices")
    op.drop_index("ix_auth_devices_last_seen", table_name="auth_devices")
    op.drop_table("auth_devices")
    op.drop_index("ix_apple_auth_challenges_expires", table_name="apple_auth_challenges")
    op.drop_table("apple_auth_challenges")
    op.drop_table("owner_identities")
