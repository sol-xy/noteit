"""Grounded per-meeting Q&A chat service via Gemini."""

from __future__ import annotations

import asyncio
from typing import Any

from google import genai
from google.genai import types

from app.config import Settings


class ChatError(Exception):
    """Raised when meeting Q&A fails."""


CHAT_SYSTEM_PROMPT = (
    "You are NoteIt, a grounded meeting assistant.\n"
    "Answer the user's question using ONLY the meeting context below "
    "(title, manual notes, enhanced summary, and transcript) plus the conversation history.\n"
    "If the answer is not covered in the meeting materials, say clearly that it was not "
    "mentioned in the meeting.\n"
    "Keep responses clear, direct, and formatted in concise Markdown."
)


def _answer_question_sync(
    meeting: dict[str, Any],
    history: list[dict[str, Any]],
    user_message: str,
    settings: Settings,
) -> str:
    if not settings.gemini_api_key.strip():
        raise ChatError("GEMINI_API_KEY is not configured on the server")

    context_block = "\n".join(
        [
            f"Meeting Title: {meeting.get('title') or 'Untitled Meeting'}",
            "",
            "### User's Manual Notes",
            (meeting.get("manual_notes") or "").strip() or "(none)",
            "",
            "### Enhanced Summary",
            (meeting.get("summary") or "").strip() or "(none)",
            "",
            "### Full Transcript",
            (meeting.get("transcript") or "").strip() or "(none)",
        ]
    )

    contents: list[types.Content] = [
        types.Content(
            role="user",
            parts=[types.Part.from_text(text=f"Here is the meeting context:\n\n{context_block}")],
        ),
        types.Content(
            role="model",
            parts=[types.Part.from_text(text="Understood. Ask me anything about this meeting.")],
        ),
    ]

    # Include recent chat turns for continuity without blowing context limits.
    for turn in history[-16:]:
        role = "user" if turn["role"] == "user" else "model"
        contents.append(
            types.Content(role=role, parts=[types.Part.from_text(text=turn["content"])])
        )

    contents.append(
        types.Content(role="user", parts=[types.Part.from_text(text=user_message)])
    )

    client = genai.Client(api_key=settings.gemini_api_key)
    response = client.models.generate_content(
        model=settings.gemini_model,
        contents=contents,
        config=types.GenerateContentConfig(
            system_instruction=CHAT_SYSTEM_PROMPT,
            temperature=0.2,
        ),
    )
    answer = (response.text or "").strip()
    if not answer:
        raise ChatError("Gemini returned an empty answer")
    return answer


async def answer_meeting_question(
    *,
    meeting: dict[str, Any],
    history: list[dict[str, Any]],
    user_message: str,
    settings: Settings,
) -> str:
    """Answer a question grounded in a specific meeting's transcript and notes."""
    return await asyncio.to_thread(
        _answer_question_sync,
        meeting,
        history,
        user_message,
        settings,
    )
