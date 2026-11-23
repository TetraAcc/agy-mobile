"""Session inspection helpers for tool call outputs and session-scoped artifacts."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from agy_hub.common.sandbox import is_sensitive_path
from agy_hub.common.schemas import (
    SessionArtifactItem,
    SessionArtifactsResponse,
    ToolCallItem,
    ToolCallOutputResponse,
)
from agy_hub.common.session_diff import _unwrap_str
from agy_hub.common.transcript import _normalize_tool_args

_ARTIFACT_IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg"}
_ARTIFACT_MD_EXTS = {".md", ".markdown"}
_PATH_ARG_KEYS = {"path", "targetfile", "target_file", "scriptpath", "cwd"}
_MAX_ARG_STR_CHARS = 8000


def _sanitize_tool_args(raw_args: Any) -> dict[str, Any]:
    normalized = _normalize_tool_args(raw_args)
    sanitized: dict[str, Any] = {}
    for key, val in normalized.items():
        if isinstance(val, str):
            unwrapped = _unwrap_str(val)
            if key.lower() in _PATH_ARG_KEYS and unwrapped:
                try:
                    if is_sensitive_path(Path(unwrapped)):
                        sanitized[key] = "[redacted]"
                        continue
                except Exception:
                    pass
            if len(unwrapped) > _MAX_ARG_STR_CHARS:
                sanitized[key] = unwrapped[:_MAX_ARG_STR_CHARS] + "\n... (truncated)"
            else:
                sanitized[key] = unwrapped
        else:
            sanitized[key] = val
    return sanitized


def _parse_tool_calls_list(raw_tool_calls: Any) -> list[ToolCallItem]:
    items: list[ToolCallItem] = []
    if not isinstance(raw_tool_calls, list):
        return items
    for tc in raw_tool_calls:
        if not isinstance(tc, dict):
            continue
        fn = tc.get("function")
        if isinstance(fn, dict):
            name = str(fn.get("name", "tool"))
            args = _sanitize_tool_args(fn.get("arguments"))
        else:
            name = str(tc.get("name") or tc.get("tool_name") or "tool")
            args = _sanitize_tool_args(tc.get("args", tc.get("arguments")))
        items.append(ToolCallItem(name=name, args=args))
    return items


def _read_transcript_dicts(brain_dir: Path, session_id: str) -> list[dict[str, Any]]:
    logs_dir = brain_dir / session_id / ".system_generated" / "logs"
    full_path = logs_dir / "transcript_full.jsonl"
    compact_path = logs_dir / "transcript.jsonl"
    target = full_path if full_path.exists() else compact_path
    if not target.exists():
        return []

    records: list[dict[str, Any]] = []
    try:
        with open(target, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    parsed = json.loads(stripped)
                except Exception:
                    continue
                if isinstance(parsed, dict):
                    records.append(parsed)
    except OSError:
        return []
    return records


def get_step_tool_output(
    brain_dir: Path,
    session_id: str,
    step_index: int,
    max_chars: int = 65536,
) -> ToolCallOutputResponse:
    """Locate a transcript step and gather contiguous tool output messages following it."""
    records = _read_transcript_dicts(brain_dir, session_id)
    target_pos: int | None = None
    target_rec: dict[str, Any] | None = None
    for idx, rec in enumerate(records):
        try:
            rec_step = int(rec.get("step_index", -1))
        except (TypeError, ValueError):
            continue
        if rec_step == step_index:
            target_pos = idx
            target_rec = rec
            break

    if target_pos is None or target_rec is None:
        return ToolCallOutputResponse(
            session_id=session_id,
            step_index=step_index,
            status="NOT_FOUND",
        )

    tool_calls = _parse_tool_calls_list(target_rec.get("tool_calls"))
    output_parts: list[str] = []
    result_step_index: int | None = None
    result_status = str(target_rec.get("status", "") or "")

    for follower in records[target_pos + 1 :]:
        ftype = str(follower.get("type", "") or "")
        if ftype in ("PLANNER_RESPONSE", "USER_INPUT", "CHECKPOINT"):
            break
        if ftype not in ("GENERIC", "ERROR_MESSAGE"):
            continue

        if result_step_index is None:
            try:
                result_step_index = int(follower.get("step_index"))
            except (TypeError, ValueError):
                pass

        fstatus = str(follower.get("status", "") or "")
        if fstatus:
            result_status = fstatus

        text = str(follower.get("content", "") or "").strip()
        err_text = str(follower.get("error", "") or "").strip()
        if text:
            output_parts.append(text)
        elif err_text:
            output_parts.append(err_text)

    combined = "\n\n".join(output_parts)
    truncated = False
    if len(combined) > max_chars:
        combined = combined[:max_chars]
        truncated = True

    return ToolCallOutputResponse(
        session_id=session_id,
        step_index=step_index,
        tool_calls=tool_calls,
        result_step_index=result_step_index,
        status=result_status,
        output=combined,
        truncated=truncated,
    )


def list_session_artifacts(
    brain_dir: Path,
    session_id: str,
    limit: int = 100,
) -> SessionArtifactsResponse:
    """List non-hidden, non-sensitive artifact files inside a session brain folder."""
    session_dir = brain_dir / session_id
    if not session_dir.exists() or not session_dir.is_dir():
        return SessionArtifactsResponse(session_id=session_id, items=[])

    try:
        resolved_session_dir = session_dir.resolve()
        resolved_brain_dir = brain_dir.resolve()
    except OSError:
        return SessionArtifactsResponse(session_id=session_id, items=[])

    collected: list[SessionArtifactItem] = []
    for dirpath, dirnames, filenames in os.walk(session_dir, followlinks=False):
        current_path = Path(dirpath)
        try:
            rel_parts = current_path.relative_to(session_dir).parts
        except ValueError:
            dirnames[:] = []
            continue

        if len(rel_parts) >= 3:
            dirnames[:] = []
        else:
            filtered_dirs: list[str] = []
            for dname in dirnames:
                if dname.startswith(".") or dname == "browser_sandbox":
                    continue
                candidate_dir = current_path / dname
                if candidate_dir.is_symlink() or is_sensitive_path(candidate_dir):
                    continue
                filtered_dirs.append(dname)
            dirnames[:] = filtered_dirs

        for fname in filenames:
            if fname.startswith("."):
                continue
            fpath = current_path / fname
            if fpath.is_symlink():
                continue
            try:
                resolved_file = fpath.resolve()
                resolved_file.relative_to(resolved_session_dir)
                rel_brain = resolved_file.relative_to(resolved_brain_dir).as_posix()
            except (OSError, ValueError):
                continue

            if is_sensitive_path(resolved_file):
                continue

            try:
                stat = resolved_file.stat()
            except OSError:
                continue

            ext = resolved_file.suffix.lower()
            collected.append(
                SessionArtifactItem(
                    name=fname,
                    rel_path=rel_brain,
                    root_id="brain",
                    size=stat.st_size,
                    updated_at=stat.st_mtime,
                    is_image=ext in _ARTIFACT_IMAGE_EXTS,
                    is_markdown=ext in _ARTIFACT_MD_EXTS,
                )
            )

    collected.sort(key=lambda item: item.updated_at, reverse=True)
    return SessionArtifactsResponse(session_id=session_id, items=collected[:limit])
