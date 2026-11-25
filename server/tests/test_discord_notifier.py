"""Tests for Gateway Discord Webhook offline notification monitor and HTTP endpoints."""

from __future__ import annotations

from typing import Any

import httpx
from fastapi.testclient import TestClient

from agy_hub.common.schemas import UserPermissionGrant
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.db import HubDatabase
from agy_hub.gateway.notifier import DiscordNotificationMonitor
from agy_hub.gateway.registry import NodeRegistryManager
from tests.conftest import TEST_INTERNAL_SECRET, TEST_SIGNING_SECRET


def _make_config(tmp_path, *, webhook_url: str = "https://discord.com/api/webhooks/123/abc") -> GatewayConfig:
    return GatewayConfig(
        host="127.0.0.1",
        port=8768,
        db_path=str(tmp_path / "hub.db"),
        signing_secret=TEST_SIGNING_SECRET,
        internal_secret=TEST_INTERNAL_SECRET,
        cookie_secure=False,
        discord_webhook_url=webhook_url,
        notify_min_run_seconds=15.0,
        notify_ask_question_delay_seconds=10.0,
        nodes={
            "win": NodeConfig(name="Windows PC", base_url="http://127.0.0.1:9901", is_local=False),
        },
    )


async def test_discord_notifier_rules_completion_error_ask_question_and_anti_spam(tmp_path) -> None:
    cfg = _make_config(tmp_path)
    now_holder = {"t": 100.0}

    tree_state: dict[str, Any] = {
        "projects": {
            "agy_mobile": [
                {"id": "s-short", "title": "短任务", "is_running": True},
            ],
        },
        "general_sessions": [],
        "running_session_ids": ["s-short"],
    }
    messages_by_sid: dict[str, list[dict[str, Any]]] = {
        "s-short": [],
        "s-long": [],
        "s-err": [],
    }

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/internal/health":
            return httpx.Response(200, json={"status": "healthy", "engine_alive": True})
        if path == "/agent/sessions":
            return httpx.Response(200, json=tree_state)
        for sid in ("s-short", "s-long", "s-err"):
            if path == f"/agent/sessions/{sid}/messages":
                return httpx.Response(200, json={"session_id": sid, "messages": messages_by_sid.get(sid, [])})
        return httpx.Response(404)

    sent_payloads: list[dict[str, Any]] = []

    async def fake_webhook_sender(_url: str, payload: dict[str, Any]) -> tuple[bool, str]:
        sent_payloads.append(payload)
        return True, "ok"

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        registry = NodeRegistryManager(cfg.nodes, http_client=client)
        await registry.probe_all()
        assert registry.is_node_online("win")

        monitor = DiscordNotificationMonitor(
            cfg,
            registry,
            http_client=client,
            webhook_sender=fake_webhook_sender,
            time_fn=lambda: now_holder["t"],
        )

        # 1. Initial prime scan: should establish baseline without notifying
        await monitor.poll_once()
        assert len(sent_payloads) == 0

        # 2. Short session finishes in 5s (< 15s) -> NO completion notification
        now_holder["t"] = 105.0
        tree_state["projects"]["agy_mobile"][0]["is_running"] = False
        tree_state["running_session_ids"] = []
        messages_by_sid["s-short"] = [
            {"step_index": 2, "msg_type": "PLANNER_RESPONSE", "status": "DONE", "content": "已回复"}
        ]
        await monitor.poll_once()
        assert len(sent_payloads) == 0

        # 3. Long task starts at t=110, user has active WS subscription -> finishes at t=130 -> suppressed!
        now_holder["t"] = 110.0
        tree_state["projects"]["agy_mobile"].append({"id": "s-long", "title": "长耗时任务", "is_running": True})
        tree_state["running_session_ids"] = ["s-long"]
        await monitor.poll_once()

        monitor.on_ws_subscription_change("win", "s-long", True)
        now_holder["t"] = 130.0
        tree_state["projects"]["agy_mobile"][-1]["is_running"] = False
        tree_state["running_session_ids"] = []
        messages_by_sid["s-long"] = [
            {"step_index": 5, "msg_type": "PLANNER_RESPONSE", "status": "DONE", "content": "全量测试通过"}
        ]
        await monitor.poll_once()
        assert len(sent_payloads) == 0  # suppressed because active WS client was watching

        # 4. Now unsubscribe WS and run a long task again -> >= 15s completion sends GREEN embed
        monitor.on_ws_subscription_change("win", "s-long", False)
        now_holder["t"] = 140.0
        tree_state["projects"]["agy_mobile"][-1]["is_running"] = True
        tree_state["running_session_ids"] = ["s-long"]
        messages_by_sid["s-long"] = []
        await monitor.poll_once()

        # 4a. Midway at t=142, AI triggers ask_question -> wait until 10s elapses
        now_holder["t"] = 142.0
        messages_by_sid["s-long"] = [
            {
                "step_index": 8,
                "msg_type": "PLANNER_RESPONSE",
                "status": "DONE",
                "content": "",
                "tool_calls": [
                    {
                        "name": "ask_question",
                        "args": {"questions": [{"question": "是否同步部署到 Steam Deck？"}]},
                    }
                ],
            }
        ]
        # Even if client has WS subscribed, unconfirmed ask_question >= 10s forces amber alert once
        monitor.on_ws_subscription_change("win", "s-long", True)
        await monitor.poll_once()
        assert len(sent_payloads) == 0  # only seen for 0s

        now_holder["t"] = 149.0  # +7s (< 10s) -> still not sent
        await monitor.poll_once()
        assert len(sent_payloads) == 0

        now_holder["t"] = 152.0  # +10s -> forced amber embed!
        await monitor.poll_once()
        assert len(sent_payloads) == 1
        ask_embed = sent_payloads[0]["embeds"][0]
        assert ask_embed["color"] == 0xF59E0B
        assert "需要你确认选项" in ask_embed["title"]
        assert "是否同步部署到 Steam Deck" in ask_embed["description"]

        # Same ask_question step should NOT spam on next poll
        now_holder["t"] = 160.0
        await monitor.poll_once()
        assert len(sent_payloads) == 1

        # 4b. User disconnects WS and task finishes at t=175 -> GREEN embed
        monitor.on_ws_subscription_change("win", "s-long", False)
        now_holder["t"] = 175.0
        tree_state["projects"]["agy_mobile"][-1]["is_running"] = False
        tree_state["running_session_ids"] = []
        messages_by_sid["s-long"].append(
            {"step_index": 9, "msg_type": "PLANNER_RESPONSE", "status": "DONE", "content": "已同步部署完成。"}
        )
        await monitor.poll_once()
        assert len(sent_payloads) == 2
        done_embed = sent_payloads[1]["embeds"][0]
        assert done_embed["color"] == 0x10B981
        assert "任务已完成" in done_embed["title"]
        assert any(f["name"] == "耗时" and f["value"] == "35s" for f in done_embed["fields"])

        # 5. Error ending even if < 15s -> RED embed
        now_holder["t"] = 180.0
        tree_state["projects"]["agy_mobile"].append({"id": "s-err", "title": "报错任务", "is_running": True})
        tree_state["running_session_ids"] = ["s-err"]
        await monitor.poll_once()

        now_holder["t"] = 184.0
        tree_state["projects"]["agy_mobile"][-1]["is_running"] = False
        tree_state["running_session_ids"] = []
        messages_by_sid["s-err"] = [
            {"step_index": 3, "msg_type": "PLANNER_RESPONSE", "status": "ERROR", "content": "Upstream timeout"}
        ]
        await monitor.poll_once()
        assert len(sent_payloads) == 3
        err_embed = sent_payloads[2]["embeds"][0]
        assert err_embed["color"] == 0xEF4444
        assert "任务异常中断" in err_embed["title"]


def test_gateway_notification_status_and_admin_test_endpoint(tmp_path) -> None:
    cfg = _make_config(tmp_path, webhook_url="https://discord.com/api/webhooks/secret_id/secret_token")
    db = HubDatabase(cfg.db_path)
    db.create_user(
        username="admin",
        password="AdminPassword!123",
        display_name="Admin",
        role="admin",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=True, can_delete=True)],
    )
    db.create_user(
        username="member",
        password="MemberPassword!123",
        display_name="Member",
        role="member",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=True, can_delete=False)],
    )

    posted: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if "discord.com/api/webhooks" in str(request.url):
            posted.append(str(request.url))
            return httpx.Response(204)
        return httpx.Response(200, json={"status": "healthy"})

    with httpx.Client(transport=httpx.MockTransport(handler)) as _:
        pass

    async_client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    app = create_gateway_app(cfg, db=db, http_client=async_client, enable_monitor=False)

    with TestClient(app) as client:
        # Admin login
        r_admin = client.post("/api/v2/auth/login", json={"username": "admin", "password": "AdminPassword!123"})
        assert r_admin.status_code == 200
        admin_tok = r_admin.json()["tokens"]["access_token"]

        # Status must NOT leak secret webhook URL
        st_resp = client.get("/api/v2/notifications/status", headers={"Authorization": f"Bearer {admin_tok}"})
        assert st_resp.status_code == 200
        st_json = st_resp.json()
        assert st_json["discord_configured"] is True
        assert st_json["ask_question_delay_seconds"] == 10.0
        assert "secret_token" not in st_resp.text

        # Admin can trigger test notification
        test_resp = client.post("/api/v2/notifications/test", headers={"Authorization": f"Bearer {admin_tok}"})
        assert test_resp.status_code == 200
        assert test_resp.json()["ok"] is True
        assert len(posted) == 1

        # Member cannot trigger test notification
        r_member = client.post("/api/v2/auth/login", json={"username": "member", "password": "MemberPassword!123"})
        mem_tok = r_member.json()["tokens"]["access_token"]
        mem_test = client.post("/api/v2/notifications/test", headers={"Authorization": f"Bearer {mem_tok}"})
        assert mem_test.status_code == 403
