"""Real ffmpeg audio probing, chunking, overlap stitching, and upload validation tests."""

from __future__ import annotations

from pathlib import Path

from app.services.audio import (
    AudioChunk,
    TranscriptSegment,
    prepare_audio_chunks,
    probe_audio,
    stitch_chunk_segments,
)
from tests.conftest import make_sine_m4a


async def test_ffmpeg_probe_and_overlapping_chunking(tmp_path: Path):
    src = make_sine_m4a(tmp_path / "sample12s.m4a", duration_sec=12.0)
    probe = await probe_audio(src, max_audio_seconds=60)
    assert 11.5 <= probe.duration_seconds <= 12.5

    chunks = await prepare_audio_chunks(
        input_path=src,
        work_dir=tmp_path / "chunks",
        chunk_duration_sec=5,
        overlap_sec=1,
        max_audio_seconds=60,
    )
    assert len(chunks) >= 3
    assert chunks[0].offset_sec == 0.0
    assert chunks[1].offset_sec == 4.0
    for chunk in chunks:
        assert chunk.path.exists()
        assert chunk.path.stat().st_size > 0


def test_stitch_chunk_segments_deduplicates_overlap(tmp_path: Path):
    c0 = AudioChunk(path=tmp_path / "c0.mp3", offset_sec=0.0, duration_sec=10.0)
    c1 = AudioChunk(path=tmp_path / "c1.mp3", offset_sec=8.0, duration_sec=10.0)

    chunk_outputs = [
        (
            c0,
            [
                TranscriptSegment(0.0, 4.0, "Hello everyone."),
                TranscriptSegment(5.0, 9.5, "Let us review the budget."),
            ],
            "",
        ),
        (
            c1,
            [
                # Relative 0..1.5s -> absolute 8.0..9.5s (midpoint 8.75s < cutoff 9.0s -> skipped)
                TranscriptSegment(0.0, 1.5, "review the budget."),
                TranscriptSegment(2.0, 6.0, "Marketing needs ten percent more."),
            ],
            "",
        ),
    ]
    text, segs = stitch_chunk_segments(chunk_outputs, overlap_sec=2)
    assert len(segs) == 3
    assert text == "Hello everyone. Let us review the budget. Marketing needs ten percent more."
    assert segs[2].start_sec == 10.0
    assert segs[2].end_sec == 14.0


async def test_rejects_non_audio_upload(client, auth_headers):
    create_resp = await client.post(
        "/api/meetings",
        headers=auth_headers,
        json={"title": "Bad Upload"},
    )
    meeting_id = create_resp.json()["id"]

    upload_resp = await client.post(
        f"/api/meetings/{meeting_id}/audio",
        headers=auth_headers,
        files={"file": ("not_audio.m4a", b"plain text not audio at all", "audio/m4a")},
    )
    assert upload_resp.status_code == 400


async def test_rejects_oversized_upload(tmp_path: Path, test_token: str):
    import httpx

    from app.config import Settings
    from app.main import create_app

    small_cfg = Settings(
        auth_token=test_token,
        cookie_secure=False,
        enable_rate_limit=False,
        data_dir=tmp_path / "small_data",
        max_upload_mb=1,
    )
    app = create_app(small_cfg)
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as ac:
            headers = {"Authorization": f"Bearer {test_token}"}
            created = await ac.post("/api/meetings", headers=headers, json={"title": "Too Big"})
            mid = created.json()["id"]
            oversized = b"0" * (1024 * 1024 + 512)
            resp = await ac.post(
                f"/api/meetings/{mid}/audio",
                headers=headers,
                files={"file": ("big.m4a", oversized, "audio/m4a")},
            )
            assert resp.status_code == 413
            assert list(small_cfg.audio_dir.glob("*")) == []

