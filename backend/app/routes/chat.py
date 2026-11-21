"""Per-meeting grounded AI chat routes."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status

from app.auth import require_auth
from app.config import Settings, get_settings
from app.db import Database
from app.deps import get_db
from app.schemas import ChatMessageOut, ChatRequest, ChatResponse
from app.services.chat import ChatError, answer_meeting_question

router = APIRouter(
    prefix="/api/meetings/{meeting_id}/chat",
    tags=["chat"],
    dependencies=[Depends(require_auth)],
)


@router.get("", response_model=list[ChatMessageOut])
async def list_chat(
    meeting_id: str,
    db: Database = Depends(get_db),
) -> list[ChatMessageOut]:
    meeting = await db.get_meeting(meeting_id)
    if meeting is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")
    rows = await db.list_chat_messages(meeting_id)
    return [ChatMessageOut(**r) for r in rows]


@router.post("", response_model=ChatResponse)
async def send_chat_message(
    meeting_id: str,
    payload: ChatRequest,
    db: Database = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> ChatResponse:
    meeting = await db.get_meeting(meeting_id)
    if meeting is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")

    history = await db.list_chat_messages(meeting_id)
    prompt = payload.message.strip()

    try:
        answer = await answer_meeting_question(
            meeting=meeting,
            history=history,
            user_message=prompt,
            settings=settings,
        )
    except ChatError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(exc),
        ) from exc

    user_msg = await db.add_chat_message(meeting_id, "user", prompt)
    assistant_msg = await db.add_chat_message(meeting_id, "assistant", answer)
    return ChatResponse(
        user_message=ChatMessageOut(**user_msg),
        assistant_message=ChatMessageOut(**assistant_msg),
    )


@router.delete("")
async def clear_chat(
    meeting_id: str,
    db: Database = Depends(get_db),
) -> dict[str, bool]:
    meeting = await db.get_meeting(meeting_id)
    if meeting is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")
    await db.clear_chat_messages(meeting_id)
    return {"cleared": True}
