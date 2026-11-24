"""Application configuration loaded from environment variables."""

from __future__ import annotations

import hashlib
import hmac
from functools import lru_cache
from pathlib import Path

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime settings for the NoteIt backend service."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    auth_token: str = Field(..., min_length=1)
    session_secret: str | None = None
    allow_weak_token_for_tests: bool = False

    groq_api_key: str = ""
    gemini_api_key: str = ""

    groq_stt_model: str = "whisper-large-v3-turbo"
    gemini_model: str = "gemini-3.5-flash-lite"
    default_stt_provider: str = "auto"

    delete_audio_after_transcription: bool = True

    max_upload_mb: int = Field(default=200, ge=1, le=2048)
    max_audio_seconds: int = Field(default=14400, ge=10, le=43200)
    chunk_duration_seconds: int = Field(default=1200, ge=10, le=3600)
    chunk_overlap_seconds: int = Field(default=5, ge=0, le=60)

    cookie_secure: bool = True
    enable_rate_limit: bool = True
    data_dir: Path = Path("/data")
    log_level: str = "INFO"

    push_enabled: bool = True
    vapid_subject: str = "mailto:noteit@example.com"
    vapid_private_key: str = ""

    @field_validator("default_stt_provider")
    @classmethod
    def _validate_stt_provider(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"auto", "groq", "gemini"}:
            raise ValueError("DEFAULT_STT_PROVIDER must be one of: auto, groq, gemini")
        return normalized

    @field_validator("vapid_subject")
    @classmethod
    def _validate_vapid_subject(cls, value: str) -> str:
        normalized = value.strip()
        if not (normalized.startswith("mailto:") or normalized.startswith("https://")):
            raise ValueError("VAPID_SUBJECT must start with 'mailto:' or 'https://'")
        return normalized

    @model_validator(mode="after")
    def _validate_security_and_chunks(self) -> Settings:
        token = self.auth_token.strip()
        if not token:
            raise ValueError("AUTH_TOKEN must not be empty")
        if not self.allow_weak_token_for_tests and len(token) < 24:
            raise ValueError(
                "AUTH_TOKEN must be at least 24 characters (generate with `openssl rand -hex 32`)"
            )
        self.auth_token = token

        if self.chunk_overlap_seconds >= self.chunk_duration_seconds:
            raise ValueError("CHUNK_OVERLAP_SECONDS must be smaller than CHUNK_DURATION_SECONDS")
        return self

    @property
    def max_upload_bytes(self) -> int:
        return self.max_upload_mb * 1024 * 1024

    @property
    def db_path(self) -> Path:
        return self.data_dir / "noteit.db"

    @property
    def audio_dir(self) -> Path:
        return self.data_dir / "audio"

    @property
    def tmp_dir(self) -> Path:
        return self.data_dir / "tmp"

    @property
    def vapid_key_path(self) -> Path:
        return self.data_dir / "vapid_private.pem"

    @property
    def derived_session_secret(self) -> bytes:
        """Return explicit SESSION_SECRET or an HMAC-derived signing key."""
        if self.session_secret and self.session_secret.strip():
            return self.session_secret.strip().encode("utf-8")
        return hmac.new(
            self.auth_token.encode("utf-8"),
            b"noteit-web-session-v1",
            hashlib.sha256,
        ).digest()


@lru_cache
def get_settings() -> Settings:
    """Return cached settings instance."""
    return Settings()
