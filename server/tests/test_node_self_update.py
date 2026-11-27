"""Tests for controlled Node Agent self-update and Gateway admin RBAC."""

from __future__ import annotations

import subprocess
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.agent.config import AgentConfig
from agy_hub.agent.updater import NodeSelfUpdater
from agy_hub.common.sandbox import RootRegistry
from agy_hub.common.schemas import UserPermissionGrant
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.db import HubDatabase
from tests.conftest import FakeEngineProvider


def _git(cwd: Path, *args: str) -> str:
    res = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        check=True,
    )
    return res.stdout.strip()


def _setup_git_pair(tmp_path: Path) -> tuple[Path, Path]:
    """Create a bare origin repo and a local clone with an initial commit."""
    origin = tmp_path / "origin.git"
    origin.mkdir()
    _git(origin, "init", "--bare")

    seed = tmp_path / "seed"
    seed.mkdir()
    _git(seed, "init")
    _git(seed, "config", "user.email", "test@example.com")
    _git(seed, "config", "user.name", "Test")
    init_file = seed / "server" / "agy_hub" / "__init__.py"
    init_file.parent.mkdir(parents=True)
    init_file.write_text('__version__ = "2.2.2"\n', encoding="utf-8")
    _git(seed, "add", ".")
    _git(seed, "commit", "-m", "initial")
    _git(seed, "branch", "-M", "main")
    _git(seed, "remote", "add", "origin", str(origin))
    _git(seed, "push", "-u", "origin", "main")
    _git(origin, "symbolic-ref", "HEAD", "refs/heads/main")

    clone_dir = tmp_path / "node_clone"
    subprocess.run(["git", "clone", str(origin), str(clone_dir)], check=True, capture_output=True)
    _git(clone_dir, "config", "user.email", "test@example.com")
    _git(clone_dir, "config", "user.name", "Test")
    return seed, clone_dir


@pytest.mark.asyncio
async def test_node_self_updater_flow_and_guards(tmp_path: Path) -> None:
    seed, clone_dir = _setup_git_pair(tmp_path)
    exited = False

    def fake_exit() -> None:
        nonlocal exited
        exited = True

    updater = NodeSelfUpdater(repo_dir=clone_dir, exit_callback=fake_exit)

    # 1. Up-to-date check
    st0 = await updater.check_update(fetch=True, running_sessions=0)
    assert st0.git_available is True
    assert st0.update_available is False
    assert st0.behind_count == 0
    assert st0.dirty is False

    # 2. Push a new version commit to origin
    (seed / "server" / "agy_hub" / "__init__.py").write_text('__version__ = "2.3.1"\n', encoding="utf-8")
    _git(seed, "add", ".")
    _git(seed, "commit", "-m", "bump to 2.3.1")
    _git(seed, "push", "origin", "main")

    st1 = await updater.check_update(fetch=True, running_sessions=0)
    assert st1.update_available is True
    assert st1.behind_count == 1
    assert st1.can_update is True

    # 3. Dirty working tree must block update
    tracked = clone_dir / "server" / "agy_hub" / "__init__.py"
    original_content = tracked.read_text(encoding="utf-8")
    tracked.write_text('__version__ = "9.9.9-local"\n', encoding="utf-8")

    st_dirty = await updater.check_update(fetch=False, running_sessions=0)
    assert st_dirty.dirty is True
    assert st_dirty.can_update is False

    res_dirty = await updater.apply_update(running_sessions=0, force=False)
    assert res_dirty.ok is False
    assert "未提交改动" in res_dirty.message
    assert exited is False

    # Restore clean working tree
    tracked.write_text(original_content, encoding="utf-8")

    # 4. Running sessions block non-forced update
    res_busy = await updater.apply_update(running_sessions=1, force=False)
    assert res_busy.ok is False
    assert "正在运行" in res_busy.message

    # 5. Clean apply succeeds and reads new disk version
    res_ok = await updater.apply_update(running_sessions=1, force=True)
    assert res_ok.ok is True
    assert res_ok.updated is True
    assert res_ok.restarting is True
    assert res_ok.to_version == "2.3.1"

    task = updater.schedule_restart(delay_seconds=0.05)
    await task
    assert exited is True


def test_gateway_admin_nodes_and_update_rbac(tmp_path: Path) -> None:
    seed, clone_dir = _setup_git_pair(tmp_path)
    secret = "test-shared-secret-at-least-32-chars-long"
    exited = False
    updater = NodeSelfUpdater(repo_dir=clone_dir, exit_callback=lambda: None)

    agent_cfg = AgentConfig(internal_secret=secret, platform="windows")
    brain_dir = tmp_path / "brain"
    scratch_dir = tmp_path / "scratch"
    brain_dir.mkdir()
    scratch_dir.mkdir()
    registry = RootRegistry()
    provider = FakeEngineProvider(agent_cfg, registry, brain_dir, tmp_path / "state.vscdb", scratch_dir)
    agent_app = create_agent_app(
        agent_cfg,
        provider=provider,
        registry=registry,
        updater=updater,
    )
    transport = httpx.ASGITransport(app=agent_app)
    http_client = httpx.AsyncClient(transport=transport, base_url="http://agent.local")

    db = HubDatabase(tmp_path / "hub.db")
    db.create_user(
        username="admin",
        password="admin-password-123",
        display_name="Admin",
        role="admin",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=True, can_delete=True)],
    )
    db.create_user(
        username="admin_other",
        password="admin-other-password-123",
        display_name="Admin Other",
        role="admin",
        default_node="",
        grants=[],
    )
    db.create_user(
        username="member",
        password="member-password-123",
        display_name="Member",
        role="member",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=True, can_delete=False)],
    )

    gw_cfg = GatewayConfig(
        signing_secret="jwt-secret-key-for-testing-only-32bytes",
        internal_secret=secret,
        nodes={"win": NodeConfig(name="Windows PC", base_url="http://agent.local", is_local=False)},
    )
    gw_app = create_gateway_app(gw_cfg, db=db, http_client=http_client, enable_monitor=True)

    with TestClient(gw_app) as client:
        # Login member
        m_login = client.post(
            "/api/v2/auth/login",
            json={"username": "member", "password": "member-password-123"},
        )
        assert m_login.status_code == 200
        m_hdr = {"Authorization": f"Bearer {m_login.json()['tokens']['access_token']}"}

        # Member is forbidden from admin nodes & node self-update
        assert client.get("/api/v2/admin/nodes", headers=m_hdr).status_code == 403
        assert client.get("/api/v2/nodes/win/update/status", headers=m_hdr).status_code == 403
        assert client.post("/api/v2/nodes/win/update/apply", headers=m_hdr, json={}).status_code == 403

        # Login admin
        a_login = client.post(
            "/api/v2/auth/login",
            json={"username": "admin", "password": "admin-password-123"},
        )
        assert a_login.status_code == 200
        a_hdr = {"Authorization": f"Bearer {a_login.json()['tokens']['access_token']}"}

        # Admin sees version from /internal/health
        nodes_resp = client.get("/api/v2/admin/nodes", headers=a_hdr)
        assert nodes_resp.status_code == 200
        node_item = nodes_resp.json()["nodes"][0]
        assert node_item["online"] is True
        assert node_item["version"] != ""

        # Admin without explicit grant for 'win' must NOT see or update unassigned nodes
        a2_login = client.post(
            "/api/v2/auth/login",
            json={"username": "admin_other", "password": "admin-other-password-123"},
        )
        assert a2_login.status_code == 200
        a2_hdr = {"Authorization": f"Bearer {a2_login.json()['tokens']['access_token']}"}
        nodes_ungranted = client.get("/api/v2/admin/nodes", headers=a2_hdr)
        assert nodes_ungranted.status_code == 200
        assert nodes_ungranted.json()["nodes"] == []
        assert client.get("/api/v2/nodes/win/update/status?fetch=false", headers=a2_hdr).status_code == 403
        assert client.post("/api/v2/nodes/win/update/apply", headers=a2_hdr, json={}).status_code == 403

        # Admin can check update status
        status_resp = client.get("/api/v2/nodes/win/update/status?fetch=true", headers=a_hdr)
        assert status_resp.status_code == 200
        assert status_resp.json()["git_available"] is True
        assert status_resp.json()["update_available"] is False

        # Push remote commit and trigger update via Gateway
        (seed / "server" / "agy_hub" / "__init__.py").write_text('__version__ = "2.3.1"\n', encoding="utf-8")
        _git(seed, "add", ".")
        _git(seed, "commit", "-m", "remote update")
        _git(seed, "push", "origin", "main")

        apply_resp = client.post("/api/v2/nodes/win/update/apply", headers=a_hdr, json={"force": False})
        assert apply_resp.status_code == 200
        body = apply_resp.json()
        assert body["ok"] is True
        assert body["updated"] is True
        assert body["to_version"] == "2.3.1"
        assert exited is False


@pytest.mark.asyncio
async def test_node_self_updater_fetch_retries_http11_and_merges_offline(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    seed, clone_dir = _setup_git_pair(tmp_path)
    (seed / "server" / "agy_hub" / "__init__.py").write_text('__version__ = "2.3.7"\n', encoding="utf-8")
    _git(seed, "add", ".")
    _git(seed, "commit", "-m", "bump to 2.3.7")
    _git(seed, "push", "origin", "main")

    updater = NodeSelfUpdater(repo_dir=clone_dir, exit_callback=lambda: None)
    updater._fetch_retry_delays = (0.0, 0.0)

    calls: list[list[str]] = []
    orig_run_git = updater._run_git
    fail_all_fetches = False

    def spy_run_git(args: list[str], timeout: float = 25.0) -> subprocess.CompletedProcess[str]:
        calls.append(list(args))
        if "fetch" in args:
            if fail_all_fetches or "-c" not in args:
                return subprocess.CompletedProcess(
                    args=["git", *args],
                    returncode=128,
                    stdout="",
                    stderr="fatal: unable to access 'https://example.com/repo.git/': Recv failure: Connection was reset",
                )
        return orig_run_git(args, timeout=timeout)

    monkeypatch.setattr(updater, "_run_git", spy_run_git)

    # First fetch fails with Connection reset, retry with HTTP/1.1 succeeds.
    st = await updater.check_update(fetch=True, running_sessions=0)
    assert st.update_available is True
    assert st.behind_count == 1
    assert st.can_update is True
    assert any("http.version=HTTP/1.1" in arg for cmd in calls for arg in cmd)

    # Even if apply_update's fetch hits connection reset again, offline merge succeeds using cached tracking ref.
    calls.clear()
    fail_all_fetches = True
    res = await updater.apply_update(running_sessions=0, force=False)
    assert res.ok is True
    assert res.updated is True
    assert res.restarting is True
    assert res.to_version == "2.3.7"
    assert not any("pull" in cmd for cmd in calls)
    assert any(cmd[:2] == ["merge", "--ff-only"] for cmd in calls)


@pytest.mark.asyncio
async def test_node_self_updater_fetch_failure_without_cached_commits(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _seed, clone_dir = _setup_git_pair(tmp_path)
    updater = NodeSelfUpdater(repo_dir=clone_dir, exit_callback=lambda: None)
    updater._fetch_retry_delays = (0.0, 0.0)

    monkeypatch.setattr(
        updater,
        "_fetch_origin",
        lambda: "fatal: unable to access 'https://example.com/repo.git/': Recv failure: Connection was reset",
    )

    st = await updater.check_update(fetch=True, running_sessions=0)
    assert st.update_available is False
    assert st.can_update is False
    assert "拉取远端状态失败" in st.message

    res = await updater.apply_update(running_sessions=0, force=False)
    assert res.ok is False
    assert "连接远端仓库失败" in res.message
