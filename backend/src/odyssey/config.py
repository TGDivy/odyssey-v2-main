"""Typed runtime configuration with payload-safe diagnostics."""

from enum import StrEnum
from functools import lru_cache

from pydantic import Field
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

    def safe_diagnostics(self) -> dict[str, str | bool | int]:
        return {
            "environment": self.env.value,
            "auth_mode": self.auth_mode.value,
            "model_provider": self.model_provider,
            "proactive_enabled": self.proactive_enabled,
            "telemetry_exporter": self.telemetry_exporter,
            "commit_sha": self.commit_sha,
            "minimum_client_schema_version": self.minimum_client_schema_version,
            "storage_configured": bool(self.storage_endpoint and self.storage_bucket),
        }


@lru_cache
def get_settings() -> Settings:
    return Settings()
