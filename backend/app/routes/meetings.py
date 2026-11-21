"""Meetings CRUD, audio upload, retry, re-summarize, and Markdown export endpoints."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Query,
    Response,
    UploadFile,
    status,
)
from fastapi.responses import JSONResponse

from app.auth import require_auth
from app.config import Settings, get_settings
from app.db import Database
from app.deps import get_db, get_worker
from app.schemas import (
    MeetingCreateRequest,
    MeetingDetailOut,
    MeetingListResponse,
    MeetingSummaryOut,
    MeetingUpdateRequest,
    ResummarizeRequest,
    TranscriptSegmentOut,
)
from app.services.audio import (
    AudioValidationError,
    UploadTooLargeError,
    probe_audio,
    save_upload_stream,
)
from app.services.markdown_export import render_meeting_markdown
from app.services.worker import MeetingWorker

router = APIRouter(
    prefix="/api/meetings",
    tags=["meetings"],
    dependencies=[Depends(require_auth)],
)


def _row_to_summary(row: dict[str, Any]) -> MeetingSummaryOut:
    audio_path = row.get("audio_path")
    return MeetingSummaryOut(
        id=row["id"],
        client_id=row.get("client_id"),
        title=row["title"],
        status=row["status"],
        error_message=row.get("error_message"),
        manual_notes=row.get("manual_notes") or "",
        summary=row.get("summary") or "",
        language=row.get("language"),
        duration_seconds=row.get("duration_seconds"),
        stt_provider=row.get("stt_provider") or "auto",
        stt_used=row.get("stt_used"),
        has_audio=bool(audio_path and Path(audio_path).exists()),
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def _safe_filename(title: str, meeting_id: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", title.strip()).strip("-")
    if not slug:
        slug = f"meeting-{meeting_id[:8]}"
    return f"{slug[:80]}.md"


@router.get("", response_model=MeetingListResponse)
async def list_meetings(
    q: str | None = Query(default=None, max_length=200),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Database = Depends(get_db),
) -> MeetingListResponse:
    rows, total = await db.list_meetings(query=q, limit=limit, offset=offset)
    return MeetingListResponse(
        meetings=[_row_to_summary(r) for r in rows],
        total=total,
    )


@router.post("", response_model=MeetingSummaryOut, status_code=status.HTTP_201_CREATED)
async def create_meeting(
    payload: MeetingCreateRequest,
    db: Database = Depends(get_db),
) -> Response:
    row, created = await db.create_or_get_meeting(
        client_id=payload.client_id,
        title=payload.title.strip() or "Untitled Meeting",
        manual_notes=payload.manual_notes,
        stt_provider=payload.stt_provider,
    )
    if not created and row["status"] == "created" and payload.manual_notes:
        updated = await db.update_meeting_fields(
            row["id"],
            manual_notes=payload.manual_notes,
            title=payload.title.strip() or row["title"],
        )
        if updated is not None:
            row = updated

    out = _row_to_summary(row)
    return JSONResponse(
        status_code=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        content=out.model_dump(),
    )


@router.get("/{meeting_id}", response_model=MeetingDetailOut)
async def get_meeting(
    meeting_id: str,
    db: Database = Depends(get_db),
) -> MeetingDetailOut:
    row = await db.get_meeting(meeting_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")
    segments = await db.get_segments(meeting_id)
    summary = _row_to_summary(row)
    return MeetingDetailOut(
        **summary.model_dump(),
        transcript=row.get("transcript") or "",
        segments=[TranscriptSegmentOut(**s) for s in segments],
    )


@router.patch("/{meeting_id}", response_model=MeetingSummaryOut)
async def update_meeting(
    meeting_id: str,
    payload: MeetingUpdateRequest,
    db: Database = Depends(get_db),
) -> MeetingSummaryOut:
    existing = await db.get_meeting(meeting_id)
    if existing is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")

    fields: dict[str, Any] = {}
    if payload.title is not None:
        fields["title"] = payload.title.strip() or "Untitled Meeting"
    if payload.manual_notes is not None:
        fields["manual_notes"] = payload.manual_notes

    updated = await db.update_meeting_fields(meeting_id, **fields)
    assert updated is not None
    return _row_to_summary(updated)


@router.delete("/{meeting_id}")
async def delete_meeting(
    meeting_id: str,
    db: Database = Depends(get_db),
) -> dict[str, bool]:
    deleted = await db.delete_meeting(meeting_id)
    if deleted is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")
    audio_path = deleted.get("audio_path")
    if audio_path:
        Path(audio_path).unlink(missing_ok=True)
    return {"deleted": True}


@router.post(
    "/{meeting_id}/audio",
    response_model=MeetingSummaryOut,
    status_code=status.HTTP_202_ACCEPTED,
)
async def upload_meeting_audio(
    meeting_id: str,
    file: UploadFile = File(...),
    stt_provider: str | None = Form(default=None),
    db: Database = Depends(get_db),
    worker: MeetingWorker = Depends(get_worker),
    settings: Settings = Depends(get_settings),
) -> MeetingSummaryOut:
    meeting = await db.get_meeting(meeting_id)
    if meeting is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")

    if stt_provider is not None:
        normalized_provider = stt_provider.strip().lower()
        if normalized_provider not in {"auto", "groq", "gemini"}:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="stt_provider must be one of: auto, groq, gemini",
            )
    else:
        normalized_provider = meeting.get("stt_provider") or settings.default_stt_provider

    ext = Path(file.filename or "audio.m4a").suffix.lower()
    if ext not in {".m4a", ".mp3", ".wav", ".aac", ".flac", ".ogg", ".webm", ".mp4"}:
        ext = ".bin"

    dest_path = settings.audio_dir / f"{meeting_id}{ext}"
    # Remove any old audio file for this meeting before saving the new one.
    old_audio = meeting.get("audio_path")
    if old_audio and old_audio != str(dest_path):
        Path(old_audio).unlink(missing_ok=True)

    try:
        await save_upload_stream(file, dest_path, settings.max_upload_bytes)
        probe = await probe_audio(dest_path, settings.max_audio_seconds)
    except UploadTooLargeError as exc:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=str(exc),
        ) from exc
    except AudioValidationError as exc:
        dest_path.unlink(missing_ok=True)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        ) from exc

    updated = await db.update_meeting_fields(
        meeting_id,
        audio_path=str(dest_path),
        duration_seconds=round(probe.duration_seconds, 2),
        stt_provider=normalized_provider,
        status="queued",
        error_message=None,
    )
    assert updated is not None
    await worker.enqueue_transcription(meeting_id)
    return _row_to_summary(updated)


@router.post(
    "/{meeting_id}/retry",
    response_model=MeetingSummaryOut,
    status_code=status.HTTP_202_ACCEPTED,
)
async def retry_meeting(
    meeting_id: str,
    db: Database = Depends(get_db),
    worker: MeetingWorker = Depends(get_worker),
) -> MeetingSummaryOut:
    meeting = await db.get_meeting(meeting_id)
    if meeting is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")

    audio_path = meeting.get("audio_path")
    if audio_path and Path(audio_path).exists():
        updated = await db.update_meeting_fields(
            meeting_id, status="queued", error_message=None
        )
        assert updated is not None
        await worker.enqueue_transcription(meeting_id)
        return _row_to_summary(updated)

    if (meeting.get("transcript") or "").strip() or (meeting.get("manual_notes") or "").strip():
        updated = await db.update_meeting_fields(
            meeting_id, status="summarizing", error_message=None
        )
        assert updated is not None
        await worker.enqueue_summarization(meeting_id)
        return _row_to_summary(updated)

    raise HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail="No audio file or transcript available to retry",
    )


@router.post(
    "/{meeting_id}/resummarize",
    response_model=MeetingSummaryOut,
    status_code=status.HTTP_202_ACCEPTED,
)
async def resummarize_meeting(
    meeting_id: str,
    payload: ResummarizeRequest,
    db: Database = Depends(get_db),
    worker: MeetingWorker = Depends(get_worker),
) -> MeetingSummaryOut:
    meeting = await db.get_meeting(meeting_id)
    if meeting is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")

    fields: dict[str, Any] = {"status": "summarizing", "error_message": None}
    if payload.manual_notes is not None:
        fields["manual_notes"] = payload.manual_notes

    updated = await db.update_meeting_fields(meeting_id, **fields)
    assert updated is not None
    await worker.enqueue_summarization(
        meeting_id, custom_instructions=payload.custom_instructions
    )
    return _row_to_summary(updated)


@router.get("/{meeting_id}/export.md")
async def export_meeting_markdown(
    meeting_id: str,
    db: Database = Depends(get_db),
) -> Response:
    meeting = await db.get_meeting(meeting_id)
    if meeting is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")
    segments = await db.get_segments(meeting_id)
    md = render_meeting_markdown(meeting, segments)
    filename = _safe_filename(meeting.get("title") or "meeting", meeting_id)
    return Response(
        content=md,
        media_type="text/markdown; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
