"""Audio upload streaming, ffprobe validation, downsampling, and overlapping chunking."""

from __future__ import annotations

import asyncio
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

from fastapi import UploadFile

MAX_PROVIDER_CHUNK_BYTES = 20 * 1024 * 1024


class AudioValidationError(Exception):
    """Raised when an uploaded file is not valid audio or violates constraints."""


class UploadTooLargeError(Exception):
    """Raised when a streamed upload exceeds the configured byte limit."""


@dataclass(frozen=True)
class AudioProbeResult:
    duration_seconds: float
    codec_name: str | None


@dataclass(frozen=True)
class AudioChunk:
    path: Path
    offset_sec: float
    duration_sec: float


@dataclass(frozen=True)
class TranscriptSegment:
    start_sec: float
    end_sec: float
    text: str


async def save_upload_stream(
    upload_file: UploadFile, dest_path: Path, max_bytes: int
) -> int:
    """Stream an uploaded file to disk in 1 MB chunks, enforcing `max_bytes`."""
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    chunk_size = 1024 * 1024
    try:
        with dest_path.open("wb") as handle:
            while True:
                data = await upload_file.read(chunk_size)
                if not data:
                    break
                total += len(data)
                if total > max_bytes:
                    raise UploadTooLargeError(
                        f"Upload exceeds maximum allowed size of {max_bytes // (1024 * 1024)} MB"
                    )
                handle.write(data)
    except Exception:
        dest_path.unlink(missing_ok=True)
        raise
    if total == 0:
        dest_path.unlink(missing_ok=True)
        raise AudioValidationError("Uploaded audio file is empty")
    return total


def _run_subprocess(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=False,
    )


def _probe_audio_sync(path: Path, max_audio_seconds: int) -> AudioProbeResult:
    if not path.exists():
        raise AudioValidationError("Audio file does not exist")

    proc = _run_subprocess(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=codec_type,codec_name",
            "-of",
            "json",
            str(path),
        ]
    )
    if proc.returncode != 0:
        raise AudioValidationError("Uploaded file is not a recognized audio format")

    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise AudioValidationError("Failed to inspect audio metadata") from exc

    streams = payload.get("streams") or []
    audio_streams = [s for s in streams if s.get("codec_type") == "audio"]
    if not audio_streams:
        raise AudioValidationError("Uploaded file does not contain an audio stream")

    duration_raw = (payload.get("format") or {}).get("duration")
    try:
        duration = float(duration_raw)
    except (TypeError, ValueError) as exc:
        raise AudioValidationError("Could not determine audio duration") from exc

    if duration <= 0:
        raise AudioValidationError("Audio duration must be positive")
    if duration > max_audio_seconds:
        raise AudioValidationError(
            f"Audio duration ({int(duration)}s) exceeds limit ({max_audio_seconds}s)"
        )

    return AudioProbeResult(
        duration_seconds=duration,
        codec_name=audio_streams[0].get("codec_name"),
    )


async def probe_audio(path: Path, max_audio_seconds: int) -> AudioProbeResult:
    """Validate audio stream and duration using ffprobe."""
    return await asyncio.to_thread(_probe_audio_sync, path, max_audio_seconds)


def _prepare_audio_chunks_sync(
    input_path: Path,
    work_dir: Path,
    chunk_duration_sec: int,
    overlap_sec: int,
    max_audio_seconds: int,
) -> list[AudioChunk]:
    work_dir.mkdir(parents=True, exist_ok=True)
    normalized_path = work_dir / "normalized.mp3"

    # Downsample to 16kHz mono speech-optimized MP3 (~14MB/hr) before chunking.
    norm_proc = _run_subprocess(
        [
            "ffmpeg",
            "-y",
            "-i",
            str(input_path),
            "-vn",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-b:a",
            "32k",
            str(normalized_path),
        ]
    )
    if norm_proc.returncode != 0 or not normalized_path.exists():
        raise AudioValidationError(
            f"ffmpeg normalization failed: {norm_proc.stderr.strip()[:300]}"
        )

    probe = _probe_audio_sync(normalized_path, max_audio_seconds)
    norm_size = normalized_path.stat().st_size

    if probe.duration_seconds <= chunk_duration_sec and norm_size <= MAX_PROVIDER_CHUNK_BYTES:
        return [
            AudioChunk(
                path=normalized_path,
                offset_sec=0.0,
                duration_sec=probe.duration_seconds,
            )
        ]

    # Cap each chunk length so even unusual encoders stay well below 20 MB.
    effective_chunk_sec = chunk_duration_sec
    if norm_size > MAX_PROVIDER_CHUNK_BYTES and probe.duration_seconds > 0:
        bytes_per_sec = norm_size / probe.duration_seconds
        safe_sec = max(60, int((MAX_PROVIDER_CHUNK_BYTES * 0.85) / bytes_per_sec))
        effective_chunk_sec = min(effective_chunk_sec, safe_sec)

    step_sec = max(1, effective_chunk_sec - overlap_sec)
    chunks: list[AudioChunk] = []
    start = 0.0
    idx = 0

    while start < probe.duration_seconds:
        remaining = probe.duration_seconds - start
        if remaining <= 0.05 and idx > 0:
            break
        chunk_len = min(float(effective_chunk_sec), remaining)
        chunk_path = work_dir / f"chunk_{idx:03d}.mp3"
        slice_proc = _run_subprocess(
            [
                "ffmpeg",
                "-y",
                "-ss",
                f"{start:.3f}",
                "-t",
                f"{chunk_len:.3f}",
                "-i",
                str(normalized_path),
                "-vn",
                "-ac",
                "1",
                "-ar",
                "16000",
                "-b:a",
                "32k",
                str(chunk_path),
            ]
        )
        if slice_proc.returncode != 0 or not chunk_path.exists():
            raise AudioValidationError(
                f"ffmpeg chunking failed at {start:.1f}s: {slice_proc.stderr.strip()[:300]}"
            )
        chunks.append(
            AudioChunk(
                path=chunk_path,
                offset_sec=start,
                duration_sec=chunk_len,
            )
        )
        if start + chunk_len >= probe.duration_seconds - 0.05:
            break
        start += step_sec
        idx += 1

    return chunks


async def prepare_audio_chunks(
    input_path: Path,
    work_dir: Path,
    chunk_duration_sec: int,
    overlap_sec: int,
    max_audio_seconds: int,
) -> list[AudioChunk]:
    """Normalize audio to 16kHz mono MP3 and slice into overlapping <20MB chunks."""
    return await asyncio.to_thread(
        _prepare_audio_chunks_sync,
        input_path,
        work_dir,
        chunk_duration_sec,
        overlap_sec,
        max_audio_seconds,
    )


def stitch_chunk_segments(
    chunk_outputs: list[tuple[AudioChunk, list[TranscriptSegment], str]],
    overlap_sec: int,
) -> tuple[str, list[TranscriptSegment]]:
    """Merge per-chunk segments with offset correction and overlap deduplication."""
    if not chunk_outputs:
        return "", []

    merged: list[TranscriptSegment] = []
    fallback_texts: list[str] = []
    prev_end_sec = 0.0

    for chunk_idx, (chunk, segs, raw_text) in enumerate(chunk_outputs):
        cutoff = max(0.0, prev_end_sec - (overlap_sec / 2.0)) if chunk_idx > 0 else -1.0

        if not segs and raw_text.strip():
            fallback_texts.append(raw_text.strip())
            prev_end_sec = max(prev_end_sec, chunk.offset_sec + chunk.duration_sec)
            continue

        for seg in segs:
            text = seg.text.strip()
            if not text:
                continue
            abs_start = chunk.offset_sec + max(0.0, seg.start_sec)
            abs_end = chunk.offset_sec + max(seg.start_sec, seg.end_sec)
            midpoint = (abs_start + abs_end) / 2.0
            if chunk_idx > 0 and midpoint < cutoff:
                continue
            merged.append(
                TranscriptSegment(
                    start_sec=round(abs_start, 2),
                    end_sec=round(abs_end, 2),
                    text=text,
                )
            )
        prev_end_sec = max(prev_end_sec, chunk.offset_sec + chunk.duration_sec)

    if merged:
        full_text = " ".join(seg.text for seg in merged).strip()
        return full_text, merged

    return " ".join(fallback_texts).strip(), []
