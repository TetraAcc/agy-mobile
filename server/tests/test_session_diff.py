"""Tests for session-level edit diff extraction, CJK inline diffing, and git repo discovery."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.common.security import sign_internal_request
from agy_hub.common.session_diff import extract_session_changes
from tests.conftest import TEST_INTERNAL_SECRET


def _signed_headers(method: str, path: str) -> dict[str, str]:
    perms = json.dumps({"can_write": True, "can_delete": True}, separators=(",", ":"), sort_keys=True)
    return sign_internal_request(TEST_INTERNAL_SECRET, method, path, "tester", perms)


def test_session_diff_extracts_cjk_inline_line_range_and_filters_sensitive(tmp_path: Path) -> None:
    brain_dir = tmp_path / "brain"
    sid = "11111111-1111-4111-8111-111111111111"
    logs_dir = brain_dir / sid / ".system_generated" / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    novel_file = tmp_path / "novel" / "chapter_01.md"
    novel_file.parent.mkdir(parents=True, exist_ok=True)
    novel_file.write_text(
        "# 第一章\n\n夜色沉沉。\n窗外狂风大作，他猛地合上了泛黄的笔记本。\n故事才刚刚开始。\n",
        encoding="utf-8",
    )

    secret_file = tmp_path / ".env"

    # Write a truncated compact log that should be superseded by transcript_full.jsonl
    (logs_dir / "transcript.jsonl").write_text(
        json.dumps({"step_index": 1, "tool_calls": []}, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    full_steps = [
        {
            "step_index": 2,
            "created_at": "2026-11-23T08:00:00Z",
            "tool_calls": [
                {
                    "name": "edit_file",
                    "args": {
                        "Path": str(novel_file),
                        "Target": "窗外下着细雨，他缓缓合上了笔记本。",
                        "Replacement": "窗外狂风大作，他猛地合上了泛黄的笔记本。",
                    },
                },
                {
                    "name": "edit_file",
                    "args": {
                        "Path": str(secret_file),
                        "Target": "OLD=1",
                        "Replacement": "SECRET_KEY=leaked",
                    },
                },
            ],
        },
        {
            "step_index": 4,
            "created_at": "2026-11-23T08:02:00Z",
            "tool_calls": [
                {
                    "name": "write_file",
                    "args": {
                        "Path": str(tmp_path / "novel" / "outline.md"),
                        "Content": "第一幕\n第二幕\n",
                        "Overwrite": True,
                    },
                },
                {
                    "name": "replace_file_content",
                    "args": {
                        "TargetFile": str(tmp_path / "novel" / "outline.md"),
                        "TargetContent": "第二幕",
                        "ReplacementContent": "第二幕：重逢",
                        "StartLine": 2,
                        "EndLine": 2,
                    },
                },
            ],
        },
    ]
    (logs_dir / "transcript_full.jsonl").write_text(
        "\n".join(json.dumps(s, ensure_ascii=False) for s in full_steps) + "\n",
        encoding="utf-8",
    )

    summary = extract_session_changes(brain_dir, sid, include_hunks=False)
    assert summary.total_files == 2
    assert summary.total_added >= 3
    assert summary.total_removed >= 1
    assert all(not f.file_path.endswith(".env") for f in summary.files)
    assert summary.files[0].file_name == "outline.md"  # Most recently edited first (step 4)
    assert summary.files[1].file_name == "chapter_01.md"
    assert summary.files[0].hunks == []

    detail = extract_session_changes(brain_dir, sid, include_hunks=True, file_path_filter=str(novel_file))
    assert detail.total_files == 1
    ch = detail.files[0]
    assert len(ch.hunks) == 1
    hunk = ch.hunks[0]
    assert hunk.start_line == 4
    assert hunk.end_line == 4
    assert "下着细雨" in "".join(seg.text for seg in hunk.inline_segments if seg.kind == "delete")
    assert "狂风大作" in "".join(seg.text for seg in hunk.inline_segments if seg.kind == "insert")
    assert "笔记本" in "".join(seg.text for seg in hunk.inline_segments if seg.kind == "equal")


def test_agent_changes_and_git_repos_and_head_diff_endpoints(tmp_agent_env: dict) -> None:
    brain_dir: Path = tmp_agent_env["brain_dir"]
    proj_dir: Path = tmp_agent_env["proj_dir"]
    sid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"

    note_file = proj_dir / "notes.md"
    note_file.write_text("第一行\n修改后的第二行\n", encoding="utf-8")

    # Prepare git repo with 1 commit and 1 uncommitted modification
    subprocess.run(["git", "init"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "add", "notes.md"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "initial novel draft"], cwd=proj_dir, check=True, capture_output=True)
    note_file.write_text("第一行\n修改后的第二行\n新增第三行\n", encoding="utf-8")

    logs_dir = brain_dir / sid / ".system_generated" / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    (logs_dir / "transcript_full.jsonl").write_text(
        json.dumps(
            {
                "step_index": 5,
                "created_at": "2026-11-23T08:05:00Z",
                "tool_calls": [
                    {
                        "name": "edit_file",
                        "args": {
                            "Path": str(note_file),
                            "Target": "第一行\n修改后的第二行",
                            "Replacement": "第一行\n修改后的第二行\n新增第三行",
                        },
                    }
                ],
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    with TestClient(app) as client:
        # 1. Session changes endpoint
        ch_path = f"/agent/sessions/{sid}/changes"
        ch_resp = client.get(f"{ch_path}?include_hunks=true", headers=_signed_headers("GET", ch_path))
        assert ch_resp.status_code == 200
        ch_data = ch_resp.json()
        assert ch_data["total_files"] == 1
        assert ch_data["total_added"] == 1
        assert ch_data["files"][0]["hunks"][0]["start_line"] == 1

        # 2. Git repo discovery automatically finds demo_project inside scratch
        repos_resp = client.get("/agent/git/repos", headers=_signed_headers("GET", "/agent/git/repos"))
        assert repos_resp.status_code == 200
        repos = repos_resp.json()["repos"]
        demo_repo = next((r for r in repos if r["name"] == "demo_project"), None)
        assert demo_repo is not None
        assert demo_repo["root_id"] == "scratch"
        assert demo_repo["sub_path"] == "demo_project"
        assert demo_repo["change_count"] == 1

        # 3. Git diff supports sub_path and scope=head
        diff_uncommitted = client.get(
            "/agent/git/diff?root_id=scratch&sub_path=demo_project&scope=uncommitted",
            headers=_signed_headers("GET", "/agent/git/diff"),
        )
        assert diff_uncommitted.status_code == 200
        assert "+新增第三行" in diff_uncommitted.json()["diff"]

        diff_head = client.get(
            "/agent/git/diff?root_id=scratch&sub_path=demo_project&scope=head",
            headers=_signed_headers("GET", "/agent/git/diff"),
        )
        assert diff_head.status_code == 200
        assert "initial novel draft" in diff_head.json()["diff"]
