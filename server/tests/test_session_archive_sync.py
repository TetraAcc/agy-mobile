"""Tests for desktop-synced session archiving, listing archived sessions, and restoring."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import httpx
from fastapi.testclient import TestClient

from agy_hub.agent.app import create_agent_app
from agy_hub.agent.config import AgentConfig
from agy_hub.common.sandbox import RootRegistry
from agy_hub.common.schemas import UserPermissionGrant
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.db import HubDatabase
from tests.conftest import FakeEngineProvider


def _create_state_db(db_path: Path, rows: list[tuple[str, str, str, str]]) -> None:
    conn = sqlite3.connect(str(db_path))
    try:
        conn.execute(
            """
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY,
                title TEXT,
                preview TEXT,
                workspace_uris TEXT,
                last_modified_time TEXT
            )
            """
        )
        conn.executemany(
            "INSERT INTO conversation_summaries (conversation_id, title, preview, workspace_uris, last_modified_time) "
            "VALUES (?, ?, ?, ?, ?)",
            rows,
        )
        conn.commit()
    finally:
        conn.close()


def test_archive_and_restore_syncs_desktop_annotations_and_rbac(tmp_path: Path) -> None:
    secret = "test-shared-secret-at-least-32-chars-long"
    brain_dir = tmp_path / "brain"
    scratch_dir = tmp_path / "scratch"
    ann_dir = tmp_path / "annotations"
    (brain_dir / "sess-1").mkdir(parents=True)
    (brain_dir / "sess-2").mkdir(parents=True)
    scratch_dir.mkdir()
    ann_dir.mkdir()

    # Existing desktop annotation file with extra fields that must be preserved
    (ann_dir / "sess-1.pbtxt").write_text(
        'title:"Session One" last_user_view_time:{seconds:1795633512 nanos:100} permission_preset:AGENT_PERMISSION_PRESET_TURBO',
        encoding="utf-8",
    )

    proj_a = tmp_path / "proj_a"
    proj_a.mkdir()
    state_db = tmp_path / "state.vscdb"
    _create_state_db(
        state_db,
        [
            ("sess-1", "Session One", "Preview 1", json.dumps([proj_a.resolve().as_uri()]), "2026-11-28T10:00:00Z"),
            ("sess-2", "Session Two", "Preview 2", "[]", "2026-11-27T10:00:00Z"),
        ],
    )

    agent_cfg = AgentConfig(internal_secret=secret, platform="windows")
    registry = RootRegistry()
    provider = FakeEngineProvider(agent_cfg, registry, brain_dir, state_db, scratch_dir)
    agent_app = create_agent_app(agent_cfg, provider=provider, registry=registry)
    http_client = httpx.AsyncClient(transport=httpx.ASGITransport(app=agent_app), base_url="http://agent.local")

    db = HubDatabase(tmp_path / "hub.db")
    db.create_user(
        username="editor",
        password="editor-password-123",
        display_name="Editor",
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
        v_login = client.post("/api/v2/auth/login", json={"username": "viewer", "password": "viewer-password-123"})
        v_hdr = {"Authorization": f"Bearer {v_login.json()['tokens']['access_token']}"}
        e_login = client.post("/api/v2/auth/login", json={"username": "editor", "password": "editor-password-123"})
        e_hdr = {"Authorization": f"Bearer {e_login.json()['tokens']['access_token']}"}

        # 1. Initially 2 active sessions, 0 archived
        tree0 = client.get("/api/v2/nodes/win/sessions", headers=e_hdr)
        assert tree0.status_code == 200
        assert tree0.json()["archived_count"] == 0
        assert len(tree0.json()["projects"]["proj_a"]) == 1

        # 2. Archive sess-1 via Gateway -> updates desktop annotations/sess-1.pbtxt
        del_resp = client.delete("/api/v2/nodes/win/sessions/sess-1", headers=e_hdr)
        assert del_resp.status_code == 200
        assert del_resp.json()["archived"] is True

        pbtxt = (ann_dir / "sess-1.pbtxt").read_text(encoding="utf-8")
        assert "archived:true" in pbtxt
        assert "archival_status_timestamp:" in pbtxt
        assert 'title:"Session One"' in pbtxt
        assert "AGENT_PERMISSION_PRESET_TURBO" in pbtxt

        # 3. Tree reflects archived_count=1 and excludes sess-1
        tree1 = client.get("/api/v2/nodes/win/sessions", headers=e_hdr)
        assert tree1.status_code == 200
        assert tree1.json()["archived_count"] == 1
        assert "proj_a" not in tree1.json()["projects"]

        # 4. Archived list returns sess-1; readonly viewer can read list, cannot restore
        arch_resp = client.get("/api/v2/nodes/win/sessions/archived", headers=v_hdr)
        assert arch_resp.status_code == 200
        arch_items = arch_resp.json()["items"]
        assert [i["id"] for i in arch_items] == ["sess-1"]
        assert arch_items[0]["project_name"] == "proj_a"

        assert client.post("/api/v2/nodes/win/sessions/sess-1/restore", headers=v_hdr).status_code == 403

        # 5. Editor restores sess-1 -> writes archived:false and clears local archive file
        rest_resp = client.post("/api/v2/nodes/win/sessions/sess-1/restore", headers=e_hdr)
        assert rest_resp.status_code == 200
        assert rest_resp.json()["archived"] is False

        pbtxt_after = (ann_dir / "sess-1.pbtxt").read_text(encoding="utf-8")
        assert "archived:false" in pbtxt_after
        assert "archived:true" not in pbtxt_after

        tree2 = client.get("/api/v2/nodes/win/sessions", headers=e_hdr)
        assert tree2.status_code == 200
        assert tree2.json()["archived_count"] == 0
        assert len(tree2.json()["projects"]["proj_a"]) == 1

        # 6. If legacy local archive JSON marks sess-2 archived, desktop explicit archived:false wins
        provider._save_archived_ids({"sess-2"})
        (ann_dir / "sess-2.pbtxt").write_text("archived:false", encoding="utf-8")
        tree3 = client.get("/api/v2/nodes/win/sessions", headers=e_hdr)
        assert tree3.status_code == 200
        assert [s["id"] for s in tree3.json()["general_sessions"]] == ["sess-2"]
        assert tree3.json()["archived_count"] == 0
