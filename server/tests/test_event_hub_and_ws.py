"""Tests for SessionEventHub WebSocket isolation, late-created transcript files, partial lines, and ping/pong."""

from __future__ import annotations

import json
import time
from pathlib import Path

from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.common.security import sign_internal_request
from tests.conftest import TEST_INTERNAL_SECRET, write_transcript_step


def _ws_headers() -> dict[str, str]:
    return sign_internal_request(
        TEST_INTERNAL_SECRET,
        "GET",
        "/agent/ws/events",
        "ws_tester",
        '{"can_write":true,"can_delete":false}',
    )


def test_ws_session_isolation_late_file_and_partial_line(tmp_agent_env: dict) -> None:
    brain_dir: Path = tmp_agent_env["brain_dir"]
    sid_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
    sid_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"
    sid_late = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee5"

    app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )

    with TestClient(app) as client:
        with client.websocket_connect("/agent/ws/events", headers=_ws_headers()) as ws_a:
            with client.websocket_connect("/agent/ws/events", headers=_ws_headers()) as ws_b:
                # Subscribe A to sid_a, B to sid_b
                ws_a.send_json({"type": "subscribe", "session_id": sid_a})
                ws_b.send_json({"type": "subscribe", "session_id": sid_b})

                status_a = ws_a.receive_json()
                status_b = ws_b.receive_json()
                assert status_a["type"] == "session_status" and status_a["session_id"] == sid_a
                assert status_b["type"] == "session_status" and status_b["session_id"] == sid_b

                # Ping / Pong check
                ws_a.send_json({"type": "ping"})
                assert ws_a.receive_json()["type"] == "pong"

                # Write step to sid_a -> only ws_a gets it
                write_transcript_step(
                    brain_dir,
                    sid_a,
                    {"step_index": 3, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "content": "Only for A"},
                )
                evt_a = ws_a.receive_json()
                assert evt_a["type"] == "step_upsert"
                assert evt_a["session_id"] == sid_a
                assert evt_a["step"]["content"] == "Only for A"

                # Verify ws_b receives only sid_b updates when sid_b is written (never sid_a)
                write_transcript_step(
                    brain_dir,
                    sid_b,
                    {"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "content": "Only for B"},
                )
                evt_b = ws_b.receive_json()
                assert evt_b["type"] == "step_upsert"
                assert evt_b["session_id"] == sid_b
                assert evt_b["step"]["content"] == "Only for B"

                # Subscribe to a brand new session whose transcript.jsonl does not exist yet
                ws_a.send_json({"type": "unsubscribe", "session_id": sid_a})
                ws_a.send_json({"type": "subscribe", "session_id": sid_late})
                late_status = ws_a.receive_json()
                assert late_status["type"] == "session_status" and late_status["session_id"] == sid_late

                # Allow watcher loop to spin several times while file doesn't exist (no NoneType crash)
                time.sleep(0.2)

                # Write partial JSON line (no trailing newline), wait, then complete it
                late_tpath = brain_dir / sid_late / ".system_generated" / "logs" / "transcript.jsonl"
                late_tpath.parent.mkdir(parents=True, exist_ok=True)
                full_line = json.dumps(
                    {"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "content": "Late arrived"}
                )
                half = len(full_line) // 2
                late_tpath.write_text(full_line[:half], encoding="utf-8")
                time.sleep(0.15)
                with open(late_tpath, "a", encoding="utf-8") as f:
                    f.write(full_line[half:] + "\n")

                evt_late = ws_a.receive_json()
                assert evt_late["type"] == "step_upsert"
                assert evt_late["session_id"] == sid_late
                assert evt_late["step"]["content"] == "Late arrived"


def test_full_transcript_prevents_content_truncation_in_http_and_ws(tmp_agent_env: dict) -> None:
    brain_dir: Path = tmp_agent_env["brain_dir"]
    sid = "ffffffff-ffff-4fff-8fff-fffffffffff6"
    logs_dir = brain_dir / sid / ".system_generated" / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    compact_path = logs_dir / "transcript.jsonl"
    full_path = logs_dir / "transcript_full.jsonl"

    full_reply_1 = "第一段完整分析。\n" + ("核心细节说明——绝不应被腰斩。" * 120) + "\n最后总结段。"
    compact_reply_1 = "第一段完整分析。\n<truncated 1209 bytes>\n最后总结段。"

    step1_compact = {
        "step_index": 1,
        "source": "MODEL",
        "type": "PLANNER_RESPONSE",
        "status": "DONE",
        "content": compact_reply_1,
        "truncated_fields": ["content"],
    }
    step1_full = {
        "step_index": 1,
        "source": "MODEL",
        "type": "PLANNER_RESPONSE",
        "status": "DONE",
        "content": full_reply_1,
    }
    compact_path.write_text(json.dumps(step1_compact, ensure_ascii=False) + "\n", encoding="utf-8")
    full_path.write_text(json.dumps(step1_full, ensure_ascii=False) + "\n", encoding="utf-8")

    app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )

    msg_headers = sign_internal_request(
        TEST_INTERNAL_SECRET,
        "GET",
        f"/agent/sessions/{sid}/messages",
        "ws_tester",
        '{"can_write":true,"can_delete":false}',
    )

    with TestClient(app) as client:
        # 1. HTTP 历史消息应读取 transcript_full.jsonl 中的完整回复而非紧凑截断版
        resp = client.get(f"/agent/sessions/{sid}/messages", headers=msg_headers)
        assert resp.status_code == 200
        msgs = resp.json()["messages"]
        assert len(msgs) == 1
        assert "<truncated" not in msgs[0]["content"]
        assert msgs[0]["content"] == full_reply_1

        # 2. WebSocket 实时订阅新追加的长回复同样返回完整无截断正文
        with client.websocket_connect("/agent/ws/events", headers=_ws_headers()) as ws:
            ws.send_json({"type": "subscribe", "session_id": sid})
            status_evt = ws.receive_json()
            assert status_evt["type"] == "session_status"

            full_reply_2 = "第二轮开头。\n" + ("完整技术方案展开内容。" * 130) + "\n第二轮收尾。"
            step2_compact = {
                "step_index": 2,
                "source": "MODEL",
                "type": "PLANNER_RESPONSE",
                "status": "DONE",
                "content": "第二轮开头。\n<truncated 1500 bytes>\n第二轮收尾。",
                "truncated_fields": ["content"],
            }
            step2_full = {
                "step_index": 2,
                "source": "MODEL",
                "type": "PLANNER_RESPONSE",
                "status": "DONE",
                "content": full_reply_2,
            }
            with open(compact_path, "a", encoding="utf-8") as fc:
                fc.write(json.dumps(step2_compact, ensure_ascii=False) + "\n")
            with open(full_path, "a", encoding="utf-8") as ff:
                ff.write(json.dumps(step2_full, ensure_ascii=False) + "\n")

            live_evt = ws.receive_json()
            assert live_evt["type"] == "step_upsert"
            assert live_evt["step"]["step_index"] == 2
            assert "<truncated" not in live_evt["step"]["content"]
            assert live_evt["step"]["content"] == full_reply_2
