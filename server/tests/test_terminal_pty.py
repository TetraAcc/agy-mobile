"""Tests for cross-platform true PTY terminal WebSocket endpoints and RBAC guards."""

from __future__ import annotations

import json
import time

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from agy_hub.agent.app import create_agent_app
from agy_hub.common.schemas import UserPermissionGrant
from agy_hub.common.security import sign_internal_request
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.db import HubDatabase
from tests.conftest import TEST_INTERNAL_SECRET, TEST_SIGNING_SECRET


def _ws_signed_headers(can_write: bool = True) -> dict[str, str]:
    perms = json.dumps({"can_write": can_write, "can_delete": False}, separators=(",", ":"), sort_keys=True)
    return sign_internal_request(TEST_INTERNAL_SECRET, "GET", "/agent/ws/terminal", "admin", perms)


def test_agent_terminal_ws_rejects_unauthorized_readonly_and_disabled(tmp_agent_env: dict) -> None:
    app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    with TestClient(app) as client:
        # Unsigned rejected with 4401
        with pytest.raises(WebSocketDisconnect) as exc1:
            with client.websocket_connect("/agent/ws/terminal"):
                pass
        assert exc1.value.code == 4401

        # Read-only caller rejected with 4403
        with pytest.raises(WebSocketDisconnect) as exc2:
            with client.websocket_connect("/agent/ws/terminal", headers=_ws_signed_headers(can_write=False)):
                pass
        assert exc2.value.code == 4403

    # Disabled in AgentConfig rejected with 4403
    disabled_cfg = tmp_agent_env["config"].model_copy(update={"enable_terminal": False})
    app_disabled = create_agent_app(
        disabled_cfg,
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    with TestClient(app_disabled) as client:
        with pytest.raises(WebSocketDisconnect) as exc3:
            with client.websocket_connect("/agent/ws/terminal", headers=_ws_signed_headers(can_write=True)):
                pass
        assert exc3.value.code == 4403


def test_agent_terminal_real_pty_roundtrip_resize_and_cleanup(tmp_agent_env: dict) -> None:
    app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    with TestClient(app) as client:
        with client.websocket_connect(
            "/agent/ws/terminal?cols=100&rows=30",
            headers=_ws_signed_headers(can_write=True),
        ) as ws:
            ready = json.loads(ws.receive_text())
            assert ready["type"] == "ready"
            assert ready["cols"] == 100
            assert ready["rows"] == 30
            assert app.state.terminal_manager.active_count == 1

            ws.send_text(json.dumps({"type": "resize", "cols": 110, "rows": 32}))
            ws.send_text(json.dumps({"type": "ping"}))
            ws.send_text(json.dumps({"type": "input", "data": "echo AGY_PTY_MARKER_234\r\n"}))

            got_marker = False
            got_pong = False
            deadline = time.time() + 12.0
            buffer = ""
            while time.time() < deadline and not (got_marker and got_pong):
                msg = json.loads(ws.receive_text())
                if msg.get("type") == "pong":
                    got_pong = True
                elif msg.get("type") == "output":
                    buffer += str(msg.get("data") or "")
                    if "AGY_PTY_MARKER_234" in buffer:
                        got_marker = True

            assert got_pong is True
            assert got_marker is True

        # Disconnecting WS must close PTY and release active slot
        assert app.state.terminal_manager.active_count == 0


def test_gateway_terminal_ws_requires_admin_role(tmp_path) -> None:
    db = HubDatabase(tmp_path / "gw.db")
    db.create_user(
        username="member",
        password="member-password-123",
        display_name="Member",
        role="member",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=True, can_delete=False)],
    )
    cfg = GatewayConfig(
        db_path=str(tmp_path / "gw.db"),
        signing_secret=TEST_SIGNING_SECRET,
        internal_secret=TEST_INTERNAL_SECRET,
        cookie_secure=False,
        nodes={"win": NodeConfig(name="Win", base_url="http://127.0.0.1:19999")},
    )
    app = create_gateway_app(cfg, db=db, enable_monitor=False)
    with TestClient(app) as client:
        login = client.post(
            "/api/v2/auth/login",
            json={"username": "member", "password": "member-password-123"},
        )
        assert login.status_code == 200
        token = login.json()["tokens"]["access_token"]

        with pytest.raises(WebSocketDisconnect) as exc:
            with client.websocket_connect(f"/ws/v2/nodes/win/terminal?token={token}"):
                pass
        assert exc.value.code == 4403
