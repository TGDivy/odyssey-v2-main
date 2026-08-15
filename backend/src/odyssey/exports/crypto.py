"""Passphrase and worker key envelopes for encrypted owner exports."""

import json
import struct
from base64 import b64decode, b64encode
from hashlib import sha256
from hmac import digest as hmac_digest
from os import urandom
from typing import Any
from uuid import UUID

from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

EXPORT_FORMAT = "odyssey-owner-export-v1"
MAGIC = b"ODYSSEY-EXPORT-V1\n"
SCRYPT_LENGTH = 32
SCRYPT_N = 2**15
SCRYPT_R = 8
SCRYPT_P = 1
MAXIMUM_HEADER_BYTES = 64 * 1024


class ExportCryptographyError(RuntimeError):
    pass


class ExportKeyManager:
    def __init__(self, wrapping_secret: str) -> None:
        self._secret = wrapping_secret.encode()

    @property
    def configured(self) -> bool:
        return len(self._secret) >= 32

    def generate_data_key(self) -> bytes:
        self.require_configured()
        return urandom(32)

    def wrap_for_worker(self, data_key: bytes, *, job_id: UUID) -> dict[str, str]:
        self.require_configured()
        nonce = urandom(12)
        ciphertext = AESGCM(self._worker_key()).encrypt(
            nonce,
            data_key,
            _worker_associated_data(job_id),
        )
        return {
            "algorithm": "aes-256-gcm",
            "nonce": b64encode(nonce).decode(),
            "ciphertext": b64encode(ciphertext).decode(),
        }

    def unwrap_for_worker(self, envelope: dict[str, Any], *, job_id: UUID) -> bytes:
        self.require_configured()
        try:
            if envelope.get("algorithm") != "aes-256-gcm":
                raise ValueError("unsupported worker key envelope")
            nonce = _decode(envelope["nonce"], expected_length=12)
            ciphertext = _decode(envelope["ciphertext"], maximum_length=128)
            key = AESGCM(self._worker_key()).decrypt(
                nonce,
                ciphertext,
                _worker_associated_data(job_id),
            )
        except (InvalidTag, KeyError, TypeError, ValueError) as error:
            raise ExportCryptographyError("export worker key could not be unwrapped") from error
        if len(key) != 32:
            raise ExportCryptographyError("export worker key could not be unwrapped")
        return key

    def sign_manifest(self, manifest: bytes) -> tuple[bytes, bytes]:
        self.require_configured()
        private_key = self._signing_key()
        signature = private_key.sign(manifest)
        public_key = private_key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        return signature, public_key

    def passphrase_fingerprint(self, passphrase: str) -> str:
        self.require_configured()
        require_passphrase(passphrase)
        return hmac_digest(
            self._worker_key(),
            b"odyssey-export-passphrase-fingerprint-v1\0" + passphrase.encode(),
            "sha256",
        ).hex()

    def require_configured(self) -> None:
        if not self.configured:
            raise ExportCryptographyError("owner export encryption is not configured")

    def _worker_key(self) -> bytes:
        return sha256(b"odyssey-export-worker-key-v1\0" + self._secret).digest()

    def _signing_key(self) -> Ed25519PrivateKey:
        seed = sha256(b"odyssey-export-signing-key-v1\0" + self._secret).digest()
        return Ed25519PrivateKey.from_private_bytes(seed)


def wrap_for_owner(data_key: bytes, *, passphrase: str, job_id: UUID) -> dict[str, object]:
    require_passphrase(passphrase)
    salt = urandom(16)
    nonce = urandom(12)
    ciphertext = AESGCM(_derive_owner_key(passphrase, salt)).encrypt(
        nonce,
        data_key,
        _owner_associated_data(job_id),
    )
    return {
        "kdf": {
            "name": "scrypt",
            "length": SCRYPT_LENGTH,
            "n": SCRYPT_N,
            "r": SCRYPT_R,
            "p": SCRYPT_P,
            "salt": b64encode(salt).decode(),
        },
        "cipher": {
            "name": "aes-256-gcm",
            "nonce": b64encode(nonce).decode(),
            "ciphertext": b64encode(ciphertext).decode(),
        },
    }


def unwrap_for_owner(
    envelope: dict[str, Any],
    *,
    passphrase: str,
    job_id: UUID,
) -> bytes:
    require_passphrase(passphrase)
    try:
        kdf = envelope["kdf"]
        cipher = envelope["cipher"]
        if (
            not isinstance(kdf, dict)
            or kdf.get("name") != "scrypt"
            or kdf.get("length") != SCRYPT_LENGTH
            or kdf.get("n") != SCRYPT_N
            or kdf.get("r") != SCRYPT_R
            or kdf.get("p") != SCRYPT_P
            or not isinstance(cipher, dict)
            or cipher.get("name") != "aes-256-gcm"
        ):
            raise ValueError("unsupported owner key envelope")
        salt = _decode(kdf["salt"], expected_length=16)
        nonce = _decode(cipher["nonce"], expected_length=12)
        ciphertext = _decode(cipher["ciphertext"], maximum_length=128)
        key = AESGCM(_derive_owner_key(passphrase, salt)).decrypt(
            nonce,
            ciphertext,
            _owner_associated_data(job_id),
        )
    except (InvalidTag, KeyError, TypeError, ValueError) as error:
        raise ExportCryptographyError("owner export passphrase or envelope is invalid") from error
    if len(key) != 32:
        raise ExportCryptographyError("owner export passphrase or envelope is invalid")
    return key


def encrypt_artifact(
    plaintext: bytes,
    *,
    data_key: bytes,
    artifact_nonce: bytes,
    job_id: UUID,
    owner_key_envelope: dict[str, Any],
    manifest_sha256: str,
    manifest_signature: bytes,
    signing_public_key: bytes,
) -> bytes:
    if len(data_key) != 32 or len(artifact_nonce) != 12:
        raise ExportCryptographyError("invalid export artifact key material")
    associated_data = _artifact_associated_data(job_id)
    ciphertext = AESGCM(data_key).encrypt(artifact_nonce, plaintext, associated_data)
    header = {
        "format": EXPORT_FORMAT,
        "job_id": str(job_id),
        "owner_key_envelope": owner_key_envelope,
        "artifact_cipher": {
            "name": "aes-256-gcm",
            "nonce": b64encode(artifact_nonce).decode(),
            "associated_data": associated_data.decode(),
        },
        "manifest_sha256": manifest_sha256,
        "manifest_signature": b64encode(manifest_signature).decode(),
        "signing_public_key": b64encode(signing_public_key).decode(),
    }
    encoded_header = json.dumps(header, separators=(",", ":"), sort_keys=True).encode()
    if len(encoded_header) > MAXIMUM_HEADER_BYTES:
        raise ExportCryptographyError("export artifact header is too large")
    return MAGIC + struct.pack(">I", len(encoded_header)) + encoded_header + ciphertext


def decrypt_artifact(content: bytes, *, passphrase: str) -> tuple[bytes, dict[str, Any]]:
    header, ciphertext = parse_artifact(content)
    try:
        job_id = UUID(header["job_id"])
        owner_envelope = header["owner_key_envelope"]
        cipher = header["artifact_cipher"]
        if (
            header.get("format") != EXPORT_FORMAT
            or not isinstance(owner_envelope, dict)
            or not isinstance(cipher, dict)
            or cipher.get("name") != "aes-256-gcm"
        ):
            raise ValueError("unsupported export artifact")
        nonce = _decode(cipher["nonce"], expected_length=12)
        associated_data = str(cipher["associated_data"]).encode()
        if associated_data != _artifact_associated_data(job_id):
            raise ValueError("invalid export associated data")
        data_key = unwrap_for_owner(
            owner_envelope,
            passphrase=passphrase,
            job_id=job_id,
        )
        plaintext = AESGCM(data_key).decrypt(nonce, ciphertext, associated_data)
    except (InvalidTag, KeyError, TypeError, ValueError) as error:
        raise ExportCryptographyError("owner export could not be decrypted") from error
    return plaintext, header


def parse_artifact(content: bytes) -> tuple[dict[str, Any], bytes]:
    try:
        if not content.startswith(MAGIC) or len(content) < len(MAGIC) + 4:
            raise ValueError("invalid export artifact magic")
        offset = len(MAGIC)
        header_length = struct.unpack(">I", content[offset : offset + 4])[0]
        if header_length < 2 or header_length > MAXIMUM_HEADER_BYTES:
            raise ValueError("invalid export artifact header")
        header_start = offset + 4
        header_end = header_start + header_length
        header = json.loads(content[header_start:header_end])
        ciphertext = content[header_end:]
        if not isinstance(header, dict) or len(ciphertext) < 16:
            raise ValueError("invalid export artifact body")
        return header, ciphertext
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise ExportCryptographyError("owner export artifact is invalid") from error


def verify_manifest_signature(
    manifest: bytes,
    *,
    signature: bytes,
    public_key: bytes,
) -> None:
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, manifest)
    except (InvalidSignature, ValueError) as error:
        raise ExportCryptographyError("owner export manifest signature is invalid") from error


def require_passphrase(passphrase: str) -> None:
    if len(passphrase) < 16 or len(passphrase) > 1024:
        raise ExportCryptographyError(
            "owner export passphrase must contain between 16 and 1024 characters"
        )


def _derive_owner_key(passphrase: str, salt: bytes) -> bytes:
    return Scrypt(
        salt=salt,
        length=SCRYPT_LENGTH,
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
    ).derive(passphrase.encode())


def _decode(
    value: object,
    *,
    expected_length: int | None = None,
    maximum_length: int | None = None,
) -> bytes:
    if not isinstance(value, str):
        raise ValueError("encoded value must be a string")
    decoded = b64decode(value, validate=True)
    if expected_length is not None and len(decoded) != expected_length:
        raise ValueError("encoded value has the wrong length")
    if maximum_length is not None and len(decoded) > maximum_length:
        raise ValueError("encoded value is too large")
    return decoded


def _worker_associated_data(job_id: UUID) -> bytes:
    return f"odyssey-export-worker-key-v1:{job_id}".encode()


def _owner_associated_data(job_id: UUID) -> bytes:
    return f"odyssey-export-owner-key-v1:{job_id}".encode()


def _artifact_associated_data(job_id: UUID) -> bytes:
    return f"odyssey-owner-export-v1:{job_id}".encode()
