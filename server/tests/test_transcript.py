"""Tests for transcript parsing, tag cleaning, tool_calls normalization, and workspace URI parsing."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from agy_hub.common.transcript import (
    clean_display_content,
    parse_project_name_and_path,
    parse_transcript_line,
    read_conversation_db_error_steps,
)


def test_clean_display_content_extracts_user_request_and_filters_noise() -> None:
    raw = """
<USER_REQUEST>
实现快速排序
</USER_REQUEST>
<ADDITIONAL_METADATA>Time: 2026-11-23</ADDITIONAL_METADATA>
<SYSTEM_MESSAGE>Internal prompt</SYSTEM_MESSAGE>
"""
    assert clean_display_content(raw) == "实现快速排序"

    noise = "Created At: 2026-11-23T01:00:00Z\nCommand output:\nok"
    assert clean_display_content(noise) == ""


def test_parse_transcript_line_normalizes_tool_calls_to_args() -> None:
    ignored = json.dumps({"type": "SYSTEM_MESSAGE", "content": "hidden"})
    assert parse_transcript_line(ignored) is None

    step_json = json.dumps(
        {
            "step_index": 5,
            "source": "MODEL",
            "type": "PLANNER_RESPONSE",
            "status": "DONE",
            "content": "完成修改",
            "thinking": "分析中",
            "model": "gemini-4-neon-high",
            "created_at": "2026-11-23T01:00:00Z",
            "tool_calls": [
                {"function": {"name": "edit_file", "arguments": '{"Path": "a.py"}'}},
                {"function": {"name": "run_command", "arguments": {"toolSummary": "Run tests"}}},
            ],
        }
    )
    parsed = parse_transcript_line(step_json)
    assert parsed is not None
    assert parsed.step_index == 5
    assert parsed.model == "gemini-4-neon-high"
    assert parsed.tool_calls[0].name == "edit_file"
    assert parsed.tool_calls[0].args == {"Path": "a.py"}
    assert parsed.tool_calls[1].args == {"toolSummary": "Run tests"}


def test_parse_project_name_and_path_handles_drive_roots_and_posix() -> None:
    name_z, path_z = parse_project_name_and_path(json.dumps(["file:///Z:/"]))
    assert name_z == "Z:"
    assert path_z == "Z:\\"

    name_win, path_win = parse_project_name_and_path(json.dumps(["file:///C:/Users/dev/my_app"]))
    assert name_win == "my_app"
    assert path_win == r"C:\Users\dev\my_app"

    name_posix, path_posix = parse_project_name_and_path(json.dumps(["file:///home/deck/scripts"]))
    assert name_posix == "scripts"
    assert path_posix == "/home/deck/scripts"


def _encode_varint(val: int) -> bytes:
    out = bytearray()
    while True:
        b = val & 0x7F
        val >>= 7
        if val:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def _pb_field_varint(field_num: int, val: int) -> bytes:
    return _encode_varint((field_num << 3) | 0) + _encode_varint(val)


def _pb_field_bytes(field_num: int, data: bytes) -> bytes:
    return _encode_varint((field_num << 3) | 2) + _encode_varint(len(data)) + data


def test_parse_transcript_line_extracts_error_message_field() -> None:
    raw_line = json.dumps(
        {
            "step_index": 172,
            "source": "SYSTEM",
            "type": "ERROR_MESSAGE",
            "status": "DONE",
            "error": "API error (attempt 1): UNAVAILABLE (code 503): No capacity available",
            "created_at": "2026-11-24T14:35:51Z",
        },
        ensure_ascii=False,
    )
    parsed = parse_transcript_line(raw_line)
    assert parsed is not None
    assert parsed.step_index == 172
    assert parsed.msg_type == "ERROR_MESSAGE"
    assert parsed.status == "ERROR"
    assert "UNAVAILABLE (code 503)" in parsed.content


def test_read_conversation_db_error_steps_parses_quota_429_protobuf(tmp_path: Path) -> None:
    user_msg = "Third-party quota reached. Please switch to Gemini models or upgrade your subscription to increase your limits. Resets in 50m3s."
    detail_msg = f"RESOURCE_EXHAUSTED (code 429): {user_msg}"
    err_info = json.dumps(
        {
            "@type": "type.googleapis.com/google.rpc.ErrorInfo",
            "reason": "QUOTA_EXHAUSTED",
            "metadata": {"model": "claude-sonnet-5-5-medium", "quotaResetDelay": "50m3.9s"},
        }
    )

    msg_5_1 = _pb_field_varint(1, 1795573489)
    msg_5 = _pb_field_bytes(1, msg_5_1)
    msg_24_3 = (
        _pb_field_bytes(1, user_msg.encode("utf-8"))
        + _pb_field_bytes(2, detail_msg.encode("utf-8"))
        + _pb_field_bytes(10, err_info.encode("utf-8"))
    )
    msg_24 = _pb_field_bytes(3, msg_24_3)
    payload = _pb_field_varint(1, 17) + _pb_field_bytes(5, msg_5) + _pb_field_bytes(24, msg_24)

    db_path = tmp_path / "conv.db"
    conn = sqlite3.connect(db_path)
    conn.execute("CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, step_payload BLOB)")
    conn.execute("INSERT INTO steps (idx, step_type, step_payload) VALUES (67, 132, ?)", (b"",))
    conn.execute("INSERT INTO steps (idx, step_type, step_payload) VALUES (68, 17, ?)", (payload,))
    conn.commit()
    conn.close()

    steps = read_conversation_db_error_steps(db_path)
    assert len(steps) == 1
    step = steps[0]
    assert step.step_index == 68
    assert step.msg_type == "ERROR_MESSAGE"
    assert step.status == "ERROR"
    assert "RESOURCE_EXHAUSTED (code 429)" in step.content
    assert "Resets in 50m3s." in step.content
    assert "claude-sonnet-5-5-medium" in step.content
    assert step.timestamp.endswith("Z") and "T" in step.timestamp

    # Verify min_step_index filter
    assert read_conversation_db_error_steps(db_path, min_step_index=68) == []
