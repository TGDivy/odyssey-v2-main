#!/usr/bin/env python3
"""Decrypt and verify an Odyssey owner export without a running service."""

import argparse
import base64
import getpass
import json
from pathlib import Path

from odyssey.exports.verification import extract_verified_export, verify_owner_export


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Decrypt and verify a signed Odyssey owner export."
    )
    parser.add_argument("artifact", type=Path, help="Encrypted .odyx artifact")
    parser.add_argument(
        "--passphrase-file",
        type=Path,
        help="Read the passphrase from a protected file instead of prompting.",
    )
    parser.add_argument(
        "--expected-signing-public-key",
        help="Pinned base64 Ed25519 public key from the authenticated job status.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Extract verified contents into a new directory.",
    )
    parser.add_argument(
        "--decrypted-zip",
        type=Path,
        help="Write the verified decrypted ZIP to a new file.",
    )
    return parser.parse_args()


def read_passphrase(path: Path | None) -> str:
    if path is None:
        return getpass.getpass("Owner export passphrase: ")
    return path.read_text().rstrip("\r\n")


def decode_expected_key(value: str | None) -> bytes | None:
    if value is None:
        return None
    decoded = base64.b64decode(value, validate=True)
    if len(decoded) != 32:
        raise ValueError("the expected Ed25519 public key must decode to 32 bytes")
    return decoded


def write_private_file(path: Path, content: bytes) -> None:
    if path.exists():
        raise FileExistsError(f"refusing to overwrite {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    path.chmod(0o600)


def main() -> None:
    args = parse_args()
    artifact = args.artifact.read_bytes()
    verified = verify_owner_export(
        artifact,
        passphrase=read_passphrase(args.passphrase_file),
        expected_signing_public_key=decode_expected_key(args.expected_signing_public_key),
    )
    if args.output_dir is not None:
        extract_verified_export(verified, args.output_dir)
    if args.decrypted_zip is not None:
        write_private_file(args.decrypted_zip, verified.decrypted_zip)
    print(
        json.dumps(
            {
                "artifact": str(args.artifact),
                "job_id": verified.manifest["job_id"],
                "manifest_sha256": verified.header["manifest_sha256"],
                "signing_public_key": verified.header["signing_public_key"],
                "verified_files": len(verified.verified_paths),
                "verified_uncompressed_bytes": verified.total_uncompressed_bytes,
                "extracted_to": str(args.output_dir) if args.output_dir else None,
                "decrypted_zip": str(args.decrypted_zip) if args.decrypted_zip else None,
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
