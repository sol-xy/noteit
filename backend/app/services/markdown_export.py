"""Render meetings into portable Markdown (Obsidian / Notion / Apple Notes)."""

from __future__ import annotations

from typing import Any


def format_timestamp(seconds: float) -> str:
    """Format seconds as MM:SS or HH:MM:SS."""
    total = max(0, int(seconds))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    if hours > 0:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def _escape_yaml_str(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    return f'"{escaped}"'


def render_meeting_markdown(
    meeting: dict[str, Any], segments: list[dict[str, Any]]
) -> str:
    """Build a complete Markdown export with YAML frontmatter."""
    duration = meeting.get("duration_seconds")
    duration_str = format_timestamp(duration) if duration is not None else "unknown"

    provider = str(meeting.get("stt_used") or meeting.get("stt_provider") or "")
    lines = [
        "---",
        f"title: {_escape_yaml_str(str(meeting.get('title') or 'Untitled Meeting'))}",
        f"date: {_escape_yaml_str(str(meeting.get('created_at') or ''))}",
        f"duration: {_escape_yaml_str(duration_str)}",
        f"stt_provider: {_escape_yaml_str(provider)}",
        "---",
        "",
        f"# {meeting.get('title') or 'Untitled Meeting'}",
        "",
    ]

    summary = (meeting.get("summary") or "").strip()
    if summary:
        lines.extend(["## Enhanced Summary", "", summary, ""])

    manual_notes = (meeting.get("manual_notes") or "").strip()
    if manual_notes:
        lines.extend(["## My Notes", "", manual_notes, ""])

    lines.extend(["## Transcript", ""])
    if segments:
        for seg in segments:
            ts = format_timestamp(float(seg.get("start_sec", 0.0)))
            text = str(seg.get("text", "")).strip()
            if text:
                lines.append(f"- **[{ts}]** {text}")
    else:
        transcript = (meeting.get("transcript") or "").strip()
        if transcript:
            lines.append(transcript)
        else:
            lines.append("_No transcript available._")

    lines.append("")
    return "\n".join(lines)
