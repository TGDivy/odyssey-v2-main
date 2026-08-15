"""Typed runtime configuration with payload-safe diagnostics."""

import re
from enum import StrEnum
from functools import lru_cache
from pathlib import Path
from urllib.parse import unquote, urlsplit

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

HTTP_HEADER_NAME = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")


class Environment(StrEnum):
    LOCAL = "local"
    DEVELOPMENT = "development"
    STAGING = "staging"
    PRODUCTION = "production"
    TEST = "test"


class AuthMode(StrEnum):
    DEVELOPMENT = "development"
    SIGN_IN_WITH_APPLE = "sign_in_with_apple"


class TelemetryExporter(StrEnum):
    NONE = "none"
    CONSOLE = "console"
    OTLP_HTTP = "otlp_http"


class AttachmentStoreBackend(StrEnum):
    LOCAL = "local"
    S3 = "s3"
    GCS = "gcs"


class ProcessRole(StrEnum):
    API = "api"
    WORKER = "worker"
    MIGRATION = "migration"
    BACKUP = "backup"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="ODYSSEY_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    env: Environment = Environment.LOCAL
    process_role: ProcessRole = ProcessRole.API
    log_level: str = "INFO"
    database_url: str = "postgresql+asyncpg://odyssey:odyssey@localhost:5432/odyssey"
    attachment_store_backend: AttachmentStoreBackend = AttachmentStoreBackend.LOCAL
    storage_endpoint: str = ""
    storage_bucket: str = "odyssey-local"
    storage_region: str = "us-east-1"
    storage_access_key: SecretStr = SecretStr("")
    storage_secret_key: SecretStr = SecretStr("")
    storage_force_path_style: bool = False
    storage_require_versioning: bool = True
    storage_require_public_access_block: bool = True
    storage_server_side_encryption: str = ""
    storage_kms_key_id: str = ""
    gcp_project_id: str = ""
    model_provider: str = "deterministic"
    auth_mode: AuthMode = AuthMode.DEVELOPMENT
    apple_client_id: str = ""
    apple_issuer: str = "https://appleid.apple.com"
    apple_jwks_url: str = "https://appleid.apple.com/auth/keys"
    apple_jwks_cache_seconds: int = Field(default=3600, ge=60, le=86400)
    apple_http_timeout_seconds: int = Field(default=5, ge=1, le=30)
    apple_identity_token_max_age_seconds: int = Field(default=600, ge=60, le=3600)
    apple_bootstrap_subject: SecretStr = SecretStr("")
    auth_access_token_signing_key: SecretStr = SecretStr("")
    auth_access_token_ttl_seconds: int = Field(default=900, ge=60, le=3600)
    auth_clock_skew_seconds: int = Field(default=30, ge=0, le=300)
    auth_refresh_credential_ttl_days: int = Field(default=90, ge=1, le=365)
    auth_challenge_ttl_seconds: int = Field(default=300, ge=60, le=900)
    auth_max_pending_challenges: int = Field(default=1000, ge=1, le=100_000)
    auth_max_pending_challenges_per_device: int = Field(default=5, ge=1, le=100)
    proactive_enabled: bool = False
    telemetry_exporter: TelemetryExporter = TelemetryExporter.NONE
    telemetry_otlp_endpoint: str = ""
    telemetry_otlp_headers: SecretStr = SecretStr("")
    telemetry_sample_ratio: float = Field(default=1.0, ge=0.0, le=1.0)
    telemetry_export_interval_seconds: int = Field(default=60, ge=1, le=3600)
    telemetry_export_timeout_seconds: int = Field(default=10, ge=1, le=300)
    commit_sha: str = "development"
    api_docs_enabled: bool = True
    minimum_client_schema_version: int = Field(default=1, ge=1)
    current_sync_schema_version: int = Field(default=1, ge=1)
    worker_poll_seconds: float = Field(default=1.0, gt=0)
    worker_batch_size: int = Field(default=50, ge=1, le=500)
    worker_lease_seconds: int = Field(default=60, ge=1, le=3600)
    worker_max_attempts: int = Field(default=8, ge=1, le=100)
    worker_backlog_alert_seconds: int = Field(default=3 * 60 * 60, ge=60)
    attachment_storage_path: Path = Path("./local-data/attachments")
    attachment_upload_signing_key: SecretStr = SecretStr("")
    attachment_chunk_bytes: int = Field(default=4 * 1024 * 1024, ge=1)
    maximum_attachment_bytes: int = Field(default=1024 * 1024 * 1024, ge=1)
    attachment_upload_ttl_seconds: int = Field(default=3600, ge=60, le=86400)
    owner_export_enabled: bool = False
    export_wrapping_key: SecretStr = SecretStr("")
    maximum_export_bytes: int = Field(default=512 * 1024 * 1024, ge=1024)

    @model_validator(mode="after")
    def validate_schema_window(self) -> "Settings":
        if self.current_sync_schema_version < self.minimum_client_schema_version:
            raise ValueError("current sync schema cannot be below the supported minimum")
        if self.maximum_attachment_bytes < self.attachment_chunk_bytes:
            raise ValueError("maximum attachment size cannot be below the upload chunk size")
        if self.auth_max_pending_challenges_per_device > self.auth_max_pending_challenges:
            raise ValueError("per-device auth challenge capacity cannot exceed global capacity")
        if (
            self.owner_export_enabled
            and len(self.export_wrapping_key.get_secret_value().encode()) < 32
        ):
            raise ValueError("owner export requires a wrapping key of at least 32 bytes")
        static_access_key = self.storage_access_key.get_secret_value()
        static_secret_key = self.storage_secret_key.get_secret_value()
        if bool(static_access_key) != bool(static_secret_key):
            raise ValueError("object storage access key and secret must be configured together")
        if self.storage_server_side_encryption not in {"", "AES256", "aws:kms"}:
            raise ValueError("unsupported object storage server-side encryption mode")
        if (
            self.attachment_store_backend is AttachmentStoreBackend.S3
            and self.storage_kms_key_id
            and self.storage_server_side_encryption != "aws:kms"
        ):
            raise ValueError("an object storage KMS key requires aws:kms encryption mode")
        if self.attachment_store_backend is AttachmentStoreBackend.S3 and self.storage_endpoint:
            storage_endpoint = urlsplit(self.storage_endpoint)
            if storage_endpoint.scheme not in {"http", "https"} or not storage_endpoint.netloc:
                raise ValueError("S3-compatible storage endpoint must use HTTP(S)")
        protected_environment = self.env in {Environment.STAGING, Environment.PRODUCTION}
        if (
            protected_environment
            and self.process_role is ProcessRole.API
            and not (self.attachment_upload_signing_key.get_secret_value())
        ):
            raise ValueError("staging and production require an attachment upload signing key")
        if protected_environment and self.process_role in {ProcessRole.API, ProcessRole.BACKUP}:
            if self.attachment_store_backend is AttachmentStoreBackend.LOCAL:
                raise ValueError("staging and production require durable cloud attachment storage")
            if not self.storage_bucket:
                raise ValueError("cloud attachment storage requires a bucket")
            if not self.storage_require_versioning:
                raise ValueError("cloud attachment storage requires object versioning")
            if (
                self.attachment_store_backend is AttachmentStoreBackend.S3
                and not self.storage_server_side_encryption
            ):
                raise ValueError("production S3 attachment storage requires server-side encryption")
        if (
            protected_environment
            and self.process_role is ProcessRole.API
            and self.auth_mode is AuthMode.SIGN_IN_WITH_APPLE
        ):
            if not self.apple_client_id:
                raise ValueError("Sign in with Apple requires an Apple client ID")
            if len(self.auth_access_token_signing_key.get_secret_value().encode()) < 32:
                raise ValueError("Sign in with Apple requires a strong access-token signing key")
            for endpoint in (self.apple_issuer, self.apple_jwks_url):
                parsed_endpoint = urlsplit(endpoint)
                if parsed_endpoint.scheme != "https" or not parsed_endpoint.netloc:
                    raise ValueError("production Apple identity endpoints must use HTTPS")
        if self.telemetry_exporter is TelemetryExporter.OTLP_HTTP:
            telemetry_endpoint = urlsplit(self.telemetry_otlp_endpoint)
            if telemetry_endpoint.scheme not in {"http", "https"} or not telemetry_endpoint.netloc:
                raise ValueError("OTLP HTTP telemetry requires an HTTP(S) endpoint")
            self.telemetry_headers()
        return self

    def telemetry_headers(self) -> dict[str, str]:
        encoded_headers = self.telemetry_otlp_headers.get_secret_value().strip()
        if not encoded_headers:
            return {}
        headers: dict[str, str] = {}
        for encoded_header in encoded_headers.split(","):
            encoded_name, separator, encoded_value = encoded_header.partition("=")
            name = unquote(encoded_name).strip()
            value = unquote(encoded_value).strip()
            if (
                not separator
                or not HTTP_HEADER_NAME.fullmatch(name)
                or "\r" in value
                or "\n" in value
            ):
                raise ValueError("OTLP headers must be comma-separated name=value pairs")
            headers[name] = value
        return headers

    def safe_diagnostics(self) -> dict[str, str | bool | int | float]:
        static_access_key = self.storage_access_key.get_secret_value()
        return {
            "environment": self.env.value,
            "process_role": self.process_role.value,
            "auth_mode": self.auth_mode.value,
            "apple_client_configured": bool(self.apple_client_id),
            "apple_bootstrap_subject_configured": bool(
                self.apple_bootstrap_subject.get_secret_value()
            ),
            "auth_access_token_signing_key_configured": bool(
                self.auth_access_token_signing_key.get_secret_value()
            ),
            "auth_access_token_ttl_seconds": self.auth_access_token_ttl_seconds,
            "model_provider": self.model_provider,
            "proactive_enabled": self.proactive_enabled,
            "telemetry_exporter": self.telemetry_exporter.value,
            "telemetry_enabled": self.telemetry_exporter is not TelemetryExporter.NONE,
            "telemetry_otlp_endpoint_configured": bool(self.telemetry_otlp_endpoint),
            "telemetry_sample_ratio": self.telemetry_sample_ratio,
            "commit_sha": self.commit_sha,
            "minimum_client_schema_version": self.minimum_client_schema_version,
            "current_sync_schema_version": self.current_sync_schema_version,
            "worker_batch_size": self.worker_batch_size,
            "worker_backlog_alert_seconds": self.worker_backlog_alert_seconds,
            "attachment_chunk_bytes": self.attachment_chunk_bytes,
            "maximum_attachment_bytes": self.maximum_attachment_bytes,
            "attachment_store_backend": self.attachment_store_backend.value,
            "storage_configured": (
                self.attachment_store_backend is AttachmentStoreBackend.LOCAL
                or bool(self.storage_bucket)
            ),
            "storage_static_credentials_configured": bool(static_access_key),
            "storage_versioning_required": self.storage_require_versioning,
            "owner_export_enabled": self.owner_export_enabled,
            "export_wrapping_key_configured": bool(self.export_wrapping_key.get_secret_value()),
            "maximum_export_bytes": self.maximum_export_bytes,
        }


@lru_cache
def get_settings() -> Settings:
    return Settings()
