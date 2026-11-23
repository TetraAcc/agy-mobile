"""Tests for transcript parsing, tag cleaning, tool_calls normalization, and workspace URI parsing."""

from __future__ import annotations

import json

from agy_hub.common.transcript import (
    clean_display_content,
    parse_project_name_and_path,
    parse_transcript_line,
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
