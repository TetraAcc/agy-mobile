"""Tests for desktop-parity backend endpoints: file editing, tool output, artifacts, and CLI mode flags."""

from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.agent.config import AgentConfig
from agy_hub.agent.providers.deck import DeckEngineProvider
from agy_hub.common.sandbox import RootRegistry
from agy_hub.common.security import sign_internal_request
from agy_hub.common.session_inspect import get_step_tool_output
from tests.conftest import TEST_INTERNAL_SECRET


def _signed_headers(method: str, path: str, *, can_write: bool = True) -> dict[str, str]:
    perms = json.dumps({"can_write": can_write, "can_delete": can_write}, separators=(",", ":"), sort_keys=True)
    return sign_internal_request(TEST_INTERNAL_SECRET, method, path, "tester", perms)


def test_agent_file_write_sandbox_conflicts_and_permissions(tmp_agent_env: dict) -> None:
    proj_dir: Path = tmp_agent_env["proj_dir"]
    brain_dir: Path = tmp_agent_env["brain_dir"]
    sid = "11111111-1111-4111-8111-111111111112"

    draft_file = proj_dir / "chapter_02.md"
    draft_file.write_text("第一段\n第二段\n", encoding="utf-8")

    # Sensitive file and brain transcript file that must never be edited
    secret_env = tmp_agent_env["scratch_dir"] / ".env"
    secret_env.write_text("SECRET=1\n", encoding="utf-8")
    agent_cfg = tmp_agent_env["scratch_dir"] / "agent_config.json"
    agent_cfg.write_text("{}\n", encoding="utf-8")
    sys_transcript = brain_dir / sid / ".system_generated" / "logs" / "transcript.jsonl"
    sys_transcript.parent.mkdir(parents=True, exist_ok=True)
    sys_transcript.write_text('{"step_index":1}\n', encoding="utf-8")

    app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    with TestClient(app) as client:
        read_resp = client.get(
            "/agent/files/content?root_id=scratch&path=demo_project/chapter_02.md",
            headers=_signed_headers("GET", "/agent/files/content"),
        )
        assert read_resp.status_code == 200
        initial_mtime = read_resp.json()["mtime"]
        assert initial_mtime > 0

        # 1. Valid edit with expected_mtime
        put_resp = client.put(
            "/agent/files/content",
            headers=_signed_headers("PUT", "/agent/files/content", can_write=True),
            json={
                "root_id": "scratch",
                "path": "demo_project/chapter_02.md",
                "content": "第一段\n改写后的第二段\n新增第三段\n",
                "expected_mtime": initial_mtime,
            },
        )
        assert put_resp.status_code == 200
        put_data = put_resp.json()
        assert put_data["ok"] is True
        assert put_data["total_lines"] == 3
        assert put_data["mtime"] >= initial_mtime
        assert "改写后的第二段" in draft_file.read_text(encoding="utf-8")

        # 2. Stale expected_mtime returns 409 Conflict
        stale_resp = client.put(
            "/agent/files/content",
            headers=_signed_headers("PUT", "/agent/files/content", can_write=True),
            json={
                "root_id": "scratch",
                "path": "demo_project/chapter_02.md",
                "content": "覆盖冲突",
                "expected_mtime": initial_mtime - 5.0,
            },
        )
        assert stale_resp.status_code == 409

        # 3. Read-only caller returns 403
        ro_resp = client.put(
            "/agent/files/content",
            headers=_signed_headers("PUT", "/agent/files/content", can_write=False),
            json={
                "root_id": "scratch",
                "path": "demo_project/chapter_02.md",
                "content": "无权限写入",
            },
        )
        assert ro_resp.status_code == 403

        # 4. Sensitive files & system transcript files return 403
        for req_body in (
            {"root_id": "scratch", "path": ".env", "content": "HACK=1"},
            {"root_id": "scratch", "path": "agent_config.json", "content": "{}"},
            {
                "root_id": "brain",
                "path": f"{sid}/.system_generated/logs/transcript.jsonl",
                "content": "tamper",
            },
            {"root_id": "scratch", "path": "../../outside.txt", "content": "escape"},
        ):
            r = client.put(
                "/agent/files/content",
                headers=_signed_headers("PUT", "/agent/files/content", can_write=True),
                json=req_body,
            )
            assert r.status_code == 403

        # 5. Missing file returns 404, binary/NUL content returns 415
        missing_resp = client.put(
            "/agent/files/content",
            headers=_signed_headers("PUT", "/agent/files/content", can_write=True),
            json={"root_id": "scratch", "path": "demo_project/missing.md", "content": "hi"},
        )
        assert missing_resp.status_code == 404

        nul_resp = client.put(
            "/agent/files/content",
            headers=_signed_headers("PUT", "/agent/files/content", can_write=True),
            json={"root_id": "scratch", "path": "demo_project/chapter_02.md", "content": "bad\x00bytes"},
        )
        assert nul_resp.status_code == 415


def test_tool_output_and_artifacts_endpoints(tmp_agent_env: dict) -> None:
    brain_dir: Path = tmp_agent_env["brain_dir"]
    sid = "22222222-2222-4222-8222-222222222222"
    session_dir = brain_dir / sid
    logs_dir = session_dir / ".system_generated" / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    secret_path = str(tmp_agent_env["scratch_dir"] / ".env")
    steps = [
        {"step_index": 1, "type": "USER_INPUT", "status": "DONE", "content": "run tests"},
        {
            "step_index": 2,
            "type": "PLANNER_RESPONSE",
            "status": "DONE",
            "tool_calls": [
                {
                    "name": "run_command",
                    "args": {"CommandLine": "pytest -v", "toolSummary": "Run pytest"},
                },
                {
                    "name": "read_file",
                    "args": {"Path": secret_path},
                },
            ],
        },
        {
            "step_index": 3,
            "type": "GENERIC",
            "status": "DONE",
            "content": "24 passed in 1.2s",
        },
        {
            "step_index": 4,
            "type": "PLANNER_RESPONSE",
            "status": "DONE",
            "content": "next turn should not leak into step 2",
        },
    ]
    (logs_dir / "transcript_full.jsonl").write_text(
        "\n".join(json.dumps(s, ensure_ascii=False) for s in steps) + "\n",
        encoding="utf-8",
    )

    # Create artifacts & ignored files inside brain/<sid>
    plan_file = session_dir / "plan.md"
    plan_file.write_text("# Plan\n", encoding="utf-8")
    scratch_py = session_dir / "scratch" / "helper.py"
    scratch_py.parent.mkdir(parents=True, exist_ok=True)
    scratch_py.write_text("print('ok')\n", encoding="utf-8")
    preview_img = session_dir / "preview.png"
    preview_img.write_bytes(b"\x89PNG\r\n\x1a\n")

    # Files that must be excluded from artifacts listing
    uploaded_img = session_dir / ".user_uploaded" / "pic.png"
    uploaded_img.parent.mkdir(parents=True, exist_ok=True)
    uploaded_img.write_bytes(b"\x89PNG")
    sandbox_img = session_dir / "browser_sandbox" / "shot.png"
    sandbox_img.parent.mkdir(parents=True, exist_ok=True)
    sandbox_img.write_bytes(b"\x89PNG")
    hidden_env = session_dir / ".env"
    hidden_env.write_text("TOKEN=x\n", encoding="utf-8")

    # Verify truncation directly via helper
    clipped = get_step_tool_output(brain_dir, sid, 2, max_chars=5)
    assert clipped.truncated is True
    assert clipped.output == "24 pa"

    app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    with TestClient(app) as client:
        out_path = f"/agent/sessions/{sid}/steps/2/tool-output"
        out_resp = client.get(out_path, headers=_signed_headers("GET", out_path))
        assert out_resp.status_code == 200
        out_data = out_resp.json()
        assert out_data["result_step_index"] == 3
        assert out_data["status"] == "DONE"
        assert "24 passed in 1.2s" in out_data["output"]
        assert "next turn" not in out_data["output"]
        assert out_data["tool_calls"][1]["args"]["Path"] == "[redacted]"

        art_path = f"/agent/sessions/{sid}/artifacts"
        art_resp = client.get(art_path, headers=_signed_headers("GET", art_path))
        assert art_resp.status_code == 200
        items = art_resp.json()["items"]
        names = {item["name"]: item for item in items}
        assert set(names.keys()) == {"plan.md", "helper.py", "preview.png"}
        assert names["plan.md"]["is_markdown"] is True
        assert names["preview.png"]["is_image"] is True
        assert names["helper.py"]["rel_path"] == f"{sid}/scratch/helper.py"


def test_deck_cli_mode_flag_mapping(tmp_path: Path) -> None:
    cfg_default = AgentConfig(
        node_id="deck",
        platform="deck",
        internal_secret=TEST_INTERNAL_SECRET,
        deck_permission_mode="default",
        roots={"scratch": str(tmp_path)},
    )
    provider = DeckEngineProvider(cfg_default, RootRegistry())
    assert provider._build_cli_flags("gemini-3.8-flash", "plan") == ["--mode=plan", "--model=gemini-3.8-flash"]
    assert provider._build_cli_flags(None, "accept-edits") == ["--mode=accept-edits"]
    assert provider._build_cli_flags(None, "auto") == ["--mode=auto"]
    # Legacy "turbo" maps cleanly to "--mode=auto" instead of passing invalid CLI flags
    assert provider._build_cli_flags(None, "turbo") == ["--mode=auto"]

    cfg_skip = AgentConfig(
        node_id="deck",
        platform="deck",
        internal_secret=TEST_INTERNAL_SECRET,
        deck_permission_mode="skip_permissions",
        roots={"scratch": str(tmp_path)},
    )
    provider_skip = DeckEngineProvider(cfg_skip, RootRegistry())
    assert provider_skip._build_cli_flags("pro", "plan") == [
        "--mode=plan",
        "--dangerously-skip-permissions",
        "--model=pro",
    ]
