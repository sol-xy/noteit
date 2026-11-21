"""Pytest fixtures for NoteIt backend tests."""

from __future__ import annotations

import subprocess
from pathlib import Path

import httpx
import pytest

from app.config import Settings
from app.main import create_app


@pytest.fixture
def test_token() -> str:
    return "test-token-with-plenty-of-entropy-1234567890"


@pytest.fixture
def test_settings(tmp_path: Path, test_token: str) -> Settings:
    return Settings(
        auth_token=test_token,
        groq_api_key="test-groq-key",
        gemini_api_key="test-gemini-key",
        cookie_secure=False,
        enable_rate_limit=False,
        data_dir=tmp_path / "data",
        delete_audio_after_transcription=True,
        chunk_duration_seconds=1200,
        chunk_overlap_seconds=5,
    )


@pytest.fixture
async def app_instance(test_settings: Settings):
    app = create_app(test_settings)
    async with app.router.lifespan_context(app):
        yield app


@pytest.fixture
async def client(app_instance):
    transport = httpx.ASGITransport(app=app_instance)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as ac:
        yield ac


@pytest.fixture
def auth_headers(test_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {test_token}"}


def make_sine_m4a(path: Path, duration_sec: float = 2.0) -> Path:
    """Create a real playable M4A audio file via ffmpeg for integration tests."""
    proc = subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency=440:duration={duration_sec}",
            "-c:a",
            "aac",
            "-b:a",
            "32k",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, f"ffmpeg failed: {proc.stderr}"
    return path
