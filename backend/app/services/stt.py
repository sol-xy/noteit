"""Speech-to-text pipeline: Groq Whisper primary with automatic Gemini Flash fallback."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from google import genai
from google.genai import types
from groq import Groq
from pydantic import BaseModel

from app.config import Settings
from app.services.audio import (
    AudioChunk,
    TranscriptSegment,
    prepare_audio_chunks,
    stitch_chunk_segments,
)

logger = logging.getLogger(__name__)


class SttError(Exception):
    """Raised when transcription fails across all configured providers."""


@dataclass(frozen=True)
class TranscriptionResult:
    text: str
    segments: list[TranscriptSegment]
    language: str | None
    provider_used: str


class _GeminiSegmentSchema(BaseModel):
    start_sec: float
    end_sec: float
    text: str


class _GeminiTranscriptSchema(BaseModel):
    language: str | None = None
    text: str
    segments: list[_GeminiSegmentSchema] = []


def _strip_json_fences(raw: str) -> str:
    stripped = raw.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if len(lines) >= 2 and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        return "\n".join(lines).strip()
    return stripped


def _extract_groq_segments(raw_segments: Any) -> list[TranscriptSegment]:
    segments: list[TranscriptSegment] = []
    if not raw_segments:
        return segments
    for item in raw_segments:
        if isinstance(item, dict):
            start = float(item.get("start", 0.0))
            end = float(item.get("end", start))
            text = str(item.get("text", "")).strip()
        else:
            start = float(getattr(item, "start", 0.0))
            end = float(getattr(item, "end", start))
            text = str(getattr(item, "text", "")).strip()
        if text:
            segments.append(TranscriptSegment(start_sec=start, end_sec=end, text=text))
    return segments


def _transcribe_chunk_groq_sync(
    chunk_path: Path, settings: Settings
) -> tuple[list[TranscriptSegment], str, str | None]:
    if not settings.groq_api_key.strip():
        raise SttError("GROQ_API_KEY is not configured")

    client = Groq(api_key=settings.groq_api_key)
    with chunk_path.open("rb") as audio_file:
        resp = client.audio.transcriptions.create(
            file=(chunk_path.name, audio_file.read()),
            model=settings.groq_stt_model,
            response_format="verbose_json",
            timestamp_granularities=["segment"],
            temperature=0.0,
        )

    text = str(getattr(resp, "text", "") or "").strip()
    language = getattr(resp, "language", None)
    segments = _extract_groq_segments(getattr(resp, "segments", None))
    return segments, text, language


def _transcribe_chunk_gemini_sync(
    chunk_path: Path, settings: Settings
) -> tuple[list[TranscriptSegment], str, str | None]:
    if not settings.gemini_api_key.strip():
        raise SttError("GEMINI_API_KEY is not configured")

    client = genai.Client(api_key=settings.gemini_api_key)
    uploaded: Any = None
    try:
        uploaded = client.files.upload(file=str(chunk_path))
        state_name = getattr(getattr(uploaded, "state", None), "name", None)
        attempts = 0
        while state_name == "PROCESSING" and attempts < 30:
            time.sleep(1.0)
            uploaded = client.files.get(name=uploaded.name)
            state_name = getattr(getattr(uploaded, "state", None), "name", None)
            attempts += 1

        prompt = (
            "Transcribe this meeting audio verbatim in its original language(s). "
            "Preserve technical terms accurately and do not summarize or omit spoken words. "
            "Return JSON with: language (BCP-47 or language name), "
            "text (full verbatim transcript), "
            "and segments (list of {start_sec, end_sec, text} chronological utterance segments)."
        )
        response = client.models.generate_content(
            model=settings.gemini_model,
            contents=[prompt, uploaded],
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                response_schema=_GeminiTranscriptSchema,
                temperature=0.0,
            ),
        )
        raw_text = (response.text or "").strip()
        if not raw_text:
            raise SttError("Gemini returned an empty transcription response")

        data = json.loads(_strip_json_fences(raw_text))
        parsed = _GeminiTranscriptSchema.model_validate(data)
        segments = [
            TranscriptSegment(
                start_sec=float(seg.start_sec),
                end_sec=float(seg.end_sec),
                text=seg.text.strip(),
            )
            for seg in parsed.segments
            if seg.text.strip()
        ]
        full_text = parsed.text.strip() or " ".join(s.text for s in segments).strip()
        return segments, full_text, parsed.language
    finally:
        if uploaded is not None and getattr(uploaded, "name", None):
            try:
                client.files.delete(name=uploaded.name)
            except Exception as exc:  # pragma: no cover - best effort remote cleanup
                logger.warning("Failed to delete temporary Gemini file %s: %s", uploaded.name, exc)


async def _run_provider_on_chunks(
    chunks: list[AudioChunk],
    provider: str,
    settings: Settings,
) -> TranscriptionResult:
    chunk_outputs: list[tuple[AudioChunk, list[TranscriptSegment], str]] = []
    detected_language: str | None = None

    fn = _transcribe_chunk_groq_sync if provider == "groq" else _transcribe_chunk_gemini_sync
    for chunk in chunks:
        segs, raw_text, lang = await asyncio.to_thread(fn, chunk.path, settings)
        if lang and not detected_language:
            detected_language = lang
        chunk_outputs.append((chunk, segs, raw_text))

    full_text, merged_segments = stitch_chunk_segments(
        chunk_outputs, overlap_sec=settings.chunk_overlap_seconds
    )
    return TranscriptionResult(
        text=full_text,
        segments=merged_segments,
        language=detected_language,
        provider_used=provider,
    )


async def transcribe_audio(
    audio_path: Path,
    provider: str,
    work_dir: Path,
    settings: Settings,
) -> TranscriptionResult:
    """Normalize/chunk audio and transcribe via Groq with optional Gemini fallback."""
    chunks = await prepare_audio_chunks(
        input_path=audio_path,
        work_dir=work_dir,
        chunk_duration_sec=settings.chunk_duration_seconds,
        overlap_sec=settings.chunk_overlap_seconds,
        max_audio_seconds=settings.max_audio_seconds,
    )

    choice = (provider or settings.default_stt_provider).strip().lower()
    if choice not in {"auto", "groq", "gemini"}:
        choice = settings.default_stt_provider

    if choice == "gemini":
        return await _run_provider_on_chunks(chunks, "gemini", settings)

    if choice == "groq":
        return await _run_provider_on_chunks(chunks, "groq", settings)

    # choice == "auto": prefer Groq Whisper, automatically falling back to Gemini Flash.
    if settings.groq_api_key.strip():
        try:
            return await _run_provider_on_chunks(chunks, "groq", settings)
        except Exception as exc:
            logger.warning("Groq STT failed; falling back to Gemini: %s", exc)
            if not settings.gemini_api_key.strip():
                raise SttError(
                    f"Groq transcription failed and Gemini key is not set: {exc}"
                ) from exc

    if settings.gemini_api_key.strip():
        return await _run_provider_on_chunks(chunks, "gemini", settings)

    raise SttError("Neither GROQ_API_KEY nor GEMINI_API_KEY is configured on the server")
