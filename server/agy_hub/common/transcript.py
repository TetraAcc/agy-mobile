"""Transcript parsing, prompt sanitization, and Antigravity workspace URI resolution."""

from __future__ import annotations

import json
import os
import re
import sqlite3
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
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


def _extract_error_text(raw_error: Any) -> str:
    if isinstance(raw_error, str):
        return raw_error.strip()
    if isinstance(raw_error, dict):
        msg = raw_error.get("message") or raw_error.get("detail")
        if msg:
            return str(msg).strip()
        return json.dumps(raw_error, ensure_ascii=False).strip()
    return ""


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
    error_text = _extract_error_text(data.get("error"))
    if error_text and not clean_content:
        clean_content = error_text
    if step_type == "ERROR_MESSAGE" or error_text:
        status = "ERROR"

    timestamp = str(data.get("created_at", "") or "")
    model = str(data.get("model", "") or "").strip()
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
        model=model,
    )


_PB_CONTAINER_PATHS: set[str] = {
    "r.5",
    "r.5.1",
    "r.5.26",
    "r.5.26.1",
    "r.24",
    "r.24.3",
}
_UUID_LIKE_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F-]{12,}(?:-\d+)?$")


def _read_pb_varint(buf: bytes, idx: int) -> tuple[int, int] | None:
    val = 0
    shift = 0
    n = len(buf)
    while idx < n:
        b = buf[idx]
        idx += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            return val, idx
        shift += 7
        if shift > 63:
            return None
    return None


def _decode_pb_entries(buf: bytes, prefix: str = "", depth: int = 0) -> list[tuple[str, Any]] | None:
    """Decode raw protobuf wire bytes into flattened (path, value) entries using stdlib only."""
    if depth > 8:
        return None
    out: list[tuple[str, Any]] = []
    i = 0
    n = len(buf)
    while i < n:
        tag_res = _read_pb_varint(buf, i)
        if tag_res is None:
            return None
        tag, i = tag_res
        field_num = tag >> 3
        wire_type = tag & 7
        if field_num == 0:
            return None

        if wire_type == 0:
            val_res = _read_pb_varint(buf, i)
            if val_res is None:
                return None
            val, i = val_res
            out.append((f"{prefix}.{field_num}(v)", val))
        elif wire_type == 1:
            if i + 8 > n:
                return None
            i += 8
        elif wire_type == 2:
            len_res = _read_pb_varint(buf, i)
            if len_res is None:
                return None
            ln, i = len_res
            if i + ln > n:
                return None
            chunk = buf[i : i + ln]
            i += ln

            field_path = f"{prefix}.{field_num}"
            if field_path in _PB_CONTAINER_PATHS:
                nested = _decode_pb_entries(chunk, field_path, depth + 1)
                if nested:
                    out.extend(nested)
                    continue

            is_text = False
            txt = ""
            try:
                txt = chunk.decode("utf-8")
                if txt and all(ch.isprintable() or ch in "\r\n\t" for ch in txt):
                    is_text = True
            except Exception:
                pass

            if is_text:
                out.append((f"{field_path}(s)", txt))
            else:
                nested = _decode_pb_entries(chunk, field_path, depth + 1)
                if nested:
                    out.extend(nested)
        elif wire_type == 5:
            if i + 4 > n:
                return None
            i += 4
        else:
            return None
    return out


def _is_usable_fallback_error_text(text: str) -> bool:
    stripped = text.strip()
    if len(stripped) < 8 or _UUID_LIKE_RE.match(stripped):
        return False
    if "\nHeaders:" in stripped or "Sherlog:" in stripped:
        return False
    if stripped.startswith("{") and stripped.endswith("}"):
        return False
    return True


def _parse_step_payload_error(payload: bytes) -> tuple[str, str]:
    """Extract user-visible error message and UTC ISO timestamp from step_type=17 protobuf payload."""
    if not payload:
        return "", ""
    entries = _decode_pb_entries(payload, "r") or []
    if not entries:
        return "", ""

    str_map: dict[str, list[str]] = {}
    var_map: dict[str, list[int]] = {}
    for key, val in entries:
        if key.endswith("(s)") and isinstance(val, str) and val.strip():
            str_map.setdefault(key, []).append(val.strip())
        elif key.endswith("(v)") and isinstance(val, int):
            var_map.setdefault(key, []).append(val)

    user_msg = (str_map.get("r.24.3.1(s)") or [""])[0]
    detail_msg = (str_map.get("r.24.3.2(s)") or str_map.get("r.24.3.9(s)") or [""])[0]

    model_name = ""
    for raw_info in str_map.get("r.24.3.10(s)", []):
        try:
            info_obj = json.loads(raw_info)
        except Exception:
            continue
        if isinstance(info_obj, dict):
            meta = info_obj.get("metadata")
            if isinstance(meta, dict) and isinstance(meta.get("model"), str) and meta["model"].strip():
                model_name = meta["model"].strip()
                break

    if detail_msg and (not user_msg or user_msg in detail_msg):
        content = detail_msg
    elif user_msg and detail_msg:
        content = f"{user_msg}\n{detail_msg}"
    else:
        content = user_msg or detail_msg

    if not content:
        for key, values in str_map.items():
            if not key.startswith("r.24."):
                continue
            for cand in values:
                if _is_usable_fallback_error_text(cand):
                    content = cand
                    break
            if content:
                break

    if content and model_name and model_name not in content:
        content = f"{content}\n模型: {model_name}"

    iso_ts = ""
    ts_candidates = var_map.get("r.5.1.1(v)", []) + var_map.get("r.5.26.1.2.1(v)", [])
    for ts_val in ts_candidates:
        if ts_val > 1_000_000_000:
            iso_ts = datetime.fromtimestamp(ts_val, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            break

    return content, iso_ts


def read_conversation_db_error_steps(
    conv_db_path: Path,
    *,
    min_step_index: int | None = None,
) -> list[TranscriptStep]:
    """Read step_type=17 error steps from Antigravity per-conversation SQLite DB (read-only)."""
    if not conv_db_path.exists() or not conv_db_path.is_file():
        return []

    steps: list[TranscriptStep] = []
    conn: sqlite3.Connection | None = None
    try:
        uri = f"{conv_db_path.resolve().as_uri()}?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=1.5)
        conn.execute("PRAGMA busy_timeout=1500;")
        if min_step_index is not None:
            rows = conn.execute(
                "SELECT idx, step_payload FROM steps WHERE step_type = 17 AND idx > ? ORDER BY idx ASC",
                (min_step_index,),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT idx, step_payload FROM steps WHERE step_type = 17 ORDER BY idx ASC"
            ).fetchall()

        for idx, payload in rows:
            if not isinstance(payload, (bytes, bytearray)):
                continue
            content, iso_ts = _parse_step_payload_error(bytes(payload))
            if not content:
                continue
            steps.append(
                TranscriptStep(
                    step_index=int(idx),
                    source="SYSTEM",
                    msg_type="ERROR_MESSAGE",
                    status="ERROR",
                    content=content,
                    thinking="",
                    tool_calls=[],
                    timestamp=iso_ts,
                )
            )
    except (sqlite3.Error, OSError):
        return steps
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
    return steps
