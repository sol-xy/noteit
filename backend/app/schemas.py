"""Pydantic request and response schemas."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

MeetingStatus = Literal[
    "created",
    "queued",
    "transcribing",
    "summarizing",
    "completed",
    "failed",
]

SttProviderChoice = Literal["auto", "groq", "gemini"]


class LoginRequest(BaseModel):
    token: str = Field(..., min_length=1, max_length=512)


class AuthStatusResponse(BaseModel):
    authenticated: bool
    auth_method: str
    default_stt_provider: str


class MeetingCreateRequest(BaseModel):
    client_id: str | None = Field(default=None, max_length=128)
    title: str = Field(default="Untitled Meeting", min_length=1, max_length=200)
    manual_notes: str = Field(default="", max_length=100000)
    stt_provider: SttProviderChoice = "auto"


class MeetingUpdateRequest(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    manual_notes: str | None = Field(default=None, max_length=100000)


class ResummarizeRequest(BaseModel):
    manual_notes: str | None = Field(default=None, max_length=100000)
    custom_instructions: str | None = Field(default=None, max_length=4000)


class TranscriptSegmentOut(BaseModel):
    seq: int
    start_sec: float
    end_sec: float
    text: str


class MeetingSummaryOut(BaseModel):
    id: str
    client_id: str | None
    title: str
    status: str
    error_message: str | None
    manual_notes: str
    summary: str
    language: str | None
    duration_seconds: float | None
    stt_provider: str
    stt_used: str | None
    has_audio: bool
    created_at: str
    updated_at: str


class MeetingDetailOut(MeetingSummaryOut):
    transcript: str
    segments: list[TranscriptSegmentOut] = Field(default_factory=list)


class MeetingListResponse(BaseModel):
    meetings: list[MeetingSummaryOut]
    total: int


class ChatMessageOut(BaseModel):
    id: int
    meeting_id: str
    role: Literal["user", "assistant"]
    content: str
    created_at: str


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=8000)


class ChatResponse(BaseModel):
    user_message: ChatMessageOut
    assistant_message: ChatMessageOut
