"""Tests for server-side persistent per-session message queue and dispatch control."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.agent.message_queue import SessionMessageQueueManager
from agy_hub.common.security import sign_internal_request
from tests.conftest import TEST_INTERNAL_SECRET


def _signed_headers(method: str, path: str, *, can_write: bool = True) -> dict[str, str]:
    perms = json.dumps({"can_write": can_write, "can_delete": can_write}, separators=(",", ":"), sort_keys=True)
    return sign_internal_request(TEST_INTERNAL_SECRET, method, path, "tester", perms)


def test_agent_queue_endpoints_crud_stop_pause_and_readonly(tmp_agent_env: dict) -> None:
    provider = tmp_agent_env["provider"]
    sid = "33333333-3333-4333-8333-333333333331"
    provider.managed_running.add(sid)

    app = create_agent_app(
        tmp_agent_env["config"],
        provider=provider,
        registry=tmp_agent_env["registry"],
    )
    with TestClient(app) as client:
        msg_path = f"/agent/sessions/{sid}/messages"
        q_path = f"/agent/sessions/{sid}/queue"

        # 1. delivery_mode="queue" while running -> enqueued instead of sent
        r1 = client.post(
            msg_path,
            headers=_signed_headers("POST", msg_path),
            json={"content": "第一条排队消息", "delivery_mode": "queue"},
        )
        assert r1.status_code == 200
        assert r1.json()["queued"] is True
        assert r1.json()["queue_position"] == 1

        r2 = client.post(
            msg_path,
            headers=_signed_headers("POST", msg_path),
            json={"content": "第二条排队消息", "delivery_mode": "queue"},
        )
        assert r2.status_code == 200
        assert r2.json()["queued"] is True
        assert r2.json()["queue_position"] == 2
        assert provider.sent_messages == []

        # 2. delivery_mode="immediate" while running -> dispatches immediately
        r_imm = client.post(
            msg_path,
            headers=_signed_headers("POST", msg_path),
            json={"content": "插队直发消息", "delivery_mode": "immediate"},
        )
        assert r_imm.status_code == 200
        assert r_imm.json()["queued"] is False
        assert [m["content"] for m in provider.sent_messages] == ["插队直发消息"]

        # 3. Inspect queue & edit first item
        q_resp = client.get(q_path, headers=_signed_headers("GET", q_path))
        assert q_resp.status_code == 200
        q_data = q_resp.json()
        assert len(q_data["items"]) == 2
        assert q_data["paused"] is False
        first_id = q_data["items"][0]["id"]
        second_id = q_data["items"][1]["id"]

        edit_path = f"{q_path}/{first_id}"
        edit_resp = client.put(
            edit_path,
            headers=_signed_headers("PUT", edit_path),
            json={"content": "第一条修改后"},
        )
        assert edit_resp.status_code == 200
        assert edit_resp.json()["items"][0]["content"] == "第一条修改后"

        # 4. Stop active session -> auto-pauses non-empty queue
        stop_path = f"/agent/sessions/{sid}/stop"
        stop_resp = client.post(stop_path, headers=_signed_headers("POST", stop_path))
        assert stop_resp.status_code == 200

        q_after_stop = client.get(q_path, headers=_signed_headers("GET", q_path)).json()
        assert q_after_stop["paused"] is True

        # 5. Send second item immediately -> removes from queue and dispatches
        now_path = f"{q_path}/{second_id}/send-now"
        now_resp = client.post(now_path, headers=_signed_headers("POST", now_path))
        assert now_resp.status_code == 200
        assert provider.sent_messages[-1]["content"] == "第二条排队消息"
        assert len(client.get(q_path, headers=_signed_headers("GET", q_path)).json()["items"]) == 1

        # 6. Read-only caller rejected with 403 on mutations
        pause_path = f"{q_path}/pause"
        assert (
            client.post(
                pause_path,
                headers=_signed_headers("POST", pause_path, can_write=False),
                json={"paused": False},
            ).status_code
            == 403
        )
        assert (
            client.delete(
                q_path,
                headers=_signed_headers("DELETE", q_path, can_write=False),
            ).status_code
            == 403
        )

        # 7. Delete remaining item -> clears paused state cleanly
        del_resp = client.delete(edit_path, headers=_signed_headers("DELETE", edit_path))
        assert del_resp.status_code == 200
        assert del_resp.json()["items"] == []
        assert del_resp.json()["paused"] is False


@pytest.mark.asyncio
async def test_queue_persistence_and_fifo_auto_dispatch(tmp_agent_env: dict) -> None:
    provider = tmp_agent_env["provider"]
    sid = "33333333-3333-4333-8333-333333333332"
    provider.managed_running.add(sid)

    qm1 = SessionMessageQueueManager(provider, poll_interval=0.03, cooldown_seconds=0.02)
    await qm1.enqueue(sid, "第一步")
    await qm1.enqueue(sid, "第二步")
    await qm1.shutdown()

    # Recreate from persisted JSON on disk and verify FIFO dispatch once engine is idle
    qm2 = SessionMessageQueueManager(provider, poll_interval=0.03, cooldown_seconds=0.02)
    assert [i.content for i in qm2.get_queue(sid).items] == ["第一步", "第二步"]

    qm2.start()
    try:
        # While still running, nothing should dispatch
        await asyncio.sleep(0.08)
        assert provider.sent_messages == []

        # Mark idle -> dispatches both in order
        provider.managed_running.discard(sid)
        for _ in range(30):
            if len(provider.sent_messages) == 2:
                break
            await asyncio.sleep(0.03)
        assert [m["content"] for m in provider.sent_messages] == ["第一步", "第二步"]
        assert qm2.get_queue(sid).items == []
    finally:
        await qm2.shutdown()
