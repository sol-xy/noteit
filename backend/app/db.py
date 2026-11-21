"""Async SQLite repository for meetings, transcript segments, and chat messages."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import aiosqlite


def utc_now_iso() -> str:
    """Return current UTC ISO-8601 timestamp."""
    return datetime.now(UTC).isoformat()


class Database:
    """SQLite repository with WAL mode and cascade deletes."""

    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path

    @asynccontextmanager
    async def _connect(self) -> AsyncIterator[aiosqlite.Connection]:
        conn = await aiosqlite.connect(self.db_path)
        conn.row_factory = aiosqlite.Row
        await conn.execute("PRAGMA foreign_keys = ON;")
        await conn.execute("PRAGMA busy_timeout = 5000;")
        try:
            yield conn
        finally:
            await conn.close()

    async def init(self) -> None:
        """Create tables and enable WAL mode."""
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        async with self._connect() as conn:
            await conn.execute("PRAGMA journal_mode = WAL;")
            await conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS meetings (
                    id TEXT PRIMARY KEY,
                    client_id TEXT UNIQUE,
                    title TEXT NOT NULL,
                    status TEXT NOT NULL,
                    error_message TEXT,
                    manual_notes TEXT NOT NULL DEFAULT '',
                    transcript TEXT NOT NULL DEFAULT '',
                    summary TEXT NOT NULL DEFAULT '',
                    language TEXT,
                    duration_seconds REAL,
                    stt_provider TEXT NOT NULL DEFAULT 'auto',
                    stt_used TEXT,
                    audio_path TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_meetings_created_at
                    ON meetings(created_at DESC);

                CREATE TABLE IF NOT EXISTS transcript_segments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    start_sec REAL NOT NULL,
                    end_sec REAL NOT NULL,
                    text TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_segments_meeting_seq
                    ON transcript_segments(meeting_id, seq);

                CREATE TABLE IF NOT EXISTS chat_messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_chat_meeting_id
                    ON chat_messages(meeting_id, id);
                """
            )
            await conn.commit()

    async def create_or_get_meeting(
        self,
        *,
        client_id: str | None,
        title: str,
        manual_notes: str,
        stt_provider: str,
    ) -> tuple[dict[str, Any], bool]:
        """Create a meeting or return the existing row matching `client_id`."""
        async with self._connect() as conn:
            if client_id:
                cur = await conn.execute(
                    "SELECT * FROM meetings WHERE client_id = ?",
                    (client_id,),
                )
                existing = await cur.fetchone()
                if existing is not None:
                    return dict(existing), False

            meeting_id = str(uuid.uuid4())
            now = utc_now_iso()
            await conn.execute(
                """
                INSERT INTO meetings (
                    id, client_id, title, status, manual_notes,
                    stt_provider, created_at, updated_at
                )
                VALUES (?, ?, ?, 'created', ?, ?, ?, ?)
                """,
                (meeting_id, client_id, title, manual_notes, stt_provider, now, now),
            )
            await conn.commit()
            cur = await conn.execute("SELECT * FROM meetings WHERE id = ?", (meeting_id,))
            row = await cur.fetchone()
            assert row is not None
            return dict(row), True

    async def get_meeting(self, meeting_id: str) -> dict[str, Any] | None:
        async with self._connect() as conn:
            cur = await conn.execute("SELECT * FROM meetings WHERE id = ?", (meeting_id,))
            row = await cur.fetchone()
            return dict(row) if row is not None else None

    async def list_meetings(
        self, *, query: str | None = None, limit: int = 50, offset: int = 0
    ) -> tuple[list[dict[str, Any]], int]:
        async with self._connect() as conn:
            where = ""
            params: list[Any] = []
            if query and query.strip():
                like = f"%{query.strip()}%"
                where = (
                    "WHERE title LIKE ? OR manual_notes LIKE ? "
                    "OR summary LIKE ? OR transcript LIKE ?"
                )
                params.extend([like, like, like, like])

            count_cur = await conn.execute(
                f"SELECT COUNT(*) AS cnt FROM meetings {where}",
                params,
            )
            count_row = await count_cur.fetchone()
            total = int(count_row["cnt"]) if count_row else 0

            cur = await conn.execute(
                f"""
                SELECT * FROM meetings
                {where}
                ORDER BY created_at DESC
                LIMIT ? OFFSET ?
                """,
                [*params, limit, offset],
            )
            rows = [dict(r) for r in await cur.fetchall()]
            return rows, total

    async def update_meeting_fields(
        self, meeting_id: str, **fields: Any
    ) -> dict[str, Any] | None:
        """Update specific allowed columns on a meeting row."""
        allowed = {
            "title",
            "status",
            "error_message",
            "manual_notes",
            "transcript",
            "summary",
            "language",
            "duration_seconds",
            "stt_provider",
            "stt_used",
            "audio_path",
        }
        updates = {k: v for k, v in fields.items() if k in allowed}
        if not updates:
            return await self.get_meeting(meeting_id)
        updates["updated_at"] = utc_now_iso()
        set_clause = ", ".join(f"{k} = ?" for k in updates)
        values = [*updates.values(), meeting_id]

        async with self._connect() as conn:
            await conn.execute(
                f"UPDATE meetings SET {set_clause} WHERE id = ?",
                values,
            )
            await conn.commit()
            cur = await conn.execute("SELECT * FROM meetings WHERE id = ?", (meeting_id,))
            row = await cur.fetchone()
            return dict(row) if row is not None else None

    async def delete_meeting(self, meeting_id: str) -> dict[str, Any] | None:
        """Delete a meeting (and cascaded segments/chat) and return the old row if found."""
        async with self._connect() as conn:
            cur = await conn.execute("SELECT * FROM meetings WHERE id = ?", (meeting_id,))
            existing = await cur.fetchone()
            if existing is None:
                return None
            await conn.execute("DELETE FROM meetings WHERE id = ?", (meeting_id,))
            await conn.commit()
            return dict(existing)

    async def replace_segments(
        self, meeting_id: str, segments: list[dict[str, Any]]
    ) -> None:
        """Replace all transcript segments for a meeting."""
        async with self._connect() as conn:
            await conn.execute(
                "DELETE FROM transcript_segments WHERE meeting_id = ?",
                (meeting_id,),
            )
            await conn.executemany(
                """
                INSERT INTO transcript_segments (meeting_id, seq, start_sec, end_sec, text)
                VALUES (?, ?, ?, ?, ?)
                """,
                [
                    (
                        meeting_id,
                        idx,
                        float(seg["start_sec"]),
                        float(seg["end_sec"]),
                        str(seg["text"]),
                    )
                    for idx, seg in enumerate(segments)
                ],
            )
            await conn.commit()

    async def get_segments(self, meeting_id: str) -> list[dict[str, Any]]:
        async with self._connect() as conn:
            cur = await conn.execute(
                """
                SELECT seq, start_sec, end_sec, text
                FROM transcript_segments
                WHERE meeting_id = ?
                ORDER BY seq ASC
                """,
                (meeting_id,),
            )
            return [dict(r) for r in await cur.fetchall()]

    async def list_chat_messages(self, meeting_id: str) -> list[dict[str, Any]]:
        async with self._connect() as conn:
            cur = await conn.execute(
                """
                SELECT id, meeting_id, role, content, created_at
                FROM chat_messages
                WHERE meeting_id = ?
                ORDER BY id ASC
                """,
                (meeting_id,),
            )
            return [dict(r) for r in await cur.fetchall()]

    async def add_chat_message(
        self, meeting_id: str, role: str, content: str
    ) -> dict[str, Any]:
        now = utc_now_iso()
        async with self._connect() as conn:
            cur = await conn.execute(
                """
                INSERT INTO chat_messages (meeting_id, role, content, created_at)
                VALUES (?, ?, ?, ?)
                """,
                (meeting_id, role, content, now),
            )
            await conn.commit()
            row_id = cur.lastrowid
            fetch = await conn.execute(
                "SELECT id, meeting_id, role, content, created_at FROM chat_messages WHERE id = ?",
                (row_id,),
            )
            row = await fetch.fetchone()
            assert row is not None
            return dict(row)

    async def clear_chat_messages(self, meeting_id: str) -> None:
        async with self._connect() as conn:
            await conn.execute(
                "DELETE FROM chat_messages WHERE meeting_id = ?",
                (meeting_id,),
            )
            await conn.commit()

    async def list_incomplete_meetings(self) -> list[dict[str, Any]]:
        """Return meetings left in queued/transcribing/summarizing across restarts."""
        async with self._connect() as conn:
            cur = await conn.execute(
                """
                SELECT * FROM meetings
                WHERE status IN ('queued', 'transcribing', 'summarizing')
                ORDER BY created_at ASC
                """
            )
            return [dict(r) for r in await cur.fetchall()]
