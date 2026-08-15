"""Versioned encryption envelope for offline owner recovery material."""

import json
from base64 import b64decode, b64encode
from os import urandom
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

FORMAT = "odyssey-owner-recovery-v1"
ASSOCIATED_DATA = FORMAT.encode()
SCRYPT_LENGTH = 32
SCRYPT_N = 2**15
SCRYPT_R = 8
SCRYPT_P = 1


class RecoveryMaterialError(RuntimeError):
    pass


def encrypt_recovery_material(
    material: dict[str, str],
    *,
    passphrase: str,
) -> dict[str, object]:
    require_passphrase(passphrase)
    salt = urandom(16)
    nonce = urandom(12)
    key = derive_key(passphrase, salt=salt)
    plaintext = json.dumps(material, separators=(",", ":"), sort_keys=True).encode()
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, ASSOCIATED_DATA)
    return {
        "format": FORMAT,
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


def decrypt_recovery_material(
    envelope: dict[str, Any],
    *,
    passphrase: str,
) -> dict[str, str]:
    require_passphrase(passphrase)
    try:
        kdf = envelope["kdf"]
        cipher = envelope["cipher"]
        if (
            envelope["format"] != FORMAT
            or not isinstance(kdf, dict)
            or kdf.get("name") != "scrypt"
            or kdf.get("length") != SCRYPT_LENGTH
            or kdf.get("n") != SCRYPT_N
            or kdf.get("r") != SCRYPT_R
            or kdf.get("p") != SCRYPT_P
            or not isinstance(cipher, dict)
            or cipher.get("name") != "aes-256-gcm"
        ):
            raise ValueError("unsupported recovery envelope")
        encoded_salt = kdf["salt"]
        encoded_nonce = cipher["nonce"]
        encoded_ciphertext = cipher["ciphertext"]
        if (
            not isinstance(encoded_salt, str)
            or len(encoded_salt) != 24
            or not isinstance(encoded_nonce, str)
            or len(encoded_nonce) != 16
            or not isinstance(encoded_ciphertext, str)
            or len(encoded_ciphertext) > 8192
        ):
            raise ValueError("invalid recovery envelope encoding")
        salt = b64decode(encoded_salt, validate=True)
        nonce = b64decode(encoded_nonce, validate=True)
        ciphertext = b64decode(encoded_ciphertext, validate=True)
        if len(salt) != 16 or len(nonce) != 12:
            raise ValueError("invalid recovery envelope lengths")
        plaintext = AESGCM(derive_key(passphrase, salt=salt)).decrypt(
            nonce,
            ciphertext,
            ASSOCIATED_DATA,
        )
        material = json.loads(plaintext)
    except (
        InvalidTag,
        KeyError,
        TypeError,
        UnicodeDecodeError,
        ValueError,
        json.JSONDecodeError,
    ) as error:
        raise RecoveryMaterialError("recovery material could not be decrypted") from error
    if (
        not isinstance(material, dict)
        or set(material) != {"credential", "credential_id", "expires_at", "label"}
        or not all(isinstance(value, str) and value for value in material.values())
    ):
        raise RecoveryMaterialError("recovery material could not be decrypted")
    return material


def derive_key(passphrase: str, *, salt: bytes) -> bytes:
    return Scrypt(
        salt=salt,
        length=SCRYPT_LENGTH,
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
    ).derive(passphrase.encode())


def require_passphrase(passphrase: str) -> None:
    if len(passphrase) < 16:
        raise RecoveryMaterialError("recovery passphrase must contain at least 16 characters")
