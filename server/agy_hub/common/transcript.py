"""Transcript parsing, prompt sanitization, and Antigravity workspace URI resolution."""

from __future__ import annotations

import json
import os
import re
import urllib.parse
from typing import Any

from agy_hub.common.schemas import ToolCallItem, TranscriptStep

IGNORED_MSG_TYPES: set[str] = {
    "GENERIC",
    "SYSTEM_MESSAGE",
    "CHECKPOINT",
    "STATUS_UPDATE",
    "TASK_NOTIFICATION",
    "USER_APPROVAL_RESPONSE",
}


def clean_display_content(raw_text: str) -> str:
    """Clean internal system tags and raw CLI noise from transcript content."""
    if not raw_text:
        return ""

    user_match = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", raw_text, re.DOTALL)
    if user_match:
        return user_match.group(1).strip()

    cleaned = re.sub(r"<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>", "", raw_text, flags=re.DOTALL)
    cleaned = re.sub(r"<SYSTEM_MESSAGE>.*?</SYSTEM_MESSAGE>", "", cleaned, flags=re.DOTALL)
    cleaned = re.sub(r"<INSTRUCTIONS>.*?</INSTRUCTIONS>", "", cleaned, flags=re.DOTALL)

    if (
        "The following is a" in cleaned
        or "<SYSTEM_MESSAGE>" in cleaned
        or "YOU MUST TAKE ONE OF THE FOLLOWING TWO ACTIONS" in cleaned
    ):
        return ""

    stripped = cleaned.strip()
    if stripped.startswith("Created At: 202") and (
        "Command output:" in stripped
        or "Command exited with code" in stripped
        or "Tool is running as a background task" in stripped
        or "cancelled" in stripped
        or "Task Description:" in stripped
        or "Log output:" in stripped
    ):
        return ""

    return stripped


def _parse_single_workspace_uri(raw_uri: str) -> tuple[str | None, str | None]:
    decoded = urllib.parse.unquote(raw_uri).split("#", 1)[0].split("?", 1)[0]
    if decoded.lower().startswith("file:///"):
        rest = decoded[8:]
        # Windows path embedded in URI, e.g. file:///C:/Users/dev/proj or file:///Z:/
        if len(rest) >= 2 and rest[1] == ":":
            win_path = rest.replace("/", "\\")
            clean_win = win_path.rstrip("\\/")
            if len(clean_win) == 2 and clean_win[1] == ":":
                return clean_win, clean_win + "\\"
            folder_name = clean_win.split("\\")[-1] or clean_win
            return folder_name, clean_win
        # POSIX path, e.g. file:///home/deck/proj
        posix_path = "/" + rest.lstrip("/")
        clean_posix = posix_path.rstrip("/") or "/"
        folder_name = clean_posix.rsplit("/", 1)[-1] or clean_posix
        return folder_name, clean_posix

    if decoded.lower().startswith("file://"):
        local_path = decoded[7:]
        clean_path = local_path.rstrip("/\\") or "/"
        folder_name = os.path.basename(clean_path) or clean_path
        return folder_name, clean_path
    return None, None


def parse_all_workspace_paths(ws_uris: str | None) -> list[str]:
    """Extract all valid local workspace paths from a workspace_uris JSON list."""
    if not ws_uris or ws_uris.strip() in ("", "[]"):
        return []
    paths: list[str] = []
    try:
        uris = json.loads(ws_uris)
        if not isinstance(uris, list):
            return []
        for raw_uri in uris:
            if not isinstance(raw_uri, str):
                continue
            _, local_path = _parse_single_workspace_uri(raw_uri)
            if local_path and local_path not in paths:
                paths.append(local_path)
    except Exception:
        pass
    return paths


def parse_project_name_and_path(ws_uris: str | None) -> tuple[str | None, str | None]:
    """Parse Antigravity SQLite workspace_uris JSON field into (project_name, local_path).

    Handles Windows drive roots (e.g. file:///Z:/ -> ('Z:', 'Z:\\')) as well as
    Windows/POSIX project directories consistently across platforms.
    """
    if not ws_uris or ws_uris.strip() in ("", "[]"):
        return None, None
    try:
        uris = json.loads(ws_uris)
        if not isinstance(uris, list) or not uris:
            return None, None
        raw_uri = uris[0]
        if not isinstance(raw_uri, str):
            return None, None
        return _parse_single_workspace_uri(raw_uri)
    except Exception:
        pass
    return None, None


def _normalize_tool_args(raw_args: Any) -> dict[str, Any]:
    if isinstance(raw_args, dict):
        return raw_args
    if isinstance(raw_args, str):
        try:
            parsed = json.loads(raw_args)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            return {"raw": raw_args}
    return {}


def _compact_chat_tool_args(args: dict[str, Any], max_str_chars: int = 4000) -> dict[str, Any]:
    """Bound huge inline file contents inside chat tool_calls while preserving structured fields."""
    compacted: dict[str, Any] = {}
    for k, v in args.items():
        if isinstance(v, str) and len(v) > max_str_chars:
            compacted[k] = v[:max_str_chars] + "\n... (truncated)"
        else:
            compacted[k] = v
    return compacted


def parse_transcript_line(line_str: str) -> TranscriptStep | None:
    """Parse and sanitize a single JSONL transcript line into TranscriptStep."""
    if not line_str or not line_str.strip():
        return None
    try:
        data = json.loads(line_str)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None

    step_type = str(data.get("type", ""))
    if step_type in IGNORED_MSG_TYPES:
        return None

    source = str(data.get("source", ""))
    status = str(data.get("status", ""))
    thinking = str(data.get("thinking", "") or "")
    raw_content = str(data.get("content", "") or "")
    clean_content = clean_display_content(raw_content)
    timestamp = str(data.get("created_at", "") or "")
    step_index = int(data.get("step_index", 0) or 0)
    raw_tool_calls = data.get("tool_calls", [])

    tool_calls: list[ToolCallItem] = []
    if isinstance(raw_tool_calls, list):
        for tc in raw_tool_calls:
            if not isinstance(tc, dict):
                continue
            fn = tc.get("function")
            if isinstance(fn, dict):
                name = str(fn.get("name", "tool"))
                args = _compact_chat_tool_args(_normalize_tool_args(fn.get("arguments")))
            else:
                name = str(tc.get("name", "tool"))
                args = _compact_chat_tool_args(_normalize_tool_args(tc.get("args", tc.get("arguments"))))
            tool_calls.append(ToolCallItem(name=name, args=args))

    if not clean_content and not thinking and not tool_calls and step_type != "USER_INPUT":
        return None

    return TranscriptStep(
        step_index=step_index,
        source=source,
        msg_type=step_type,
        status=status,
        content=clean_content,
        thinking=thinking,
        tool_calls=tool_calls,
        timestamp=timestamp,
    )
