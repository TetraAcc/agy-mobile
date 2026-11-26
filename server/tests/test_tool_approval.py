"""Tests for interactive tool approval parsing, Connect-RPC payloads, endpoints, WS events, and notifications."""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.agent.approvals import build_user_interaction_payload, extract_pending_approvals
from agy_hub.agent.config import AgentConfig
from agy_hub.agent.providers.windows import WindowsEngineProvider
from agy_hub.common.sandbox import RootRegistry
from agy_hub.common.schemas import ApprovalDecisionRequest
from agy_hub.common.security import sign_internal_request
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.notifier import DiscordNotificationMonitor
from agy_hub.gateway.registry import NodeRegistryManager
from tests.conftest import TEST_INTERNAL_SECRET, TEST_SIGNING_SECRET


def test_extract_and_build_all_interaction_types() -> None:
    sid = "11111111-1111-4111-8111-111111111111"
    tid = "traj-main-001"
    steps = [
        # Step 40 (with base_step_offset=40): Permissions v2 runCommand with ONCE-only scope filter
        {
            "type": "CORTEX_STEP_TYPE_RUN_COMMAND",
            "status": "CORTEX_STEP_STATUS_WAITING",
            "metadata": {"createdAt": "2026-11-26T03:00:00Z"},
            "runCommand": {
                "proposedCommandLine": "rm -rf ./tmp_cache",
                "cwd": r"C:\repo\app",
                "shellName": "pwsh",
            },
            "requestedInteraction": {
                "permission": {
                    "resource": {"action": "command", "target": "rm -rf ./tmp_cache"},
                    "actionDescription": "Run shell command",
                    "reason": "该命令包含破坏性删除操作",
                    "approvalScopeFilter": ["PERMISSION_SCOPE_ONCE"],
                    "persistSuggestionType": "PERSIST_SUGGESTION_TYPE_BLOCKED",
                }
            },
        },
        # Step 41: Legacy FilePermissionInteractionSpec
        {
            "type": "CORTEX_STEP_TYPE_VIEW_FILE",
            "status": "CORTEX_STEP_STATUS_WAITING",
            "requestedInteraction": {
                "filePermission": {
                    "absolutePathUri": "file:///D:/external/secrets_note.txt",
                    "isDirectory": False,
                    "blockReason": "BLOCK_REASON_OUTSIDE_WORKSPACE",
                }
            },
        },
        # Step 42: Legacy MCP tool confirmation
        {
            "type": "CORTEX_STEP_TYPE_MCP_TOOL",
            "status": "CORTEX_STEP_STATUS_WAITING",
            "mcpTool": {
                "serverName": "github",
                "toolCall": {"name": "create_issue", "argumentsJson": '{"title":"Bug"}'},
            },
            "requestedInteraction": {"mcp": {}},
        },
        # Step 43: AskQuestion must NOT show up as a tool approval item
        {
            "type": "CORTEX_STEP_TYPE_ASK_QUESTION",
            "status": "CORTEX_STEP_STATUS_WAITING",
            "requestedInteraction": {"askQuestion": {"questions": [{"question": "Pick A or B"}]}},
        },
        # Step 44: Subagent nested subtrajectory waiting on runCommand
        {
            "type": "CORTEX_STEP_TYPE_INVOKE_SUBAGENT",
            "status": "CORTEX_STEP_STATUS_RUNNING",
            "subtrajectory": {
                "trajectoryId": "traj-sub-999",
                "steps": [
                    {
                        "type": "CORTEX_STEP_TYPE_RUN_COMMAND",
                        "status": "CORTEX_STEP_STATUS_WAITING",
                        "runCommand": {"proposedCommandLine": "git status", "cwd": "/repo"},
                        "requestedInteraction": {"runCommand": {}},
                    }
                ],
            },
        },
    ]

    approvals = extract_pending_approvals(
        steps,
        session_id=sid,
        trajectory_id=tid,
        base_step_offset=40,
    )
    assert len(approvals) == 4

    # 1. Permission v2 command
    cmd_item = approvals[0]
    assert cmd_item.step_index == 40
    assert cmd_item.trajectory_id == tid
    assert cmd_item.category == "command"
    assert cmd_item.raw_interaction_field == "permission"
    assert cmd_item.cwd == r"C:\repo\app"
    assert cmd_item.shell_name == "pwsh"
    assert cmd_item.allowed_scopes == ["once"]
    assert cmd_item.can_remember is False
    assert cmd_item.editable_command is True

    # Verify disallowed scope raises ValueError
    with pytest.raises(ValueError, match="不允许|不支持"):
        build_user_interaction_payload(
            steps[0],
            trajectory_id=tid,
            step_index=40,
            decision=ApprovalDecisionRequest(
                trajectory_id=tid,
                step_index=40,
                interaction_field="permission",
                decision="allow",
                scope="workspace",
            ),
        )

    # Verify deny with instruction
    deny_payload = build_user_interaction_payload(
        steps[0],
        trajectory_id=tid,
        step_index=40,
        decision=ApprovalDecisionRequest(
            trajectory_id=tid,
            step_index=40,
            interaction_field="permission",
            decision="deny",
            deny_reason="不要删除缓存目录",
        ),
    )
    assert deny_payload == {
        "trajectoryId": tid,
        "stepIndex": 40,
        "permission": {
            "allow": False,
            "scope": "PERMISSION_SCOPE_ONCE",
            "userDenyInstruction": "不要删除缓存目录",
        },
    }

    # 2. File permission
    file_item = approvals[1]
    assert file_item.step_index == 41
    assert file_item.category == "file"
    assert file_item.can_remember is True
    assert "工作区之外" in file_item.reason
    file_payload = build_user_interaction_payload(
        steps[1],
        trajectory_id=tid,
        step_index=41,
        decision=ApprovalDecisionRequest(
            trajectory_id=tid,
            step_index=41,
            interaction_field="filePermission",
            decision="allow",
            scope="conversation",
        ),
    )
    assert file_payload == {
        "trajectoryId": tid,
        "stepIndex": 41,
        "filePermission": {
            "allow": True,
            "scope": "PERMISSION_SCOPE_CONVERSATION",
            "absolutePathUri": "file:///D:/external/secrets_note.txt",
        },
    }

    # 3. MCP tool
    mcp_item = approvals[2]
    assert mcp_item.step_index == 42
    assert mcp_item.category == "mcp"
    assert mcp_item.target == "github/create_issue"
    assert mcp_item.detail["arguments_json"] == '{"title":"Bug"}'
    mcp_payload = build_user_interaction_payload(
        steps[2],
        trajectory_id=tid,
        step_index=42,
        decision=ApprovalDecisionRequest(
            trajectory_id=tid,
            step_index=42,
            interaction_field="mcp",
            decision="allow",
        ),
    )
    assert mcp_payload == {"trajectoryId": tid, "stepIndex": 42, "mcp": {"confirm": True}}

    # 4. Nested subtrajectory runCommand with edited command
    sub_item = approvals[3]
    assert sub_item.trajectory_id == "traj-sub-999"
    assert sub_item.step_index == 0
    sub_payload = build_user_interaction_payload(
        steps[4]["subtrajectory"]["steps"][0],
        trajectory_id="traj-sub-999",
        step_index=0,
        decision=ApprovalDecisionRequest(
            trajectory_id="traj-sub-999",
            step_index=0,
            interaction_field="runCommand",
            decision="allow",
            edited_target="git status -sb",
        ),
    )
    assert sub_payload == {
        "trajectoryId": "traj-sub-999",
        "stepIndex": 0,
        "runCommand": {
            "confirm": True,
            "proposedCommandLine": "git status",
            "submittedCommandLine": "git status -sb",
            "sandboxOverride": False,
        },
    }


def _make_signed_headers(method: str, path: str, *, can_write: bool = True) -> dict[str, str]:
    perms = json.dumps({"can_write": can_write, "can_delete": False})
    return sign_internal_request(TEST_INTERNAL_SECRET, method, path, "tester", perms)


def test_windows_provider_endpoints_ws_and_rbac(tmp_path: Path) -> None:
    brain_dir = tmp_path / "brain"
    daemon_dir = tmp_path / "daemon"
    scratch = tmp_path / "scratch"
    brain_dir.mkdir(parents=True)
    daemon_dir.mkdir(parents=True)
    scratch.mkdir(parents=True)
    db_path = tmp_path / "conversation_summaries.db"
    conn = sqlite3.connect(db_path)
    conn.execute("CREATE TABLE conversations (id TEXT PRIMARY KEY, status TEXT)")
    sid = "22222222-2222-4222-8222-222222222222"
    conn.execute("INSERT INTO conversations (id, status) VALUES (?, ?)", (sid, "CASCADE_RUN_STATUS_RUNNING"))
    conn.commit()
    conn.close()

    (brain_dir / sid).mkdir()
    (brain_dir / sid / "transcript.jsonl").write_text(
        json.dumps({"step_index": 0, "source": "USER", "type": "USER_INPUT", "status": "DONE", "content": "hi"}) + "\n",
        encoding="utf-8",
    )

    # Point daemon discovery to a reachable mock port file
    (daemon_dir / "hub_19999.json").write_text(
        json.dumps({"port": 19999, "csrfToken": "csrf-xyz"}),
        encoding="utf-8",
    )

    state: dict[str, Any] = {
        "waiting": True,
        "rpc_calls": [],
    }

    def rpc_handler(request: httpx.Request) -> httpx.Response:
        method = request.url.path.rsplit("/", 1)[-1]
        body = json.loads(request.content.decode("utf-8")) if request.content else {}
        state["rpc_calls"].append((method, body))
        if method == "GetAllCascadeTrajectories":
            return httpx.Response(
                200,
                json={
                    "trajectorySummaries": {
                        sid: {
                            "trajectoryId": "traj-win-1",
                            "stepCount": 2,
                            "status": "CASCADE_RUN_STATUS_RUNNING",
                        }
                    }
                },
            )
        if method == "GetCascadeTrajectorySteps":
            step1: dict[str, Any] = {
                "type": "CORTEX_STEP_TYPE_RUN_COMMAND",
                "status": "CORTEX_STEP_STATUS_WAITING" if state["waiting"] else "CORTEX_STEP_STATUS_DONE",
                "runCommand": {"proposedCommandLine": "npm test", "cwd": str(scratch)},
            }
            if state["waiting"]:
                step1["requestedInteraction"] = {
                    "permission": {
                        "resource": {"action": "command", "target": "npm test"},
                        "actionDescription": "Run tests",
                        "reason": "确认执行测试命令",
                    }
                }
            return httpx.Response(
                200,
                json={
                    "steps": [
                        {"type": "CORTEX_STEP_TYPE_USER_INPUT", "status": "CORTEX_STEP_STATUS_DONE"},
                        step1,
                    ]
                },
            )
        if method == "HandleCascadeUserInteraction":
            state["waiting"] = False
            return httpx.Response(200, json={})
        return httpx.Response(404, json={"error": f"Unknown {method}"})

    mock_http = httpx.AsyncClient(transport=httpx.MockTransport(rpc_handler))
    cfg = AgentConfig(
        platform="windows",
        internal_secret=TEST_INTERNAL_SECRET,
        brain_dir=str(brain_dir),
        db_path=str(db_path),
        daemon_dir=str(daemon_dir),
        default_workspace=str(scratch),
        poll_interval_seconds=0.05,
    )
    reg = RootRegistry({"scratch": scratch})
    provider = WindowsEngineProvider(cfg, reg, http_client=mock_http)
    # Bypass TCP socket connect probe in unit test
    provider._discover_hub_sync = lambda: {"port": 19999, "csrf_token": "csrf-xyz", "pid": 1234}  # type: ignore[method-assign]

    app = create_agent_app(cfg, provider=provider, registry=reg)
    with TestClient(app) as client:
        # 1. GET /messages embeds pending_approvals
        msg_path = f"/agent/sessions/{sid}/messages"
        r_msg = client.get(msg_path, headers=_make_signed_headers("GET", msg_path))
        assert r_msg.status_code == 200
        body_msg = r_msg.json()
        assert body_msg["supports_tool_approval"] is True
        assert len(body_msg["pending_approvals"]) == 1
        assert body_msg["pending_approvals"][0]["target"] == "npm test"
        assert body_msg["pending_approvals"][0]["can_remember"] is True

        # 2. Read-only caller cannot POST /approvals/resolve -> 403
        resolve_path = f"/agent/sessions/{sid}/approvals/resolve"
        req_payload = json.dumps({
            "trajectory_id": "traj-win-1",
            "step_index": 1,
            "interaction_field": "permission",
            "decision": "allow",
            "scope": "conversation",
        }).encode("utf-8")
        r_ro = client.post(
            resolve_path,
            content=req_payload,
            headers={**_make_signed_headers("POST", resolve_path, can_write=False), "Content-Type": "application/json"},
        )
        assert r_ro.status_code == 403

        # 3. WebSocket initial subscribe pushes approvals_changed, then resolving broadcasts cleared list
        ws_path = "/agent/ws/events"
        with client.websocket_connect(ws_path, headers=_make_signed_headers("GET", ws_path)) as ws:
            ws.send_json({"type": "subscribe", "session_id": sid})
            ev1 = ws.receive_json()
            assert ev1["type"] == "session_status"
            ev2 = ws.receive_json()
            assert ev2["type"] == "approvals_changed"
            assert len(ev2["approvals"]) == 1

            r_ok = client.post(
                resolve_path,
                content=req_payload,
                headers={**_make_signed_headers("POST", resolve_path, can_write=True), "Content-Type": "application/json"},
            )
            assert r_ok.status_code == 200
            res_json = r_ok.json()
            assert res_json["ok"] is True
            assert res_json["remaining_approvals"] == []

            ev3 = ws.receive_json()
            assert ev3["type"] == "approvals_changed"
            assert ev3["approvals"] == []

        rpc_interactions = [b for m, b in state["rpc_calls"] if m == "HandleCascadeUserInteraction"]
        assert len(rpc_interactions) == 1
        assert rpc_interactions[0] == {
            "cascadeId": sid,
            "interaction": {
                "trajectoryId": "traj-win-1",
                "stepIndex": 1,
                "permission": {
                    "allow": True,
                    "scope": "PERMISSION_SCOPE_CONVERSATION",
                },
            },
        }


@pytest.mark.asyncio
async def test_discord_notifier_sends_tool_approval_alert(tmp_path: Path) -> None:
    sid = "33333333-3333-4333-8333-333333333333"
    posted: list[dict[str, Any]] = []
    clock = [100.0]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/internal/health":
            return httpx.Response(200, json={"status": "healthy", "engine_alive": True})
        if request.url.path == "/agent/sessions":
            return httpx.Response(
                200,
                json={
                    "projects": {
                        "projA": [
                            {"id": sid, "title": "修复构建", "is_running": True},
                        ]
                    },
                    "general_sessions": [],
                    "running_session_ids": [sid],
                },
            )
        if request.url.path == f"/agent/sessions/{sid}/messages":
            return httpx.Response(
                200,
                json={
                    "session_id": sid,
                    "messages": [],
                    "is_running": True,
                    "pending_approvals": [
                        {
                            "approval_id": "traj-1:5:permission",
                            "session_id": sid,
                            "trajectory_id": "traj-1",
                            "step_index": 5,
                            "interaction_kind": "permission",
                            "raw_interaction_field": "permission",
                            "title": "终端命令权限审批",
                            "action_label": "Run command",
                            "target": "flutter test",
                        }
                    ],
                },
            )
        return httpx.Response(404)

    async def fake_webhook(_url: str, payload: dict[str, Any]) -> tuple[bool, str]:
        posted.append(payload)
        return True, ""

    gw_cfg = GatewayConfig(
        db_path=str(tmp_path / "hub.db"),
        signing_secret=TEST_SIGNING_SECRET,
        internal_secret=TEST_INTERNAL_SECRET,
        discord_webhook_url="https://discord.com/api/webhooks/1/abc",
        notify_ask_question_delay_seconds=5.0,
        nodes={
            "win": NodeConfig(
                id="win",
                name="Windows PC",
                platform="windows",
                base_url="http://node.local",
                enabled=True,
            )
        },
    )
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        reg = NodeRegistryManager(gw_cfg.nodes, http_client=client)
        await reg.probe_all()
        assert reg.is_node_online("win")

        monitor = DiscordNotificationMonitor(
            gw_cfg,
            reg,
            http_client=client,
            webhook_sender=fake_webhook,
            time_fn=lambda: clock[0],
        )

        await monitor.poll_once()
        assert len(posted) == 0

        clock[0] = 106.0
        await monitor.poll_once()
        assert len(posted) == 1
        embed = posted[0]["embeds"][0]
        assert "等待工具审批" in embed["title"]
        assert "flutter test" in embed["description"]

        # Should not duplicate on subsequent polls for same approval_id
        clock[0] = 115.0
        await monitor.poll_once()
        assert len(posted) == 1
