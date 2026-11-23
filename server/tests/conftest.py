"""Shared fixtures and fake engine provider for AGY Remote Hub v2.0 tests."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

import pytest

from agy_hub.agent.config import AgentConfig
from agy_hub.agent.providers.base import BaseEngineProvider
from agy_hub.common.sandbox import RootRegistry
from agy_hub.common.schemas import (
    ActionAckResponse,
    CreateSessionResponse,
    QuotaBucket,
    QuotaGroup,
    QuotaResponse,
)

TEST_SIGNING_SECRET = "test_signing_secret_minimum_32_characters_long_001"
TEST_INTERNAL_SECRET = "test_internal_secret_minimum_32_characters_long_002"


class FakeEngineProvider(BaseEngineProvider):
    """In-memory controllable provider backed by real filesystem brain/scratch & read-only SQLite."""

    platform_name = "windows"

    def __init__(self, config: AgentConfig, registry: RootRegistry, brain_dir: Path, db_path: Path, scratch_dir: Path) -> None:
        self._brain_dir = brain_dir.resolve()
        self._db_path = db_path.resolve()
        self._default_workspace = scratch_dir.resolve()
        self.engine_alive = True
        self.pinned_ids: set[str] = set()
        self.sent_messages: list[dict[str, Any]] = []
        self.created_sessions: list[dict[str, Any]] = []
        self.stopped_sessions: list[str] = []
        self.managed_running: set[str] = set()
        super().__init__(config, registry)

    @property
    def brain_dir(self) -> Path:
        return self._brain_dir

    @property
    def db_path(self) -> Path:
        return self._db_path

    @property
    def default_workspace(self) -> Path:
        return self._default_workspace

    def get_pinned_session_ids(self) -> set[str]:
        return set(self.pinned_ids)

    def is_managed_process_running(self, session_id: str) -> bool:
        return session_id in self.managed_running

    async def is_engine_alive(self) -> bool:
        return self.engine_alive

    async def send_message(
        self,
        session_id: str,
        content: str,
        model: str | None = None,
        workspace_path: str | None = None,
    ) -> ActionAckResponse:
        sid = self.validate_session_id(session_id)
        self.sent_messages.append(
            {"session_id": sid, "content": content, "model": model, "workspace_path": workspace_path}
        )
        return ActionAckResponse(ok=True, session_id=sid, message="Dispatched")

    async def create_session(
        self,
        content: str,
        model: str | None = None,
        mode: str = "auto",
        workspace_path: str | None = None,
    ) -> CreateSessionResponse:
        new_id = "11111111-1111-4111-8111-111111111199"
        self.created_sessions.append(
            {"content": content, "model": model, "mode": mode, "workspace_path": workspace_path}
        )
        return CreateSessionResponse(ok=True, session_id=new_id, message=f"Created ({mode})")

    async def stop_session(self, session_id: str) -> ActionAckResponse:
        sid = self.validate_session_id(session_id)
        self.stopped_sessions.append(sid)
        self.managed_running.discard(sid)
        return ActionAckResponse(ok=True, session_id=sid, message="Stopped")

    async def fetch_quota(self) -> QuotaResponse:
        return QuotaResponse(
            groups=[
                QuotaGroup(
                    display_name="Gemini",
                    buckets=[
                        QuotaBucket(
                            bucket_id="5h",
                            display_name="5h",
                            window="5h",
                            remaining_fraction=0.85,
                            reset_time="2026-11-23T06:00:00Z",
                        )
                    ],
                )
            ],
            description="Test quota",
        )


def write_transcript_step(
    brain_dir: Path,
    session_id: str,
    step: dict[str, Any],
    append: bool = True,
    newline: bool = True,
) -> Path:
    tpath = brain_dir / session_id / ".system_generated" / "logs" / "transcript.jsonl"
    tpath.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if append else "w"
    raw = json.dumps(step, ensure_ascii=False) + ("\n" if newline else "")
    with open(tpath, mode, encoding="utf-8") as f:
        f.write(raw)
    return tpath


def create_sample_official_db(db_path: Path, workspace_dir: Path) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    try:
        conn.executescript(
            """
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY,
                title TEXT,
                preview TEXT,
                workspace_uris TEXT,
                last_modified_time TEXT,
                project_id TEXT,
                parent_conversation_id TEXT,
                nesting_depth INTEGER,
                agent_name TEXT,
                status TEXT,
                not_fully_idle INTEGER
            );
            CREATE TABLE conversations_fts (
                conversation_id TEXT,
                project TEXT
            );
            """
        )
        ws_uri = json.dumps([workspace_dir.resolve().as_uri()])
        rows = [
            (
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
                "主项目重构",
                "进行中...",
                ws_uri,
                "2026-11-23T01:00:00Z",
                "proj-alpha",
                "",
                0,
                "",
                "CASCADE_RUN_STATUS_RUNNING",
                1,
            ),
            (
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2",
                "通用讨论",
                "你好",
                "[]",
                "2026-11-22T12:00:00Z",
                "outside-of-project",
                None,
                0,
                None,
                "CASCADE_RUN_STATUS_IDLE",
                0,
            ),
            (
                # Subagent should be filtered out
                "cccccccc-cccc-4ccc-8ccc-ccccccccccc3",
                "内部子代理任务",
                "",
                ws_uri,
                "2026-11-23T01:10:00Z",
                "proj-alpha",
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
                1,
                "research",
                "CASCADE_RUN_STATUS_IDLE",
                0,
            ),
            (
                # Orphan (no disk folder) should be filtered in memory WITHOUT DELETE from DB
                "dddddddd-dddd-4ddd-8ddd-ddddddddddd4",
                "磁盘已删除的孤儿会话",
                "",
                ws_uri,
                "2026-11-21T08:00:00Z",
                "proj-alpha",
                "",
                0,
                "",
                "CASCADE_RUN_STATUS_IDLE",
                0,
            ),
        ]
        conn.executemany(
            """
            INSERT INTO conversation_summaries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        conn.execute(
            "INSERT INTO conversations_fts VALUES (?, ?)",
            ("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1", "MySpecialProject"),
        )
        conn.commit()
    finally:
        conn.close()


@pytest.fixture
def tmp_agent_env(tmp_path: Path) -> dict[str, Any]:
    brain_dir = tmp_path / "brain"
    brain_dir.mkdir()
    scratch_dir = tmp_path / "scratch"
    scratch_dir.mkdir()
    proj_dir = scratch_dir / "demo_project"
    proj_dir.mkdir()
    db_path = tmp_path / "conversation_summaries.db"
    create_sample_official_db(db_path, proj_dir)

    # Create disk dirs only for session 1 and 2 (and subagent 3), leaving 4 as orphan
    for sid in (
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2",
        "cccccccc-cccc-4ccc-8ccc-ccccccccccc3",
    ):
        (brain_dir / sid / ".system_generated" / "logs").mkdir(parents=True, exist_ok=True)

    write_transcript_step(
        brain_dir,
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
        {"step_index": 1, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE", "content": "<USER_REQUEST>开始重构</USER_REQUEST>"},
    )
    write_transcript_step(
        brain_dir,
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
        {
            "step_index": 2,
            "source": "MODEL",
            "type": "PLANNER_RESPONSE",
            "status": "DONE",
            "content": "好的，正在分析。",
            "thinking": "检查结构",
            "tool_calls": [{"function": {"name": "read_file", "arguments": '{"Path": "README.md"}'}}],
        },
    )

    cfg = AgentConfig(
        platform="windows",
        host="127.0.0.1",
        port=8765,
        internal_secret=TEST_INTERNAL_SECRET,
        roots={"scratch": str(scratch_dir)},
        brain_dir=str(brain_dir),
        db_path=str(db_path),
        default_workspace=str(scratch_dir),
        archive_file=str(tmp_path / "archived.json"),
        poll_interval_seconds=0.05,
    )
    registry = RootRegistry()
    provider = FakeEngineProvider(cfg, registry, brain_dir=brain_dir, db_path=db_path, scratch_dir=scratch_dir)
    return {
        "tmp_path": tmp_path,
        "brain_dir": brain_dir,
        "scratch_dir": scratch_dir,
        "proj_dir": proj_dir,
        "db_path": db_path,
        "config": cfg,
        "registry": registry,
        "provider": provider,
    }
