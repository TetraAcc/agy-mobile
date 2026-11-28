"""Tests for native Antigravity Automations store, Agent routes, and Gateway RBAC."""

from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.agent.automations import AutomationError, AutomationStore
from agy_hub.agent.config import AgentConfig
from agy_hub.common.sandbox import RootRegistry
from agy_hub.common.schemas import AutomationUpsertRequest, UserPermissionGrant
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.db import HubDatabase
from tests.conftest import FakeEngineProvider


def _seed_native_automations(tmp_path: Path) -> tuple[Path, Path]:
    cfg_dir = tmp_path / "config"
    data_dir = tmp_path / "sidecar_data"
    (cfg_dir / "sidecars" / "daily-flight").mkdir(parents=True)
    (cfg_dir / "sidecars" / "swarm" / "swarm_board").mkdir(parents=True)

    # Scheduled sidecar (should be listed)
    (cfg_dir / "sidecars" / "daily-flight" / "sidecar.json").write_text(
        json.dumps(
            {
                "builtin": "schedule",
                "args": [
                    "CRON_TZ=Asia/Tokyo 0 9,21 * * *",
                    "agentapi",
                    "new-conversation",
                    "--",
                    "Check daily flights",
                ],
                "restart_policy": "always",
                "display_name": "每日机票监控",
                "description": "每天两次抓取大阪报价",
                "agent_permissions": {
                    "workspace_uris": ["file:///C:/Users/demo/flight-monitor"],
                    "access_grants": [
                        "read_file(C:/Users/demo/flight-monitor)",
                        "mcp(playwright/browser_navigate)",
                    ],
                },
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    # Non-schedule internal sidecar (must be filtered out)
    (cfg_dir / "sidecars" / "swarm" / "swarm_board" / "sidecar.json").write_text(
        json.dumps({"builtin": "command", "args": ["swarm-board"]}),
        encoding="utf-8",
    )

    # config.json with unrelated top-level keys that must never be lost
    (cfg_dir / "config.json").write_text(
        json.dumps(
            {
                "plugins": {"demo": {"enabled": True}},
                "userSettings": {"theme": "dark"},
                "sidecars": {
                    "daily-flight": {
                        "enabled": True,
                        "projectId": "proj-1",
                        "schemaVersion": 1,
                    },
                    "swarm/swarm_board": {"projectId": "proj-2", "schemaVersion": 1},
                },
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    ev_dir = data_dir / "daily-flight" / "events"
    ev_dir.mkdir(parents=True)
    (ev_dir / "20261128_105021.json").write_text(
        json.dumps(
            {
                "timestampMs": "1795830621000",
                "commandInvocationTimestampMs": "1795830500000",
                "error": "",
                "payload": {"newConversation": {"conversationId": "conv-auto-123"}},
            }
        ),
        encoding="utf-8",
    )
    log_dir = data_dir / "daily-flight" / "logs"
    log_dir.mkdir(parents=True)
    (log_dir / "sidecar.log").write_text(
        "\n".join(
            [
                "2026-11-28 01:49:22 [schedule] Scheduler started",
                "2026-11-28 01:49:22 [schedule] Next execution scheduled in 10h10m37s (at 2026-11-28 12:00:00 UTC)",
            ]
        ),
        encoding="utf-8",
    )
    return cfg_dir, data_dir


def test_automation_store_crud_permissions_and_filtering(tmp_path: Path) -> None:
    cfg_dir, data_dir = _seed_native_automations(tmp_path)
    store = AutomationStore(config_dir=cfg_dir, data_dir=data_dir)

    listed = store.list_automations()
    assert [a.id for a in listed.items] == ["daily-flight"]
    item = listed.items[0]
    assert item.enabled is True
    assert item.cron_expr == "0 9,21 * * *"
    assert item.timezone == "Asia/Tokyo"
    assert item.workspace_path == "C:/Users/demo/flight-monitor"
    assert "Next execution" not in item.next_run_text
    assert item.next_run_text.startswith("in 10h10m37s")
    assert item.last_run_ok is True
    assert item.recent_events[0].conversation_id == "conv-auto-123"

    # Update preserves existing mcp(...) grant and config.json unrelated keys
    updated = store.update_automation(
        "daily-flight",
        AutomationUpsertRequest(
            display_name="每日机票监控 v2",
            description="更新描述",
            cron_expr="0 8,20 * * *",
            timezone="Asia/Tokyo",
            prompt="New prompt text",
            workspace_path="C:/Users/demo/flight-monitor",
            preserve_permissions=True,
        ),
    )
    assert updated.display_name == "每日机票监控 v2"
    assert updated.cron_expr == "0 8,20 * * *"
    assert "mcp(playwright/browser_navigate)" in updated.access_grants

    # Toggle off preserves projectId & unrelated top-level keys
    toggled = store.toggle_automation("daily-flight", False)
    assert toggled.enabled is False
    cfg_after = json.loads((cfg_dir / "config.json").read_text(encoding="utf-8"))
    assert cfg_after["plugins"] == {"demo": {"enabled": True}}
    assert cfg_after["sidecars"]["daily-flight"]["projectId"] == "proj-1"
    assert cfg_after["sidecars"]["daily-flight"]["enabled"] is False

    # Create new automation
    created = store.create_automation(
        AutomationUpsertRequest(
            id="weekly-check",
            display_name="每周巡检",
            cron_expr="0 9 * * 1",
            timezone="Asia/Tokyo",
            prompt="Check repos",
            workspace_path="C:/Users/demo/repo",
            enabled=False,
        )
    )
    assert created.id == "weekly-check"
    assert created.enabled is False
    assert "write_file(C:/Users/demo/repo)" in created.access_grants

    # Logs & invalid ID guard
    logs = store.get_logs("daily-flight", tail=10)
    assert len(logs.lines) == 2

    with pytest.raises(AutomationError) as exc_info:
        store.get_automation("../escape")
    assert exc_info.value.status_code == 400

    store.delete_automation("weekly-check")
    assert not (cfg_dir / "sidecars" / "weekly-check").exists()


def test_automations_gateway_agent_e2e_and_rbac(tmp_path: Path) -> None:
    cfg_dir, data_dir = _seed_native_automations(tmp_path)
    secret = "test-shared-secret-at-least-32-chars-long"
    store = AutomationStore(config_dir=cfg_dir, data_dir=data_dir)

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
        automation_store=store,
    )
    transport = httpx.ASGITransport(app=agent_app)
    http_client = httpx.AsyncClient(transport=transport, base_url="http://agent.local")

    db = HubDatabase(tmp_path / "hub.db")
    db.create_user(
        username="writer",
        password="writer-password-123",
        display_name="Writer",
        role="member",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=True, can_delete=True)],
    )
    db.create_user(
        username="viewer",
        password="viewer-password-123",
        display_name="Viewer",
        role="member",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=False, can_delete=False)],
    )

    gw_cfg = GatewayConfig(
        signing_secret="jwt-secret-key-for-testing-only-32bytes",
        internal_secret=secret,
        nodes={"win": NodeConfig(name="Windows PC", base_url="http://agent.local", is_local=False)},
    )
    gw_app = create_gateway_app(gw_cfg, db=db, http_client=http_client, enable_monitor=True)

    with TestClient(gw_app) as client:
        v_login = client.post(
            "/api/v2/auth/login",
            json={"username": "viewer", "password": "viewer-password-123"},
        )
        v_hdr = {"Authorization": f"Bearer {v_login.json()['tokens']['access_token']}"}

        w_login = client.post(
            "/api/v2/auth/login",
            json={"username": "writer", "password": "writer-password-123"},
        )
        w_hdr = {"Authorization": f"Bearer {w_login.json()['tokens']['access_token']}"}

        # Read-only user can list and view logs, but cannot write/delete/run
        list_resp = client.get("/api/v2/nodes/win/automations", headers=v_hdr)
        assert list_resp.status_code == 200
        assert len(list_resp.json()["items"]) == 1

        logs_resp = client.get("/api/v2/nodes/win/automations/daily-flight/logs", headers=v_hdr)
        assert logs_resp.status_code == 200
        assert len(logs_resp.json()["lines"]) == 2

        assert client.post(
            "/api/v2/nodes/win/automations/daily-flight/toggle",
            headers=v_hdr,
            json={"enabled": False},
        ).status_code == 403
        assert client.post(
            "/api/v2/nodes/win/automations/daily-flight/run",
            headers=v_hdr,
        ).status_code == 403
        assert client.delete(
            "/api/v2/nodes/win/automations/daily-flight",
            headers=v_hdr,
        ).status_code == 403

        # Write user can toggle, run now (creates session), and create
        toggle_resp = client.post(
            "/api/v2/nodes/win/automations/daily-flight/toggle",
            headers=w_hdr,
            json={"enabled": False},
        )
        assert toggle_resp.status_code == 200
        assert toggle_resp.json()["enabled"] is False

        run_resp = client.post("/api/v2/nodes/win/automations/daily-flight/run", headers=w_hdr)
        assert run_resp.status_code == 200
        run_body = run_resp.json()
        assert run_body["ok"] is True
        assert run_body["session_id"] == "11111111-1111-4111-8111-111111111199"

        create_resp = client.post(
            "/api/v2/nodes/win/automations",
            headers=w_hdr,
            json={
                "id": "e2e-task",
                "display_name": "E2E Task",
                "cron_expr": "0 10 * * *",
                "timezone": "Asia/Tokyo",
                "prompt": "Run diagnostics",
                "enabled": True,
            },
        )
        assert create_resp.status_code == 200
        assert create_resp.json()["enabled"] is True

        del_resp = client.delete("/api/v2/nodes/win/automations/e2e-task", headers=w_hdr)
        assert del_resp.status_code == 200
