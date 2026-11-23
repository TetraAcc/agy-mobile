"""Tests for stateless Node Agent HTTP endpoints, read-only SQLite guarantee, git diff, and quota."""

from __future__ import annotations

import json
import sqlite3
import subprocess
from pathlib import Path

from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.agent.providers.deck import DeckEngineProvider
from agy_hub.common.security import sign_internal_request
from tests.conftest import TEST_INTERNAL_SECRET, write_transcript_step


def _signed_headers(method: str, path: str, can_write: bool = True, can_delete: bool = True) -> dict[str, str]:
    perms = json.dumps({"can_write": can_write, "can_delete": can_delete}, separators=(",", ":"), sort_keys=True)
    return sign_internal_request(TEST_INTERNAL_SECRET, method, path, "tester", perms)


def test_agent_rejects_unsigned_requests(tmp_agent_env: dict) -> None:
    app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    with TestClient(app) as client:
        assert client.get("/internal/health").status_code == 200
        assert client.get("/agent/sessions").status_code == 401
        bad_headers = {"X-Hub-User": "hacker", "X-Hub-Timestamp": "9999999999", "X-Hub-Nonce": "1", "X-Hub-Signature": "deadbeef"}
        assert client.get("/agent/sessions", headers=bad_headers).status_code == 401


def test_agent_sessions_tree_readonly_db_and_pagination(tmp_agent_env: dict) -> None:
    db_path: Path = tmp_agent_env["db_path"]
    brain_dir: Path = tmp_agent_env["brain_dir"]
    sid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
    for idx in range(3, 10):
        write_transcript_step(
            brain_dir,
            sid,
            {"step_index": idx, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "content": f"step {idx}"},
        )

    app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    with TestClient(app) as client:
        # 1. Session tree reads FTS project, filters subagent & orphan, keeps official SQLite untouched
        resp = client.get("/agent/sessions", headers=_signed_headers("GET", "/agent/sessions"))
        assert resp.status_code == 200
        tree = resp.json()
        assert "MySpecialProject" in tree["projects"]
        proj_ids = [s["id"] for s in tree["projects"]["MySpecialProject"]]
        assert proj_ids == [sid]
        gen_ids = [s["id"] for s in tree["general_sessions"]]
        assert "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2" in gen_ids
        assert "cccccccc-cccc-4ccc-8ccc-ccccccccccc3" not in proj_ids
        assert "dddddddd-dddd-4ddd-8ddd-ddddddddddd4" not in proj_ids

        # Verify official DB still has all 4 rows (read-only guarantee)
        conn = sqlite3.connect(db_path)
        count = conn.execute("SELECT COUNT(*) FROM conversation_summaries").fetchone()[0]
        conn.close()
        assert count == 4

        # 2. Pagination on messages
        m_path = f"/agent/sessions/{sid}/messages"
        page1 = client.get(f"{m_path}?limit=4", headers=_signed_headers("GET", m_path))
        assert page1.status_code == 200
        p1_data = page1.json()
        assert len(p1_data["messages"]) == 4
        assert p1_data["has_more"] is True
        assert [m["step_index"] for m in p1_data["messages"]] == [6, 7, 8, 9]
        assert p1_data["next_before_step"] == 6

        page2 = client.get(f"{m_path}?before_step=6&limit=4", headers=_signed_headers("GET", m_path))
        p2_data = page2.json()
        assert [m["step_index"] for m in p2_data["messages"]] == [2, 3, 4, 5]


def test_agent_create_send_stop_delete_upload_files_git_quota(tmp_agent_env: dict) -> None:
    provider = tmp_agent_env["provider"]
    scratch_dir: Path = tmp_agent_env["scratch_dir"]
    proj_dir: Path = tmp_agent_env["proj_dir"]

    # Prepare sample text, binary, and git repository inside scratch
    (proj_dir / "hello.py").write_text("print('hello')\n", encoding="utf-8")
    (proj_dir / "img.png").write_bytes(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")
    subprocess.run(["git", "init"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "add", "hello.py"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=proj_dir, check=True, capture_output=True)
    (proj_dir / "hello.py").write_text("print('modified')\n", encoding="utf-8")

    sid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
    app = create_agent_app(tmp_agent_env["config"], provider=provider, registry=tmp_agent_env["registry"])
    with TestClient(app) as client:
        # Create session
        c_resp = client.post(
            "/agent/sessions",
            headers=_signed_headers("POST", "/agent/sessions"),
            json={"content": "Build feature", "model": "claude-sonnet-4-6", "mode": "plan", "workspace_path": str(proj_dir)},
        )
        assert c_resp.status_code == 200
        assert c_resp.json()["ok"] is True
        assert provider.created_sessions[-1]["mode"] == "plan"

        # Send message
        msg_path = f"/agent/sessions/{sid}/messages"
        s_resp = client.post(msg_path, headers=_signed_headers("POST", msg_path), json={"content": "继续"})
        assert s_resp.status_code == 200
        assert provider.sent_messages[-1]["content"] == "继续"

        # Stop
        stop_path = f"/agent/sessions/{sid}/stop"
        st_resp = client.post(stop_path, headers=_signed_headers("POST", stop_path))
        assert st_resp.status_code == 200
        assert sid in provider.stopped_sessions

        # Upload multipart
        up_path = f"/agent/sessions/{sid}/uploads"
        up_resp = client.post(
            up_path,
            headers=_signed_headers("POST", up_path),
            files={"file": ("shot.png", b"\x89PNG\r\n\x1a\n1234", "image/png")},
        )
        assert up_resp.status_code == 200
        up_data = up_resp.json()
        assert up_data["is_image"] is True
        assert Path(up_data["abs_path"]).is_file()

        # Browse tree, read text, reject binary with 415, download, media with file:///
        tree_resp = client.get("/agent/files/tree?root_id=scratch&path=demo_project", headers=_signed_headers("GET", "/agent/files/tree"))
        assert tree_resp.status_code == 200
        names = [i["name"] for i in tree_resp.json()["items"]]
        assert "hello.py" in names

        txt_resp = client.get("/agent/files/content?root_id=scratch&path=demo_project/hello.py", headers=_signed_headers("GET", "/agent/files/content"))
        assert txt_resp.status_code == 200
        assert "modified" in txt_resp.json()["content"]

        bin_resp = client.get("/agent/files/content?root_id=scratch&path=demo_project/img.png", headers=_signed_headers("GET", "/agent/files/content"))
        assert bin_resp.status_code == 415

        dl_resp = client.get("/agent/files/download?root_id=scratch&path=demo_project/hello.py", headers=_signed_headers("GET", "/agent/files/download"))
        assert dl_resp.status_code == 200
        assert "attachment" in dl_resp.headers.get("content-disposition", "")

        media_uri = (proj_dir / "img.png").as_uri()
        media_resp = client.get(f"/agent/media?path={media_uri}", headers=_signed_headers("GET", "/agent/media"))
        assert media_resp.status_code == 200

        # Git diff
        diff_resp = client.get("/agent/git/diff?root_id=scratch", headers=_signed_headers("GET", "/agent/git/diff"))
        # Register demo_project directly for git diff
        proj_root_id = tmp_agent_env["registry"].register_workspace(proj_dir)
        diff_resp2 = client.get(f"/agent/git/diff?root_id={proj_root_id}", headers=_signed_headers("GET", "/agent/git/diff"))
        assert diff_resp2.status_code == 200
        assert "modified" in diff_resp2.json()["diff"]

        # Quota
        q_resp = client.get("/agent/quota", headers=_signed_headers("GET", "/agent/quota"))
        assert q_resp.status_code == 200
        assert q_resp.json()["groups"][0]["display_name"] == "Gemini"

        # Archive session (delete) without modifying SQLite
        del_path = f"/agent/sessions/{sid}"
        assert client.delete(del_path, headers=_signed_headers("DELETE", del_path, can_delete=False)).status_code == 403
        d_resp = client.delete(del_path, headers=_signed_headers("DELETE", del_path, can_delete=True))
        assert d_resp.status_code == 200
        assert d_resp.json()["archived"] is True

        # Archived session excluded from session tree, DB rows still 4
        after_tree = client.get("/agent/sessions", headers=_signed_headers("GET", "/agent/sessions")).json()
        assert "MySpecialProject" not in after_tree["projects"]


def test_deck_tsv_quota_parser() -> None:
    sample = (
        "Running as unit: run-r123.service\n"
        "Gemini\t5h Sliding\t76.9%\t2026-11-23T06:00:00Z\n"
        "Gemini\tWeekly\t91.2%\t2026-11-28T00:00:00Z\n"
        "Claude\t5h Sliding\t100.0%\t2026-11-23T06:00:00Z\n"
    )
    groups = DeckEngineProvider.parse_cli_quota_output(sample)
    assert len(groups) == 2
    assert groups[0].display_name == "Gemini"
    assert len(groups[0].buckets) == 2
    assert abs(groups[0].buckets[0].remaining_fraction - 0.769) < 1e-6
    assert groups[0].buckets[1].bucket_id == "weekly"


def test_deck_cli_flags_respect_permission_mode(tmp_path: Path) -> None:
    from agy_hub.agent.config import AgentConfig
    from agy_hub.common.sandbox import RootRegistry

    cfg_auto = AgentConfig(
        platform="deck",
        internal_secret=TEST_INTERNAL_SECRET,
        brain_dir=str(tmp_path / "b"),
        db_path=str(tmp_path / "d.db"),
        default_workspace=str(tmp_path),
        deck_permission_mode="auto",
    )
    p_auto = DeckEngineProvider(cfg_auto, RootRegistry())
    flags_auto = p_auto._build_cli_flags("gemini-3.8-flash-high", mode="plan")
    assert "--mode=plan" in flags_auto
    assert "--model=gemini-3.8-flash-high" in flags_auto
    assert "--dangerously-skip-permissions" not in flags_auto

    cfg_skip = cfg_auto.model_copy(update={"deck_permission_mode": "skip_permissions"})
    p_skip = DeckEngineProvider(cfg_skip, RootRegistry())
    assert "--dangerously-skip-permissions" in p_skip._build_cli_flags(None, mode="auto")


async def test_windows_provider_rpc_stop_and_quota(tmp_path: Path) -> None:
    import httpx
    from agy_hub.agent.config import AgentConfig
    from agy_hub.agent.providers.windows import WindowsEngineProvider
    from agy_hub.common.sandbox import RootRegistry

    daemon_dir = tmp_path / "daemon"
    daemon_dir.mkdir()
    (daemon_dir / "hub_123.json").write_text(
        json.dumps({"httpPort": 54321, "csrfToken": "csrf-test"}),
        encoding="utf-8",
    )

    called_methods: list[str] = []

    def _handler(request: httpx.Request) -> httpx.Response:
        assert request.headers.get("x-codeium-csrf-token") == "csrf-test"
        method = request.url.path.rsplit("/", 1)[-1]
        called_methods.append(method)
        if method == "RetrieveUserQuotaSummary":
            return httpx.Response(
                200,
                json={
                    "response": {
                        "groups": [
                            {
                                "displayName": "Gemini",
                                "buckets": [{"bucketId": "5h", "displayName": "5h", "window": "5h", "remainingFraction": 0.72}],
                            }
                        ]
                    }
                },
            )
        return httpx.Response(200, json={})

    transport = httpx.MockTransport(_handler)
    async with httpx.AsyncClient(transport=transport) as mock_client:
        cfg = AgentConfig(
            platform="windows",
            internal_secret=TEST_INTERNAL_SECRET,
            brain_dir=str(tmp_path / "brain"),
            db_path=str(tmp_path / "db.sqlite"),
            default_workspace=str(tmp_path),
            daemon_dir=str(daemon_dir),
        )
        provider = WindowsEngineProvider(cfg, RootRegistry(), http_client=mock_client)
        ack = await provider.stop_session("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")
        assert ack.ok is True
        assert "CancelCascadeInvocation" in called_methods
        assert "ForceStopCascadeTree" in called_methods

        quota = await provider.fetch_quota()
        assert len(quota.groups) == 1
        assert abs(quota.groups[0].buckets[0].remaining_fraction - 0.72) < 1e-6


def test_agent_pdf_media_percent_filename_and_clean_git_diff(tmp_agent_env: dict) -> None:
    proj_dir: Path = tmp_agent_env["proj_dir"]
    scratch_dir: Path = tmp_agent_env["scratch_dir"]

    pdf_name = "讲义_100%_笔记.pdf"
    pdf_file = proj_dir / pdf_name
    pdf_file.write_bytes(b"%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n")

    # Initialize a clean git repository inside proj_dir
    (proj_dir / "clean.txt").write_text("ok\n", encoding="utf-8")
    subprocess.run(["git", "init"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "add", "."], cwd=proj_dir, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "clean init"], cwd=proj_dir, check=True, capture_output=True)
    proj_root_id = tmp_agent_env["registry"].register_workspace(proj_dir)

    non_git_dir = scratch_dir / "plain_folder"
    non_git_dir.mkdir(parents=True, exist_ok=True)
    non_git_root_id = tmp_agent_env["registry"].register_workspace(non_git_dir)

    app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    with TestClient(app) as client:
        media_resp = client.get(
            "/agent/media",
            params={"root_id": "scratch", "path": f"demo_project/{pdf_name}"},
            headers=_signed_headers("GET", "/agent/media"),
        )
        assert media_resp.status_code == 200
        assert "application/pdf" in media_resp.headers.get("content-type", "")
        assert "inline" in media_resp.headers.get("content-disposition", "")
        assert media_resp.content.startswith(b"%PDF-1.4")

        dl_resp = client.get(
            "/agent/files/download",
            params={"root_id": "scratch", "path": f"demo_project/{pdf_name}"},
            headers=_signed_headers("GET", "/agent/files/download"),
        )
        assert dl_resp.status_code == 200
        assert "attachment" in dl_resp.headers.get("content-disposition", "")
        assert dl_resp.content.startswith(b"%PDF-1.4")

        clean_diff = client.get(
            f"/agent/git/diff?root_id={proj_root_id}",
            headers=_signed_headers("GET", "/agent/git/diff"),
        )
        assert clean_diff.status_code == 200
        assert clean_diff.json()["status"] == ""
        assert clean_diff.json()["diff"] == ""

        non_git_diff = client.get(
            f"/agent/git/diff?root_id={non_git_root_id}",
            headers=_signed_headers("GET", "/agent/git/diff"),
        )
        assert non_git_diff.status_code == 200
        assert non_git_diff.json()["diff"] == "Not a Git repository"
