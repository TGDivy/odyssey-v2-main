#!/usr/bin/env python3
"""Create, list, or revoke one-time owner recovery credentials."""

import argparse
import asyncio
import json
import os
from datetime import UTC, datetime, timedelta
from getpass import getpass
from hashlib import sha256
from pathlib import Path
from secrets import token_urlsafe
from uuid import UUID

from sqlalchemy import select

from odyssey.auth.persistence import OwnerIdentityRecord, OwnerRecoveryCredentialRecord
from odyssey.auth.recovery_material import encrypt_recovery_material
from odyssey.auth.service import OWNER_ID
from odyssey.config import get_settings
from odyssey.db.session import Database
from odyssey.domain.common import new_uuid7


def aware(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def public_record(record: OwnerRecoveryCredentialRecord, *, now: datetime) -> dict[str, object]:
    if record.consumed_at is not None:
        status = "consumed"
    elif record.revoked_at is not None:
        status = "revoked"
    elif aware(record.expires_at) <= now:
        status = "expired"
    else:
        status = "available"
    return {
        "id": str(record.id),
        "label": record.label,
        "status": status,
        "created_at": aware(record.created_at).isoformat(),
        "expires_at": aware(record.expires_at).isoformat(),
        "created_by": record.created_by,
        "consumed_at": aware(record.consumed_at).isoformat() if record.consumed_at else None,
        "consumed_by_device_id": (
            str(record.consumed_by_device_id) if record.consumed_by_device_id else None
        ),
        "revoked_at": aware(record.revoked_at).isoformat() if record.revoked_at else None,
        "revoked_by": record.revoked_by,
    }


def write_owner_only(path: Path, content: dict[str, object]) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(content, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
    except Exception:
        path.unlink(missing_ok=True)
        raise


def resolved_path(value: str) -> Path:
    return Path(value).expanduser().resolve()


def recovery_passphrase() -> str:
    passphrase = getpass("Recovery bundle passphrase: ")
    confirmation = getpass("Confirm recovery bundle passphrase: ")
    if passphrase != confirmation:
        raise RuntimeError("recovery bundle passphrases did not match")
    return passphrase


async def run(arguments: argparse.Namespace) -> None:
    database = Database(arguments.database_url or get_settings().database_url)
    now = datetime.now(UTC)
    try:
        if arguments.action == "create":
            async with database.sessions() as session:
                identity = await session.get(OwnerIdentityRecord, OWNER_ID)
            if identity is None:
                raise RuntimeError("bootstrap the owner identity before creating recovery material")
            raw_credential = f"odyssey-recovery-v1_{token_urlsafe(32)}"
            record = OwnerRecoveryCredentialRecord(
                id=new_uuid7(),
                owner_id=OWNER_ID,
                credential_hash=sha256(raw_credential.encode()).hexdigest(),
                label=arguments.label,
                created_at=now,
                expires_at=now + timedelta(days=arguments.valid_days),
                created_by=arguments.created_by,
            )
            output_path: Path = arguments.output
            encrypted_material = encrypt_recovery_material(
                {
                    "credential": raw_credential,
                    "credential_id": str(record.id),
                    "expires_at": record.expires_at.isoformat(),
                    "label": record.label,
                },
                passphrase=arguments.passphrase,
            )
            await asyncio.to_thread(
                write_owner_only,
                output_path,
                encrypted_material,
            )
            try:
                async with database.sessions() as session, session.begin():
                    session.add(record)
            except Exception:
                await asyncio.to_thread(output_path.unlink, missing_ok=True)
                raise
            result = {
                "created": public_record(record, now=now),
                "credential_file": str(output_path),
                "encrypted": True,
                "file_mode": "0600",
            }
        elif arguments.action == "list":
            async with database.sessions() as session:
                records = tuple(
                    (
                        await session.scalars(
                            select(OwnerRecoveryCredentialRecord).order_by(
                                OwnerRecoveryCredentialRecord.created_at,
                                OwnerRecoveryCredentialRecord.id,
                            )
                        )
                    ).all()
                )
            result = {"credentials": [public_record(record, now=now) for record in records]}
        else:
            async with database.sessions() as session, session.begin():
                existing_record = await session.get(
                    OwnerRecoveryCredentialRecord,
                    UUID(arguments.credential_id),
                )
                if existing_record is None:
                    raise RuntimeError("recovery credential was not found")
                if existing_record.consumed_at is not None:
                    raise RuntimeError("a consumed recovery credential cannot be revoked")
                if existing_record.revoked_at is None:
                    existing_record.revoked_at = now
                    existing_record.revoked_by = arguments.revoked_by
            result = {"revoked": public_record(existing_record, now=now)}
        print(json.dumps(result, indent=2, sort_keys=True))
    finally:
        await database.dispose()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database-url")
    subparsers = parser.add_subparsers(dest="action", required=True)
    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--label", required=True, choices=("primary", "secondary", "drill"))
    create_parser.add_argument("--created-by", required=True)
    create_parser.add_argument("--valid-days", type=int, default=365, choices=range(1, 3651))
    create_parser.add_argument("--output", required=True, type=resolved_path)
    subparsers.add_parser("list")
    revoke_parser = subparsers.add_parser("revoke")
    revoke_parser.add_argument("credential_id")
    revoke_parser.add_argument("--revoked-by", required=True)
    arguments = parser.parse_args()
    if arguments.action == "create":
        arguments.passphrase = recovery_passphrase()
    asyncio.run(run(arguments))


if __name__ == "__main__":
    main()
