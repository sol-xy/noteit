"""End-to-end tests for meetings CRUD, worker AI pipeline, fallback, cleanup, and chat."""

from __future__ import annotations

from pathlib import Path

from app.services.audio import TranscriptSegment
from app.services.summarizer import SummaryResult
from tests.conftest import make_sine_m4a


async def test_meeting_crud_and_idempotent_client_id(client, auth_headers):
    payload = {
        "client_id": "ios-uuid-1",
        "title": "Weekly Sync",
        "manual_notes": "- Ship beta\n- Fix login bug",
        "stt_provider": "auto",
    }
    r1 = await client.post("/api/meetings", headers=auth_headers, json=payload)
    assert r1.status_code == 201
    m1 = r1.json()

    r2 = await client.post("/api/meetings", headers=auth_headers, json=payload)
    assert r2.status_code == 200
    assert r2.json()["id"] == m1["id"]

    listing = await client.get("/api/meetings?q=login", headers=auth_headers)
    assert listing.status_code == 200
    assert listing.json()["total"] == 1

    patch_resp = await client.patch(
        f"/api/meetings/{m1['id']}",
        headers=auth_headers,
        json={"title": "Updated Sync"},
    )
    assert patch_resp.status_code == 200
    assert patch_resp.json()["title"] == "Updated Sync"

    del_resp = await client.delete(f"/api/meetings/{m1['id']}", headers=auth_headers)
    assert del_resp.status_code == 200
    assert (await client.get(f"/api/meetings/{m1['id']}", headers=auth_headers)).status_code == 404


async def test_full_pipeline_groq_primary_and_audio_cleanup(
    app_instance, client, auth_headers, tmp_path: Path, monkeypatch
):
    def fake_groq(chunk_path, settings):
        return (
            [
                TranscriptSegment(0.0, 1.2, "We agreed to launch on Friday."),
                TranscriptSegment(1.2, 2.0, "Alex will prepare release notes."),
            ],
            "We agreed to launch on Friday. Alex will prepare release notes.",
            "en",
        )

    def fake_summary(transcript, manual_notes, custom_instructions, settings):
        assert "Friday" in transcript
        assert "check deploy" in manual_notes
        return SummaryResult(
            title="Friday Launch Planning",
            summary_markdown=(
                "## Overview\n\nTeam aligned on launching Friday.\n\n"
                "## Action Items\n\n- [ ] Alex: Prepare release notes\n"
            ),
        )

    monkeypatch.setattr("app.services.stt._transcribe_chunk_groq_sync", fake_groq)
    monkeypatch.setattr("app.services.summarizer._generate_summary_sync", fake_summary)

    created = await client.post(
        "/api/meetings",
        headers=auth_headers,
        json={
            "title": "Untitled Meeting",
            "manual_notes": "- check deploy",
            "stt_provider": "auto",
        },
    )
    assert created.status_code == 201
    meeting_id = created.json()["id"]

    audio_file = make_sine_m4a(tmp_path / "meeting.m4a", duration_sec=2.0)
    with audio_file.open("rb") as f:
        up = await client.post(
            f"/api/meetings/{meeting_id}/audio",
            headers=auth_headers,
            files={"file": ("meeting.m4a", f, "audio/m4a")},
        )
    assert up.status_code == 202
    assert up.json()["status"] == "queued"

    await app_instance.state.worker.drain_for_tests()

    detail_resp = await client.get(f"/api/meetings/{meeting_id}", headers=auth_headers)
    assert detail_resp.status_code == 200
    detail = detail_resp.json()
    assert detail["status"] == "completed"
    assert detail["title"] == "Friday Launch Planning"
    assert detail["stt_used"] == "groq"
    assert detail["has_audio"] is False
    assert len(detail["segments"]) == 2
    assert "## Action Items" in detail["summary"]

    # Confirm server deleted the raw uploaded audio file after transcription.
    audio_dir = app_instance.dependency_overrides[
        next(iter(app_instance.dependency_overrides))
    ]().audio_dir
    assert list(audio_dir.glob("*")) == []

    # Export Markdown
    md_resp = await client.get(f"/api/meetings/{meeting_id}/export.md", headers=auth_headers)
    assert md_resp.status_code == 200
    assert "Friday Launch Planning" in md_resp.text
    assert "- **[00:00]** We agreed to launch on Friday." in md_resp.text


async def test_auto_fallback_to_gemini_resummarize_and_chat(
    app_instance, client, auth_headers, tmp_path: Path, monkeypatch
):
    def broken_groq(chunk_path, settings):
        raise RuntimeError("429 rate limited")

    def fake_gemini_stt(chunk_path, settings):
        return (
            [TranscriptSegment(0.0, 2.0, "Fallback transcript from Gemini Flash.")],
            "Fallback transcript from Gemini Flash.",
            "en",
        )

    def fake_summary(transcript, manual_notes, custom_instructions, settings):
        prefix = f"[{custom_instructions}] " if custom_instructions else ""
        return SummaryResult(
            title="Fallback Session",
            summary_markdown=f"## Overview\n\n{prefix}{transcript}",
        )

    def fake_chat(meeting, history, user_message, settings):
        return f"Grounded answer for '{user_message}' ({len(history)} prior turns)."

    monkeypatch.setattr("app.services.stt._transcribe_chunk_groq_sync", broken_groq)
    monkeypatch.setattr("app.services.stt._transcribe_chunk_gemini_sync", fake_gemini_stt)
    monkeypatch.setattr("app.services.summarizer._generate_summary_sync", fake_summary)
    monkeypatch.setattr("app.services.chat._answer_question_sync", fake_chat)

    created = await client.post(
        "/api/meetings",
        headers=auth_headers,
        json={"title": "Fallback Session", "manual_notes": "note", "stt_provider": "auto"},
    )
    meeting_id = created.json()["id"]

    audio_file = make_sine_m4a(tmp_path / "fb.m4a", duration_sec=2.0)
    with audio_file.open("rb") as f:
        up = await client.post(
            f"/api/meetings/{meeting_id}/audio",
            headers=auth_headers,
            files={"file": ("fb.m4a", f, "audio/m4a")},
        )
    assert up.status_code == 202
    await app_instance.state.worker.drain_for_tests()

    detail = (await client.get(f"/api/meetings/{meeting_id}", headers=auth_headers)).json()
    assert detail["status"] == "completed"
    assert detail["stt_used"] == "gemini"

    resum = await client.post(
        f"/api/meetings/{meeting_id}/resummarize",
        headers=auth_headers,
        json={"manual_notes": "updated note", "custom_instructions": "keep short"},
    )
    assert resum.status_code == 202
    await app_instance.state.worker.drain_for_tests()

    detail2 = (await client.get(f"/api/meetings/{meeting_id}", headers=auth_headers)).json()
    assert detail2["manual_notes"] == "updated note"
    assert "[keep short]" in detail2["summary"]

    chat_post = await client.post(
        f"/api/meetings/{meeting_id}/chat",
        headers=auth_headers,
        json={"message": "What happened?"},
    )
    assert chat_post.status_code == 200
    assert "Grounded answer" in chat_post.json()["assistant_message"]["content"]

    chat_list = await client.get(f"/api/meetings/{meeting_id}/chat", headers=auth_headers)
    assert len(chat_list.json()) == 2

    chat_clear = await client.delete(f"/api/meetings/{meeting_id}/chat", headers=auth_headers)
    assert chat_clear.status_code == 200
    assert (await client.get(f"/api/meetings/{meeting_id}/chat", headers=auth_headers)).json() == []


async def test_quick_upload_one_step_pipeline(
    app_instance, client, auth_headers, tmp_path: Path, monkeypatch
):
    def fake_groq(chunk_path, settings):
        return (
            [
                TranscriptSegment(0.0, 1.2, "We agreed to launch on Friday."),
                TranscriptSegment(1.2, 2.0, "Alex will prepare release notes."),
            ],
            "We agreed to launch on Friday. Alex will prepare release notes.",
            "en",
        )

    def fake_summary(transcript, manual_notes, custom_instructions, settings):
        assert "Friday" in transcript
        assert "check deploy" in manual_notes
        return SummaryResult(
            title="Friday Launch Planning",
            summary_markdown=(
                "## Overview\n\nTeam aligned on launching Friday.\n\n"
                "## Action Items\n\n- [ ] Alex: Prepare release notes\n"
            ),
        )

    monkeypatch.setattr("app.services.stt._transcribe_chunk_groq_sync", fake_groq)
    monkeypatch.setattr("app.services.summarizer._generate_summary_sync", fake_summary)

    audio_file = make_sine_m4a(tmp_path / "quick.m4a", duration_sec=2.0)
    with audio_file.open("rb") as f:
        up = await client.post(
            "/api/meetings/quick-upload",
            headers=auth_headers,
            data={"title": "", "manual_notes": "- check deploy", "stt_provider": "auto"},
            files={"file": ("quick.m4a", f, "audio/m4a")},
        )
    assert up.status_code == 202
    meeting_id = up.json()["id"]
    assert up.json()["status"] == "queued"

    await app_instance.state.worker.drain_for_tests()

    detail_resp = await client.get(f"/api/meetings/{meeting_id}", headers=auth_headers)
    assert detail_resp.status_code == 200
    detail = detail_resp.json()
    assert detail["status"] == "completed"
    assert detail["title"] == "Friday Launch Planning"
    assert detail["stt_used"] == "groq"
    assert detail["has_audio"] is False
    assert len(detail["segments"]) == 2
    assert "## Action Items" in detail["summary"]

    audio_dir = app_instance.dependency_overrides[
        next(iter(app_instance.dependency_overrides))
    ]().audio_dir
    assert list(audio_dir.glob("*")) == []


async def test_quick_upload_custom_title_and_idempotent_client_id(
    app_instance, client, auth_headers, tmp_path: Path, monkeypatch
):
    def fake_groq(chunk_path, settings):
        return (
            [TranscriptSegment(0.0, 2.0, "Discussed database sharding.")],
            "Discussed database sharding.",
            "en",
        )

    def fake_summary(transcript, manual_notes, custom_instructions, settings):
        return SummaryResult(
            title="AI Suggested Title",
            summary_markdown="## Overview\n\nDatabase sharding overview.",
        )

    monkeypatch.setattr("app.services.stt._transcribe_chunk_groq_sync", fake_groq)
    monkeypatch.setattr("app.services.summarizer._generate_summary_sync", fake_summary)

    audio_file = make_sine_m4a(tmp_path / "arch.m4a", duration_sec=2.0)
    with audio_file.open("rb") as f:
        r1 = await client.post(
            "/api/meetings/quick-upload",
            headers=auth_headers,
            data={"title": "Architecture Review", "client_id": "shortcut-uuid-1"},
            files={"file": ("arch.m4a", f, "audio/m4a")},
        )
    assert r1.status_code == 202
    m1 = r1.json()
    await app_instance.state.worker.drain_for_tests()

    detail = (await client.get(f"/api/meetings/{m1['id']}", headers=auth_headers)).json()
    assert detail["title"] == "Architecture Review"
    assert detail["status"] == "completed"

    with audio_file.open("rb") as f:
        r2 = await client.post(
            "/api/meetings/quick-upload",
            headers=auth_headers,
            data={"title": "Architecture Review", "client_id": "shortcut-uuid-1"},
            files={"file": ("arch.m4a", f, "audio/m4a")},
        )
    assert r2.status_code == 202
    assert r2.json()["id"] == m1["id"]
    await app_instance.state.worker.drain_for_tests()

    listing = await client.get("/api/meetings", headers=auth_headers)
    assert listing.status_code == 200
    assert listing.json()["total"] == 1


async def test_quick_upload_invalid_audio_leaves_no_orphan(app_instance, client, auth_headers):
    resp = await client.post(
        "/api/meetings/quick-upload",
        headers=auth_headers,
        data={"title": "Corrupt Upload"},
        files={"file": ("bad.m4a", b"not-valid-audio-data", "audio/m4a")},
    )
    assert resp.status_code == 400

    listing = await client.get("/api/meetings", headers=auth_headers)
    assert listing.status_code == 200
    assert listing.json()["total"] == 0

    audio_dir = app_instance.dependency_overrides[
        next(iter(app_instance.dependency_overrides))
    ]().audio_dir
    assert list(audio_dir.iterdir()) == []


async def test_quick_upload_requires_auth(client, tmp_path: Path):
    audio_file = make_sine_m4a(tmp_path / "unauth.m4a", duration_sec=1.0)
    with audio_file.open("rb") as f:
        resp = await client.post(
            "/api/meetings/quick-upload",
            files={"file": ("unauth.m4a", f, "audio/m4a")},
        )
    assert resp.status_code == 401
