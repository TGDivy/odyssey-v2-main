"""Track attachment object backend and immutable provider version.

Revision ID: 20260815_0010
Revises: 20260815_0009
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260815_0010"
down_revision: str | None = "20260815_0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("attachment_objects") as batch_op:
        batch_op.add_column(
            sa.Column(
                "storage_backend",
                sa.String(length=30),
                nullable=False,
                server_default="local",
            )
        )
        batch_op.add_column(sa.Column("bucket_name", sa.String(length=255)))
        batch_op.add_column(sa.Column("object_version_id", sa.String(length=255)))
    if op.get_bind().dialect.name != "sqlite":
        op.alter_column("attachment_objects", "storage_backend", server_default=None)


def downgrade() -> None:
    with op.batch_alter_table("attachment_objects") as batch_op:
        batch_op.drop_column("object_version_id")
        batch_op.drop_column("bucket_name")
        batch_op.drop_column("storage_backend")
