"""Typed runtime configuration with payload-safe diagnostics."""

from enum import StrEnum
from functools import lru_cache
from pathlib import Path

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Environment(StrEnum):
    LOCAL = "local"
    DEVELOPMENT = "development"
    STAGING = "staging"
    PRODUCTION = "production"
    TEST = "test"


class AuthMode(StrEnum):
    DEVELOPMENT = "development"
    SIGN_IN_WITH_APPLE = "sign_in_with_apple"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="ODYSSEY_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    env: Environment = Environment.LOCAL
    log_level: str = "INFO"
    database_url: str = "postgresql+asyncpg://odyssey:odyssey@localhost:5432/odyssey"
    storage_endpoint: str = "http://localhost:9000"
    storage_bucket: str = "odyssey-local"
    storage_access_key: str = "odyssey"
    storage_secret_key: str = ""
    model_provider: str = "deterministic"
    auth_mode: AuthMode = AuthMode.DEVELOPMENT
    proactive_enabled: bool = False
    telemetry_exporter: str = "console"
    commit_sha: str = "development"
    api_docs_enabled: bool = True
    minimum_client_schema_version: int = Field(default=1, ge=1)
    current_sync_schema_version: int = Field(default=1, ge=1)
    worker_poll_seconds: float = Field(default=1.0, gt=0)
    worker_batch_size: int = Field(default=50, ge=1, le=500)
    worker_lease_seconds: int = Field(default=60, ge=1, le=3600)
    worker_max_attempts: int = Field(default=8, ge=1, le=100)
    attachment_storage_path: Path = Path("./local-data/attachments")
    attachment_upload_signing_key: SecretStr = SecretStr("")
    attachment_chunk_bytes: int = Field(default=4 * 1024 * 1024, ge=1)
    maximum_attachment_bytes: int = Field(default=1024 * 1024 * 1024, ge=1)
    attachment_upload_ttl_seconds: int = Field(default=3600, ge=60, le=86400)

    @model_validator(mode="after")
    def validate_schema_window(self) -> "Settings":
        if self.current_sync_schema_version < self.minimum_client_schema_version:
            raise ValueError("current sync schema cannot be below the supported minimum")
        if self.maximum_attachment_bytes < self.attachment_chunk_bytes:
            raise ValueError("maximum attachment size cannot be below the upload chunk size")
        if self.env in {Environment.STAGING, Environment.PRODUCTION} and not (
            self.attachment_upload_signing_key.get_secret_value()
        ):
            raise ValueError("staging and production require an attachment upload signing key")
        return self

    def safe_diagnostics(self) -> dict[str, str | bool | int]:
        return {
            "environment": self.env.value,
            "auth_mode": self.auth_mode.value,
            "model_provider": self.model_provider,
            "proactive_enabled": self.proactive_enabled,
            "telemetry_exporter": self.telemetry_exporter,
            "commit_sha": self.commit_sha,
            "minimum_client_schema_version": self.minimum_client_schema_version,
            "current_sync_schema_version": self.current_sync_schema_version,
            "worker_batch_size": self.worker_batch_size,
            "attachment_chunk_bytes": self.attachment_chunk_bytes,
            "maximum_attachment_bytes": self.maximum_attachment_bytes,
            "storage_configured": bool(self.storage_endpoint and self.storage_bucket),
        }


@lru_cache
def get_settings() -> Settings:
    return Settings()
