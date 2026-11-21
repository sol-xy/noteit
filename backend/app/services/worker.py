"""Async background job worker with startup recovery and guaranteed audio cleanup."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import shutil
from dataclasses import dataclass
from pathlib import Path

from app.config import Settings
from app.db import Database
from app.services.stt import transcribe_audio
from app.services.summarizer import generate_enhanced_notes

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class WorkerJob:
    kind: str  # "transcribe" | "summarize"
    meeting_id: str
    custom_instructions: str | None = None


def _sanitize_error(exc: Exception) -> str:
    msg = str(exc).strip() or exc.__class__.__name__
    return msg[:500]


def _delete_file_quietly(path_str: str | None) -> None:
    if not path_str:
        return
    try:
        Path(path_str).unlink(missing_ok=True)
    except Exception as exc:
        logger.warning("Failed deleting audio file %s: %s", path_str, exc)


class MeetingWorker:
    """Single-process async queue executing STT -> cleanup -> summarization."""

    def __init__(self, db: Database, settings: Settings) -> None:
        self.db = db
        self.settings = settings
        self._queue: asyncio.Queue[WorkerJob] = asyncio.Queue()
        self._task: asyncio.Task[None] | None = None

    async def start(self) -> None:
        """Start the worker loop and re-enqueue interrupted jobs from previous runs."""
        if self._task is not None and not self._task.done():
            return
        self._task = asyncio.create_task(self._run_loop(), name="noteit-worker")
        await self._recover_incomplete_jobs()

    async def stop(self) -> None:
        """Gracefully stop the background worker task."""
        if self._task is None:
            return
        self._task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self._task
        self._task = None

    async def enqueue_transcription(self, meeting_id: str) -> None:
        await self._queue.put(WorkerJob(kind="transcribe", meeting_id=meeting_id))

    async def enqueue_summarization(
        self, meeting_id: str, custom_instructions: str | None = None
    ) -> None:
        await self._queue.put(
            WorkerJob(
                kind="summarize",
                meeting_id=meeting_id,
                custom_instructions=custom_instructions,
            )
        )

    async def drain_for_tests(self) -> None:
        """Wait until all currently queued jobs finish (used in automated tests)."""
        await self._queue.join()

    async def _recover_incomplete_jobs(self) -> None:
        incomplete = await self.db.list_incomplete_meetings()
        for meeting in incomplete:
            meeting_id = meeting["id"]
            status = meeting["status"]
            audio_path = meeting.get("audio_path")
            transcript = (meeting.get("transcript") or "").strip()

            if status in {"queued", "transcribing"}:
                if audio_path and Path(audio_path).exists():
                    await self.db.update_meeting_fields(meeting_id, status="queued")
                    await self.enqueue_transcription(meeting_id)
                elif transcript:
                    await self.db.update_meeting_fields(meeting_id, status="summarizing")
                    await self.enqueue_summarization(meeting_id)
                else:
                    await self.db.update_meeting_fields(
                        meeting_id,
                        status="failed",
                        error_message=(
                            "Audio file missing after server restart; please retry upload."
                        ),
                    )
            elif status == "summarizing":
                if transcript or (meeting.get("manual_notes") or "").strip():
                    await self.enqueue_summarization(meeting_id)
                else:
                    await self.db.update_meeting_fields(
                        meeting_id,
                        status="failed",
                        error_message="Transcript missing after server restart.",
                    )

    async def _run_loop(self) -> None:
        while True:
            job = await self._queue.get()
            try:
                if job.kind == "transcribe":
                    await self._process_transcription_pipeline(job.meeting_id)
                elif job.kind == "summarize":
                    await self._process_summarization_only(
                        job.meeting_id, job.custom_instructions
                    )
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # pragma: no cover - defensive guard
                logger.exception("Unhandled worker error for %s: %s", job.meeting_id, exc)
            finally:
                self._queue.task_done()

    async def _process_transcription_pipeline(self, meeting_id: str) -> None:
        meeting = await self.db.get_meeting(meeting_id)
        if meeting is None:
            return

        audio_path_str = meeting.get("audio_path")
        if not audio_path_str or not Path(audio_path_str).exists():
            await self.db.update_meeting_fields(
                meeting_id,
                status="failed",
                error_message="Audio file not found for transcription.",
            )
            return

        job_tmp_dir = self.settings.tmp_dir / meeting_id
        try:
            await self.db.update_meeting_fields(
                meeting_id, status="transcribing", error_message=None
            )
            result = await transcribe_audio(
                audio_path=Path(audio_path_str),
                provider=meeting.get("stt_provider") or self.settings.default_stt_provider,
                work_dir=job_tmp_dir,
                settings=self.settings,
            )

            segments_payload = [
                {"start_sec": seg.start_sec, "end_sec": seg.end_sec, "text": seg.text}
                for seg in result.segments
            ]
            await self.db.replace_segments(meeting_id, segments_payload)
            await self.db.update_meeting_fields(
                meeting_id,
                transcript=result.text,
                language=result.language,
                stt_used=result.provider_used,
            )

            # Delete raw audio immediately after transcription succeeds when configured.
            if self.settings.delete_audio_after_transcription:
                _delete_file_quietly(audio_path_str)
                await self.db.update_meeting_fields(meeting_id, audio_path=None)

            await self._process_summarization_only(meeting_id, custom_instructions=None)
        except Exception as exc:
            logger.warning("Transcription failed for %s: %s", meeting_id, exc)
            await self.db.update_meeting_fields(
                meeting_id,
                status="failed",
                error_message=_sanitize_error(exc),
            )
        finally:
            shutil.rmtree(job_tmp_dir, ignore_errors=True)

    async def _process_summarization_only(
        self, meeting_id: str, custom_instructions: str | None
    ) -> None:
        meeting = await self.db.get_meeting(meeting_id)
        if meeting is None:
            return
        try:
            await self.db.update_meeting_fields(
                meeting_id, status="summarizing", error_message=None
            )
            summary_result = await generate_enhanced_notes(
                transcript=meeting.get("transcript") or "",
                manual_notes=meeting.get("manual_notes") or "",
                custom_instructions=custom_instructions,
                settings=self.settings,
            )

            existing_title = (meeting.get("title") or "").strip()
            new_title = (
                summary_result.title
                if existing_title in {"", "Untitled Meeting"}
                else existing_title
            )

            await self.db.update_meeting_fields(
                meeting_id,
                title=new_title,
                summary=summary_result.summary_markdown,
                status="completed",
                error_message=None,
            )
        except Exception as exc:
            logger.warning("Summarization failed for %s: %s", meeting_id, exc)
            await self.db.update_meeting_fields(
                meeting_id,
                status="failed",
                error_message=_sanitize_error(exc),
            )
