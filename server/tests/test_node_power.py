"""Tests for NodePowerManager multi-task global idle trigger and Gateway host-node restriction."""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.agent.config import AgentConfig
from agy_hub.agent.message_queue import SessionMessageQueueManager
from agy_hub.agent.power import NodePowerManager
from agy_hub.agent.providers.base import BaseEngineProvider
from agy_hub.common.sandbox import RootRegistry
from agy_hub.common.schemas import (
    ActionAckResponse,
    CreateSessionResponse,
    DeleteSessionResponse,
    ModelsResponse,
    PinSessionResponse,
    QuotaResponse,
    SessionMessagesResponse,
    SessionTreeResponse,
    ToolApprovalItem,
    UserPermissionGrant,
)
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.db import HubDatabase
from tests.conftest import TEST_INTERNAL_SECRET, TEST_SIGNING_SECRET


class _FakePowerProvider(BaseEngineProvider):
    platform_name = "windows"
    supports_tool_approval = True

    def __init__(self, tmp_path: Path, config: AgentConfig) -> None:
        self._brain = tmp_path / "brain"
        self._db = tmp_path / "db.sqlite"
        self._ws = tmp_path / "scratch"
        self._brain.mkdir(parents=True, exist_ok=True)
        self._ws.mkdir(parents=True, exist_ok=True)
        super().__init__(config, RootRegistry({"scratch": self._ws, "brain": self._brain}))
        self.running_ids: list[str] = []
        self.approvals_by_session: dict[str, list[ToolApprovalItem]] = {}

    @property
    def brain_dir(self) -> Path:
        return self._brain

    @property
    def db_path(self) -> Path:
        return self._db

    @property
    def default_workspace(self) -> Path:
        return self._ws

    async def is_engine_alive(self) -> bool:
        return True

    async def get_session_tree(self) -> SessionTreeResponse:
        return SessionTreeResponse(engine_alive=True, running_session_ids=list(self.running_ids))

    async def get_session_messages(self, session_id: str, limit: int = 120, before_step: int | None = None) -> SessionMessagesResponse:
        return SessionMessagesResponse(session_id=session_id)

    async def get_pending_approvals(self, session_id: str) -> list[ToolApprovalItem]:
        return list(self.approvals_by_session.get(session_id, []))

    async def create_session(self, content: str, model: str | None = None, mode: str = "auto", workspace_path: str | None = None) -> CreateSessionResponse:
        return CreateSessionResponse(ok=True, session_id="s-1")

    async def send_message(self, session_id: str, content: str, model: str | None = None) -> ActionAckResponse:
        return ActionAckResponse(ok=True, session_id=session_id)

    async def stop_session(self, session_id: str) -> ActionAckResponse:
        return ActionAckResponse(ok=True, session_id=session_id)

    async def delete_session(self, session_id: str) -> DeleteSessionResponse:
        return DeleteSessionResponse(ok=True, session_id=session_id)

    async def set_session_pinned(self, session_id: str, pinned: bool) -> PinSessionResponse:
        return PinSessionResponse(ok=True, session_id=session_id, is_pinned=pinned)

    async def fetch_quota(self) -> QuotaResponse:
        return QuotaResponse()

    async def get_models(self) -> ModelsResponse:
        return ModelsResponse()


def _make_provider_and_queue(tmp_path: Path, *, enabled: bool = True) -> tuple[_FakePowerProvider, SessionMessageQueueManager]:
    cfg = AgentConfig(platform="windows", internal_secret=TEST_INTERNAL_SECRET, enable_remote_power=enabled)
    provider = _FakePowerProvider(tmp_path, cfg)
    queue = SessionMessageQueueManager(provider)
    return provider, queue


@pytest.mark.asyncio
async def test_power_manager_waits_for_all_tasks_approvals_queues_and_settle(tmp_path: Path) -> None:
    provider, queue = _make_provider_and_queue(tmp_path, enabled=True)
    executed: list[tuple[str, str]] = []

    async def fake_exec(plat: str, act: str) -> None:
        executed.append((plat, act))

    mgr = NodePowerManager(provider, queue, enabled=True, poll_interval=0.02, executor=fake_exec)
    try:
        # 1. Arm while idle -> waiting_for_activity, never shuts down before a task starts
        st = await mgr.schedule(action="sleep", armed_by="simeng", settle_seconds=0.08, countdown_seconds=0.1)
        assert st.state == "waiting_for_activity"
        await asyncio.sleep(0.15)
        assert executed == []

        # 2. Two concurrent sessions start -> armed; finishing 1 keeps armed
        provider.running_ids = ["s1", "s2"]
        st = await mgr.refresh_status()
        assert st.state == "armed"
        assert st.running_sessions == 2

        provider.running_ids = ["s2"]
        st = await mgr.refresh_status()
        assert st.state == "armed"
        assert st.running_sessions == 1

        # 3. Task pauses on pending approval -> keeps armed even if running_ids clears
        provider.running_ids = []
        provider.approvals_by_session["s2"] = [
            ToolApprovalItem(
                approval_id="a1",
                session_id="s2",
                trajectory_id="t1",
                step_index=1,
                interaction_kind="run_command",
                raw_interaction_field="permission",
                title="Run command",
            )
        ]
        st = await mgr.refresh_status()
        assert st.state == "armed"
        assert st.pending_approvals == 1

        # 4. Approval cleared, but queued message remains -> keeps armed
        provider.approvals_by_session.clear()
        await queue.enqueue("s2", "follow-up")
        st = await mgr.refresh_status()
        assert st.state == "armed"
        assert st.queued_messages == 1

        # 5. Queue clears -> enters settling -> new activity aborts back to armed -> clears & executes once
        await queue.clear_queue("s2")
        st = await mgr.refresh_status()
        assert st.state == "settling"

        provider.running_ids = ["s3"]
        st = await mgr.refresh_status()
        assert st.state == "armed"

        provider.running_ids = []
        for _ in range(40):
            if executed:
                break
            await asyncio.sleep(0.03)
        assert executed == [("windows", "sleep")]
        assert mgr.status().state == "off"
    finally:
        await mgr.shutdown()


@pytest.mark.asyncio
async def test_power_manager_cancel_and_disabled_guard(tmp_path: Path) -> None:
    provider, queue = _make_provider_and_queue(tmp_path, enabled=True)
    executed: list[tuple[str, str]] = []

    async def fake_exec(plat: str, act: str) -> None:
        executed.append((plat, act))

    mgr = NodePowerManager(provider, queue, enabled=True, poll_interval=0.02, executor=fake_exec)
    provider.running_ids = ["s1"]
    await mgr.schedule(action="shutdown", settle_seconds=0.0, countdown_seconds=0.25)
    provider.running_ids = []
    await asyncio.sleep(0.06)
    assert mgr.status().state == "countdown"
    cancelled = await mgr.cancel(reason="用户取消")
    assert cancelled.enabled is False
    assert cancelled.state == "off"
    await asyncio.sleep(0.25)
    assert executed == []

    disabled_mgr = NodePowerManager(provider, queue, enabled=False)
    assert disabled_mgr.status().supported is False
    with pytest.raises(PermissionError):
        await disabled_mgr.schedule("shutdown")


def test_gateway_power_blocks_local_gateway_and_allows_normal_node_members(tmp_path: Path) -> None:
    db = HubDatabase(tmp_path / "hub.db")
    db.create_user(
        username="admin_u",
        password="AdminPassword!123",
        display_name="Admin",
        role="admin",
        default_node="deck",
        grants=[
            UserPermissionGrant(node_id="deck", can_write=True, can_delete=True),
            UserPermissionGrant(node_id="win", can_write=True, can_delete=True),
        ],
    )
    db.create_user(
        username="member_rw",
        password="MemberPassword!123",
        display_name="MemberRW",
        role="member",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=True, can_delete=False)],
    )
    db.create_user(
        username="member_ro",
        password="ReadOnlyPassword!123",
        display_name="MemberRO",
        role="member",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=False, can_delete=False)],
    )

    provider, _ = _make_provider_and_queue(tmp_path, enabled=True)
    executed: list[tuple[str, str]] = []

    async def fake_exec(plat: str, act: str) -> None:
        executed.append((plat, act))

    agent_cfg = AgentConfig(platform="windows", internal_secret=TEST_INTERNAL_SECRET, enable_remote_power=True)
    power_mgr = NodePowerManager(provider, SessionMessageQueueManager(provider), enabled=True, executor=fake_exec)
    agent_app = create_agent_app(agent_cfg, provider=provider, power_manager=power_mgr)
    agent_client = TestClient(agent_app)

    async def forward_handler(request: httpx.Request) -> httpx.Response:
        resp = agent_client.request(
            request.method,
            request.url.path + (f"?{request.url.query.decode()}" if request.url.query else ""),
            content=request.content,
            headers=dict(request.headers),
        )
        return httpx.Response(status_code=resp.status_code, content=resp.content, headers=dict(resp.headers))

    gw_cfg = GatewayConfig(
        db_path=str(tmp_path / "hub.db"),
        signing_secret=TEST_SIGNING_SECRET,
        internal_secret=TEST_INTERNAL_SECRET,
        allowed_origins=["http://127.0.0.1"],
        cookie_secure=False,
        nodes={
            "deck": NodeConfig(name="Steam Deck Gateway", base_url="http://127.0.0.1:18769", is_local=True),
            "win": NodeConfig(name="Windows PC", base_url="http://upstream.test", is_local=False),
        },
    )
    gw_app = create_gateway_app(
        gw_cfg,
        db=db,
        http_client=httpx.AsyncClient(transport=httpx.MockTransport(forward_handler)),
        enable_monitor=False,
    )

    with agent_client, TestClient(gw_app) as client:
        # Admin cannot power off the local Gateway node
        admin_login = client.post("/api/v2/auth/login", json={"username": "admin_u", "password": "AdminPassword!123"})
        admin_hdr = {"Authorization": f"Bearer {admin_login.json()['tokens']['access_token']}"}
        r_deck_get = client.get("/api/v2/nodes/deck/power/status", headers=admin_hdr)
        assert r_deck_get.status_code == 200
        assert r_deck_get.json()["supported"] is False

        r_deck_post = client.post("/api/v2/nodes/deck/power/schedule", headers=admin_hdr, json={"action": "shutdown"})
        assert r_deck_post.status_code == 403

        # Regular RW member CAN schedule & cancel power on their normal node (is_local=False)
        rw_login = client.post("/api/v2/auth/login", json={"username": "member_rw", "password": "MemberPassword!123"})
        rw_hdr = {"Authorization": f"Bearer {rw_login.json()['tokens']['access_token']}"}
        r_sched = client.post(
            "/api/v2/nodes/win/power/schedule",
            headers=rw_hdr,
            json={"action": "shutdown", "settle_seconds": 15, "countdown_seconds": 45},
        )
        assert r_sched.status_code == 200
        assert r_sched.json()["enabled"] is True
        assert r_sched.json()["state"] == "waiting_for_activity"
        assert r_sched.json()["armed_by"] == "member_rw"

        r_cancel = client.post("/api/v2/nodes/win/power/cancel", headers=rw_hdr)
        assert r_cancel.status_code == 200
        assert r_cancel.json()["enabled"] is False

        # Read-only member gets 403 on schedule
        ro_login = client.post("/api/v2/auth/login", json={"username": "member_ro", "password": "ReadOnlyPassword!123"})
        ro_hdr = {"Authorization": f"Bearer {ro_login.json()['tokens']['access_token']}"}
        r_ro = client.post("/api/v2/nodes/win/power/schedule", headers=ro_hdr, json={"action": "shutdown"})
        assert r_ro.status_code == 403
