"""Owner-side decryption and complete signed-manifest verification."""

import base64
import io
import json
import zipfile
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path, PurePosixPath
from typing import Any

from odyssey.exports.archive import (
    MANIFEST_NAME,
    MANIFEST_SIGNATURE_NAME,
    SIGNING_PUBLIC_KEY_NAME,
)
from odyssey.exports.crypto import (
    EXPORT_FORMAT,
    ExportCryptographyError,
    decrypt_artifact,
    verify_manifest_signature,
)

MAXIMUM_MANIFEST_BYTES = 10 * 1024 * 1024
DEFAULT_MAXIMUM_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024


class OwnerExportVerificationError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class VerifiedOwnerExport:
    decrypted_zip: bytes
    manifest: dict[str, Any]
    header: dict[str, Any]
    verified_paths: tuple[str, ...]
    total_uncompressed_bytes: int


def verify_owner_export(
    artifact: bytes,
    *,
    passphrase: str,
    expected_signing_public_key: bytes | None = None,
    maximum_uncompressed_bytes: int = DEFAULT_MAXIMUM_UNCOMPRESSED_BYTES,
) -> VerifiedOwnerExport:
    if maximum_uncompressed_bytes < 1:
        raise ValueError("maximum uncompressed export size must be positive")
    try:
        decrypted_zip, header = decrypt_artifact(artifact, passphrase=passphrase)
        with zipfile.ZipFile(io.BytesIO(decrypted_zip), mode="r") as archive:
            infos = archive.infolist()
            paths = tuple(info.filename for info in infos)
            if len(paths) != len(set(paths)):
                raise OwnerExportVerificationError("owner export contains duplicate paths")
            if len(paths) != len({path.casefold() for path in paths}):
                raise OwnerExportVerificationError("owner export contains case-colliding paths")
            for path in paths:
                _validate_archive_path(path)
            info_by_path = {info.filename: info for info in infos}
            manifest_info = info_by_path.get(MANIFEST_NAME)
            if manifest_info is None or manifest_info.file_size > MAXIMUM_MANIFEST_BYTES:
                raise OwnerExportVerificationError("owner export manifest is missing or too large")
            manifest_content = archive.read(manifest_info)
            manifest = json.loads(manifest_content)
            if not isinstance(manifest, dict) or manifest.get("format") != EXPORT_FORMAT:
                raise OwnerExportVerificationError("owner export manifest format is invalid")
            manifest_digest = sha256(manifest_content).hexdigest()
            if header.get("manifest_sha256") != manifest_digest:
                raise OwnerExportVerificationError("owner export manifest hash does not match")
            signature = _decode_base64(header.get("manifest_signature"), expected_length=64)
            public_key = _decode_base64(header.get("signing_public_key"), expected_length=32)
            if (
                expected_signing_public_key is not None
                and public_key != expected_signing_public_key
            ):
                raise OwnerExportVerificationError(
                    "owner export signing key does not match the pinned key"
                )
            verify_manifest_signature(
                manifest_content,
                signature=signature,
                public_key=public_key,
            )
            _verify_control_files(
                archive,
                info_by_path,
                signature=signature,
                public_key=public_key,
            )
            verified_paths, total_bytes = _verify_manifest_files(
                archive,
                info_by_path,
                manifest,
                maximum_uncompressed_bytes=maximum_uncompressed_bytes,
            )
            manifest_job_id = manifest.get("job_id")
            if not isinstance(manifest_job_id, str) or header.get("job_id") != manifest_job_id:
                raise OwnerExportVerificationError("owner export job identity does not match")
    except OwnerExportVerificationError:
        raise
    except (
        ExportCryptographyError,
        KeyError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
        RuntimeError,
        zipfile.BadZipFile,
        zipfile.LargeZipFile,
    ) as error:
        raise OwnerExportVerificationError("owner export verification failed") from error
    return VerifiedOwnerExport(
        decrypted_zip=decrypted_zip,
        manifest=manifest,
        header=header,
        verified_paths=verified_paths,
        total_uncompressed_bytes=total_bytes,
    )


def extract_verified_export(export: VerifiedOwnerExport, destination: Path) -> None:
    if destination.exists():
        raise OwnerExportVerificationError("export destination already exists")
    destination.mkdir(parents=True, mode=0o700)
    try:
        with zipfile.ZipFile(io.BytesIO(export.decrypted_zip), mode="r") as archive:
            for path in export.verified_paths:
                target = destination.joinpath(*PurePosixPath(path).parts)
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                target.write_bytes(archive.read(path))
                target.chmod(0o600)
    except Exception:
        _remove_partial_tree(destination)
        raise


def _verify_control_files(
    archive: zipfile.ZipFile,
    info_by_path: dict[str, zipfile.ZipInfo],
    *,
    signature: bytes,
    public_key: bytes,
) -> None:
    expected_controls = {
        MANIFEST_NAME,
        MANIFEST_SIGNATURE_NAME,
        SIGNING_PUBLIC_KEY_NAME,
    }
    if not expected_controls.issubset(info_by_path):
        raise OwnerExportVerificationError("owner export control files are incomplete")
    if (
        info_by_path[MANIFEST_SIGNATURE_NAME].file_size > 1024
        or info_by_path[SIGNING_PUBLIC_KEY_NAME].file_size > 1024
    ):
        raise OwnerExportVerificationError("owner export control file is too large")
    encoded_signature = archive.read(info_by_path[MANIFEST_SIGNATURE_NAME]).strip()
    encoded_public_key = archive.read(info_by_path[SIGNING_PUBLIC_KEY_NAME]).strip()
    if _decode_base64(encoded_signature, expected_length=64) != signature:
        raise OwnerExportVerificationError("manifest signature control file does not match")
    if _decode_base64(encoded_public_key, expected_length=32) != public_key:
        raise OwnerExportVerificationError("signing key control file does not match")


def _verify_manifest_files(
    archive: zipfile.ZipFile,
    info_by_path: dict[str, zipfile.ZipInfo],
    manifest: dict[str, Any],
    *,
    maximum_uncompressed_bytes: int,
) -> tuple[tuple[str, ...], int]:
    raw_files = manifest.get("files")
    if not isinstance(raw_files, list):
        raise OwnerExportVerificationError("owner export file manifest is invalid")
    expected_paths = {
        MANIFEST_NAME,
        MANIFEST_SIGNATURE_NAME,
        SIGNING_PUBLIC_KEY_NAME,
    }
    verified_paths: list[str] = []
    total_bytes = 0
    for raw_entry in raw_files:
        if not isinstance(raw_entry, dict):
            raise OwnerExportVerificationError("owner export file entry is invalid")
        path = raw_entry.get("path")
        expected_hash = raw_entry.get("sha256")
        expected_bytes = raw_entry.get("bytes")
        if (
            not isinstance(path, str)
            or not isinstance(expected_hash, str)
            or len(expected_hash) != 64
            or not isinstance(expected_bytes, int)
            or expected_bytes < 0
            or path in expected_paths
        ):
            raise OwnerExportVerificationError("owner export file entry is invalid")
        _validate_archive_path(path)
        info = info_by_path.get(path)
        if info is None or info.file_size != expected_bytes:
            raise OwnerExportVerificationError("owner export file size does not match")
        total_bytes += expected_bytes
        if total_bytes > maximum_uncompressed_bytes:
            raise OwnerExportVerificationError("owner export exceeds the verification size limit")
        content = archive.read(info)
        if sha256(content).hexdigest() != expected_hash:
            raise OwnerExportVerificationError("owner export file hash does not match")
        expected_paths.add(path)
        verified_paths.append(path)
    if set(info_by_path) != expected_paths:
        raise OwnerExportVerificationError("owner export contains unmanifested files")
    return tuple(sorted(expected_paths)), total_bytes


def _validate_archive_path(path: str) -> None:
    parsed = PurePosixPath(path)
    if (
        not path
        or path.startswith("/")
        or "\\" in path
        or parsed.is_absolute()
        or str(parsed) != path
        or any(part in {"", ".", ".."} for part in parsed.parts)
    ):
        raise OwnerExportVerificationError("owner export contains an unsafe path")


def _decode_base64(value: object, *, expected_length: int) -> bytes:
    if isinstance(value, str):
        encoded = value.encode()
    elif isinstance(value, bytes):
        encoded = value
    else:
        raise OwnerExportVerificationError("owner export contains invalid encoded key material")
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except ValueError as error:
        raise OwnerExportVerificationError(
            "owner export contains invalid encoded key material"
        ) from error
    if len(decoded) != expected_length:
        raise OwnerExportVerificationError("owner export key material has the wrong length")
    return decoded


def _remove_partial_tree(path: Path) -> None:
    for child in sorted(path.rglob("*"), reverse=True):
        if child.is_file():
            child.unlink()
        elif child.is_dir():
            child.rmdir()
    path.rmdir()
