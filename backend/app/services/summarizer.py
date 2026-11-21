"""Anarlog-style meeting note enhancement and summarization via Gemini."""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass

from google import genai
from google.genai import types
from pydantic import BaseModel

from app.config import Settings
from app.services.stt import _strip_json_fences


class SummarizerError(Exception):
    """Raised when meeting summarization fails."""


@dataclass(frozen=True)
class SummaryResult:
    title: str
    summary_markdown: str


class _SummarySchema(BaseModel):
    title: str
    summary_markdown: str


SYSTEM_PROMPT = (
    "You are NoteIt, an Anarlog-inspired AI meeting notepad assistant.\n"
    "Your job is to synthesize the user's rough manual meeting notes together with the full\n"
    "meeting transcript into crisp, accurate, well-structured Markdown meeting notes.\n\n"
    "Rules:\n"
    "1. Treat the user's manual notes as priority anchors — preserve their key observations,\n"
    "   phrasing intent, and emphasis, and enrich them with concrete context, details,\n"
    "   decisions, and action items from the transcript.\n"
    "2. Only state facts supported by the transcript or the user's manual notes.\n"
    "   Never invent names, dates, commitments, or decisions.\n"
    "3. Keep the title concise (3 to 8 words) and descriptive of the meeting topic.\n"
    "4. Format `summary_markdown` using clear Markdown sections:\n"
    "   - `## Overview` (2-3 sentence executive summary)\n"
    "   - `## Key Points` (concise bullet list combining manual notes + transcript details)\n"
    "   - `## Decisions` (bullet list, or `- None explicitly recorded.` if none)\n"
    "   - `## Action Items` (markdown checkboxes `- [ ] Owner: task`,\n"
    "     or `- None explicitly assigned.` if none)\n"
    "   - `## Open Questions` (bullet list, omit if none)\n"
    "5. Write in the primary language of the meeting unless custom instructions say otherwise."
)


def _generate_summary_sync(
    transcript: str,
    manual_notes: str,
    custom_instructions: str | None,
    settings: Settings,
) -> SummaryResult:
    if not settings.gemini_api_key.strip():
        raise SummarizerError("GEMINI_API_KEY is not configured on the server")

    parts = [
        "### User's Rough Manual Notes",
        manual_notes.strip() if manual_notes.strip() else "(none provided)",
        "",
        "### Full Meeting Transcript",
        transcript.strip() if transcript.strip() else "(empty transcript)",
    ]
    if custom_instructions and custom_instructions.strip():
        parts.extend(["", "### Additional User Instructions", custom_instructions.strip()])

    client = genai.Client(api_key=settings.gemini_api_key)
    response = client.models.generate_content(
        model=settings.gemini_model,
        contents="\n".join(parts),
        config=types.GenerateContentConfig(
            system_instruction=SYSTEM_PROMPT,
            response_mime_type="application/json",
            response_schema=_SummarySchema,
            temperature=0.2,
        ),
    )

    raw = (response.text or "").strip()
    if not raw:
        raise SummarizerError("Gemini returned an empty summary response")

    data = json.loads(_strip_json_fences(raw))
    parsed = _SummarySchema.model_validate(data)
    title = parsed.title.strip() or "Meeting Notes"
    summary_md = parsed.summary_markdown.strip()
    if not summary_md:
        raise SummarizerError("Gemini returned an empty summary_markdown field")
    return SummaryResult(title=title[:200], summary_markdown=summary_md)


async def generate_enhanced_notes(
    *,
    transcript: str,
    manual_notes: str,
    custom_instructions: str | None = None,
    settings: Settings,
) -> SummaryResult:
    """Merge rough manual notes and transcript into Anarlog-style enhanced Markdown."""
    if not transcript.strip() and not manual_notes.strip():
        return SummaryResult(
            title="Empty Recording",
            summary_markdown=(
                "## Overview\n\nNo speech or manual notes were captured in this session."
            ),
        )
    return await asyncio.to_thread(
        _generate_summary_sync,
        transcript,
        manual_notes,
        custom_instructions,
        settings,
    )
