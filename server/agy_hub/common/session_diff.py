"""Session-level file modification extractor with unified diff and CJK-friendly inline diff."""

from __future__ import annotations

import difflib
import json
import os
import re
from pathlib import Path
from typing import Any, Literal

from agy_hub.common.sandbox import is_sensitive_path
from agy_hub.common.schemas import (
    InlineDiffSegment,
    SessionChangesResponse,
    SessionEditHunk,
    SessionFileChangeSummary,
)

_EDIT_TOOLS = {"edit_file", "write_file", "replace_file_content", "multi_replace_file_content"}
_TOKEN_RE = re.compile(r"[A-Za-z0-9_]+|[^\S\n]+|\n|.")
_MAX_INLINE_CHARS = 12000
_MAX_UNIFIED_CHARS = 24000


def _unwrap_str(value: Any) -> str:
    if value is None:
        return ""
    if not isinstance(value, str):
        return str(value)
    # Compact transcript.jsonl sometimes serializes long arg strings as JSON-quoted literals.
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            decoded = json.loads(value)
            if isinstance(decoded, str):
                return decoded
        except Exception:
            pass
    return value


def _normalize_display_path(raw_path: str) -> str:
    cleaned = raw_path.strip().replace("\\", "/")
    if len(cleaned) >= 2 and cleaned[1] == ":":
        cleaned = cleaned[0].upper() + cleaned[1:]
    return cleaned


def _split_name_dir(display_path: str) -> tuple[str, str]:
    norm = display_path.rstrip("/")
    if "/" not in norm:
        return norm, ""
    directory, name = norm.rsplit("/", 1)
    return name or norm, directory


def _count_line_delta(before_text: str, after_text: str) -> tuple[int, int]:
    before_lines = before_text.splitlines() if before_text else []
    after_lines = after_text.splitlines() if after_text else []
    matcher = difflib.SequenceMatcher(None, before_lines, after_lines)
    added = 0
    removed = 0
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "replace":
            removed += i2 - i1
            added += j2 - j1
        elif tag == "delete":
            removed += i2 - i1
        elif tag == "insert":
            added += j2 - j1
    return added, removed


def _compute_inline_segments(before_text: str, after_text: str) -> list[InlineDiffSegment]:
    if not before_text and not after_text:
        return []
    if not before_text:
        snippet = after_text[:_MAX_INLINE_CHARS]
        if len(after_text) > _MAX_INLINE_CHARS:
            snippet += "\n... (内容较长已截断预览)"
        return [InlineDiffSegment(kind="insert", text=snippet)]
    if not after_text:
        snippet = before_text[:_MAX_INLINE_CHARS]
        if len(before_text) > _MAX_INLINE_CHARS:
            snippet += "\n... (内容较长已截断预览)"
        return [InlineDiffSegment(kind="delete", text=snippet)]

    if len(before_text) + len(after_text) > _MAX_INLINE_CHARS:
        b_clip = before_text[: _MAX_INLINE_CHARS // 2] + ("\n... (已截断)" if len(before_text) > _MAX_INLINE_CHARS // 2 else "")
        a_clip = after_text[: _MAX_INLINE_CHARS // 2] + ("\n... (已截断)" if len(after_text) > _MAX_INLINE_CHARS // 2 else "")
        return [
            InlineDiffSegment(kind="delete", text=b_clip),
            InlineDiffSegment(kind="insert", text=a_clip),
        ]

    b_tokens = _TOKEN_RE.findall(before_text.replace("\r\n", "\n"))
    a_tokens = _TOKEN_RE.findall(after_text.replace("\r\n", "\n"))
    matcher = difflib.SequenceMatcher(None, b_tokens, a_tokens, autojunk=False)
    merged: list[InlineDiffSegment] = []

    def _push(kind: str, txt: str) -> None:
        if not txt:
            return
        if merged and merged[-1].kind == kind:
            merged[-1] = InlineDiffSegment(kind=kind, text=merged[-1].text + txt)
        else:
            merged.append(InlineDiffSegment(kind=kind, text=txt))  # type: ignore[arg-type]

    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            _push("equal", "".join(b_tokens[i1:i2]))
        elif tag == "delete":
            _push("delete", "".join(b_tokens[i1:i2]))
        elif tag == "insert":
            _push("insert", "".join(a_tokens[j1:j2]))
        elif tag == "replace":
            _push("delete", "".join(b_tokens[i1:i2]))
            _push("insert", "".join(a_tokens[j1:j2]))

    return merged


def _build_unified_diff(file_name: str, before_text: str, after_text: str) -> str:
    if len(before_text) + len(after_text) > _MAX_UNIFIED_CHARS:
        b_lines = (before_text[: _MAX_UNIFIED_CHARS // 2]).splitlines()
        a_lines = (after_text[: _MAX_UNIFIED_CHARS // 2]).splitlines()
        diff_lines = list(
            difflib.unified_diff(
                b_lines,
                a_lines,
                fromfile=f"a/{file_name}",
                tofile=f"b/{file_name}",
                n=2,
                lineterm="",
            )
        )
        diff_lines.append("... (差异内容过长，已截断显示)")
        return "\n".join(diff_lines)

    b_lines = before_text.replace("\r\n", "\n").splitlines() if before_text else []
    a_lines = after_text.replace("\r\n", "\n").splitlines() if after_text else []
    return "\n".join(
        difflib.unified_diff(
            b_lines,
            a_lines,
            fromfile=f"a/{file_name}",
            tofile=f"b/{file_name}",
            n=2,
            lineterm="",
        )
    )


def _locate_line_range(disk_text_cache: dict[str, str | None], raw_path: str, needle: str) -> tuple[int | None, int | None]:
    if not needle:
        return None, None
    key = os.path.normcase(raw_path)
    if key not in disk_text_cache:
        loaded: str | None = None
        try:
            p = Path(raw_path)
            if p.is_file() and p.stat().st_size <= 2 * 1024 * 1024:
                loaded = p.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
        except OSError:
            loaded = None
        disk_text_cache[key] = loaded

    full_text = disk_text_cache[key]
    if not full_text:
        return None, None

    clean_needle = needle.replace("\r\n", "\n")
    idx = full_text.find(clean_needle)
    if idx < 0:
        first_line = clean_needle.split("\n", 1)[0].strip()
        if len(first_line) >= 8:
            idx = full_text.find(first_line)
    if idx < 0:
        return None, None

    start_line = full_text.count("\n", 0, idx) + 1
    line_span = max(0, clean_needle.rstrip("\n").count("\n"))
    return start_line, start_line + line_span


def _extract_tool_args(tc: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    fn = tc.get("function")
    if isinstance(fn, dict):
        name = str(fn.get("name", ""))
        raw_args = fn.get("arguments")
    else:
        name = str(tc.get("name", ""))
        raw_args = tc.get("args", tc.get("arguments"))

    if isinstance(raw_args, str):
        try:
            parsed = json.loads(raw_args)
            args = parsed if isinstance(parsed, dict) else {}
        except Exception:
            args = {}
    elif isinstance(raw_args, dict):
        args = raw_args
    else:
        args = {}
    return name, args


def extract_session_changes(
    brain_dir: Path,
    session_id: str,
    include_hunks: bool = False,
    file_path_filter: str | None = None,
    scope: Literal["all", "latest_turn"] = "all",
    step_index_filter: int | None = None,
) -> SessionChangesResponse:
    """Parse transcript_full.jsonl (fallback transcript.jsonl) into per-file diff summaries."""
    logs_dir = brain_dir / session_id / ".system_generated" / "logs"
    full_path = logs_dir / "transcript_full.jsonl"
    compact_path = logs_dir / "transcript.jsonl"
    log_path = full_path if full_path.exists() else compact_path
    if not log_path.exists():
        return SessionChangesResponse(session_id=session_id)

    norm_filter = os.path.normcase(_normalize_display_path(file_path_filter)) if file_path_filter else None

    file_records: dict[str, dict[str, Any]] = {}
    tracked_contents: dict[str, str] = {}
    disk_text_cache: dict[str, str | None] = {}
    raw_edits: list[dict[str, Any]] = []

    def _queue_edit(
        turn_id: int,
        raw_file_path: str,
        tool_name: str,
        step_index: int,
        timestamp: str,
        before_text: str,
        after_text: str,
        *,
        is_new: bool = False,
        explicit_start: int | None = None,
        explicit_end: int | None = None,
    ) -> None:
        display_path = _normalize_display_path(raw_file_path)
        if not display_path or is_sensitive_path(Path(display_path)):
            return
        raw_edits.append(
            {
                "turn_id": turn_id,
                "raw_file_path": raw_file_path,
                "tool_name": tool_name,
                "step_index": step_index,
                "timestamp": timestamp,
                "before_text": before_text,
                "after_text": after_text,
                "is_new": is_new,
                "explicit_start": explicit_start,
                "explicit_end": explicit_end,
            }
        )

    def _record_edit(
        raw_file_path: str,
        tool_name: str,
        step_index: int,
        timestamp: str,
        before_text: str,
        after_text: str,
        *,
        is_new: bool = False,
        explicit_start: int | None = None,
        explicit_end: int | None = None,
    ) -> None:
        display_path = _normalize_display_path(raw_file_path)
        if not display_path or is_sensitive_path(Path(display_path)):
            return
        norm_key = os.path.normcase(display_path)
        if norm_filter and norm_key != norm_filter:
            return

        added, removed = _count_line_delta(before_text, after_text)
        rec = file_records.get(norm_key)
        if rec is None:
            file_name, directory = _split_name_dir(display_path)
            rec = {
                "file_path": display_path,
                "file_name": file_name,
                "directory": directory,
                "added_lines": 0,
                "removed_lines": 0,
                "edit_count": 0,
                "last_step_index": step_index,
                "is_new_file": is_new,
                "hunks": [],
            }
            file_records[norm_key] = rec

        rec["added_lines"] += added
        rec["removed_lines"] += removed
        rec["edit_count"] += 1
        rec["last_step_index"] = max(rec["last_step_index"], step_index)

        if include_hunks:
            hunk_idx = len(rec["hunks"]) + 1
            s_line, e_line = (explicit_start, explicit_end)
            if s_line is None:
                s_line, e_line = _locate_line_range(disk_text_cache, raw_file_path, after_text or before_text)
            rec["hunks"].append(
                SessionEditHunk(
                    hunk_id=f"s{step_index}_h{hunk_idx}",
                    step_index=step_index,
                    tool_name=tool_name,
                    timestamp=timestamp,
                    start_line=s_line,
                    end_line=e_line,
                    added_lines=added,
                    removed_lines=removed,
                    before_text=before_text,
                    after_text=after_text,
                    unified_diff=_build_unified_diff(rec["file_name"], before_text, after_text),
                    inline_segments=_compute_inline_segments(before_text, after_text),
                )
            )

    current_turn_id = 0
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    step_obj = json.loads(line)
                except Exception:
                    continue
                if not isinstance(step_obj, dict):
                    continue

                step_index = int(step_obj.get("step_index", 0) or 0)
                if step_obj.get("source") == "USER_EXPLICIT" or step_obj.get("type") in ("USER_INPUT", "USER_EXPLICIT"):
                    current_turn_id = step_index if step_index > 0 else (current_turn_id + 1)

                tool_calls = step_obj.get("tool_calls")
                if not isinstance(tool_calls, list) or not tool_calls:
                    continue

                timestamp = str(step_obj.get("created_at", "") or "")

                for tc in tool_calls:
                    if not isinstance(tc, dict):
                        continue
                    tool_name, args = _extract_tool_args(tc)
                    if tool_name not in _EDIT_TOOLS:
                        continue

                    if tool_name == "edit_file":
                        raw_p = _unwrap_str(args.get("Path") or args.get("path"))
                        before = _unwrap_str(args.get("Target") or args.get("target")).replace("\r\n", "\n")
                        after = _unwrap_str(args.get("Replacement") or args.get("replacement")).replace("\r\n", "\n")
                        if not raw_p:
                            continue
                        norm_k = os.path.normcase(_normalize_display_path(raw_p))
                        if norm_k in tracked_contents and before and before in tracked_contents[norm_k]:
                            tracked_contents[norm_k] = tracked_contents[norm_k].replace(before, after, 1)
                        _queue_edit(current_turn_id, raw_p, tool_name, step_index, timestamp, before, after)

                    elif tool_name == "write_file":
                        raw_p = _unwrap_str(args.get("Path") or args.get("path"))
                        content = _unwrap_str(args.get("Content") or args.get("content")).replace("\r\n", "\n")
                        is_append = bool(args.get("Append") if "Append" in args else args.get("append", False))
                        if not raw_p:
                            continue
                        norm_k = os.path.normcase(_normalize_display_path(raw_p))
                        prev = tracked_contents.get(norm_k)
                        if is_append:
                            before = ""
                            tracked_contents[norm_k] = (prev or "") + content
                            _queue_edit(
                                current_turn_id,
                                raw_p,
                                tool_name,
                                step_index,
                                timestamp,
                                before,
                                content,
                                is_new=prev is None,
                            )
                        else:
                            before = prev if prev is not None else ""
                            tracked_contents[norm_k] = content
                            _queue_edit(
                                current_turn_id,
                                raw_p,
                                tool_name,
                                step_index,
                                timestamp,
                                before,
                                content,
                                is_new=prev is None,
                            )

                    elif tool_name == "replace_file_content":
                        raw_p = _unwrap_str(args.get("TargetFile") or args.get("target_file"))
                        before = _unwrap_str(args.get("TargetContent") or args.get("target_content")).replace("\r\n", "\n")
                        after = _unwrap_str(args.get("ReplacementContent") or args.get("replacement_content")).replace("\r\n", "\n")
                        s_line = args.get("StartLine") or args.get("start_line")
                        e_line = args.get("EndLine") or args.get("end_line")
                        if not raw_p:
                            continue
                        _queue_edit(
                            current_turn_id,
                            raw_p,
                            tool_name,
                            step_index,
                            timestamp,
                            before,
                            after,
                            explicit_start=int(s_line) if isinstance(s_line, int) else None,
                            explicit_end=int(e_line) if isinstance(e_line, int) else None,
                        )

                    elif tool_name == "multi_replace_file_content":
                        raw_p = _unwrap_str(args.get("TargetFile") or args.get("target_file"))
                        chunks = args.get("ReplacementChunks") or args.get("replacement_chunks")
                        if not raw_p or not isinstance(chunks, list):
                            continue
                        for chunk in chunks:
                            if not isinstance(chunk, dict):
                                continue
                            before = _unwrap_str(chunk.get("TargetContent") or chunk.get("target_content")).replace("\r\n", "\n")
                            after = _unwrap_str(chunk.get("ReplacementContent") or chunk.get("replacement_content")).replace("\r\n", "\n")
                            s_line = chunk.get("StartLine") or chunk.get("start_line")
                            e_line = chunk.get("EndLine") or chunk.get("end_line")
                            _queue_edit(
                                current_turn_id,
                                raw_p,
                                tool_name,
                                step_index,
                                timestamp,
                                before,
                                after,
                                explicit_start=int(s_line) if isinstance(s_line, int) else None,
                                explicit_end=int(e_line) if isinstance(e_line, int) else None,
                            )
    except OSError:
        return SessionChangesResponse(session_id=session_id)

    if not raw_edits:
        return SessionChangesResponse(session_id=session_id)

    if step_index_filter is not None:
        selected_edits = [e for e in raw_edits if e["step_index"] == step_index_filter]
    elif scope == "latest_turn":
        latest_turn_id = raw_edits[-1]["turn_id"]
        selected_edits = [e for e in raw_edits if e["turn_id"] == latest_turn_id]
    else:
        selected_edits = raw_edits

    for e in selected_edits:
        _record_edit(
            e["raw_file_path"],
            e["tool_name"],
            e["step_index"],
            e["timestamp"],
            e["before_text"],
            e["after_text"],
            is_new=e["is_new"],
            explicit_start=e["explicit_start"],
            explicit_end=e["explicit_end"],
        )

    sorted_recs = sorted(file_records.values(), key=lambda r: (-r["last_step_index"], r["file_name"].lower()))
    summaries = [SessionFileChangeSummary(**rec) for rec in sorted_recs]
    return SessionChangesResponse(
        session_id=session_id,
        total_files=len(summaries),
        total_added=sum(f.added_lines for f in summaries),
        total_removed=sum(f.removed_lines for f in summaries),
        files=summaries,
    )
