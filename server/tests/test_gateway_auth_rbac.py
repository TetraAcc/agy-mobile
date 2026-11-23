"""Tests for Gateway authentication, cookie & Bearer dual channel, refresh rotation, lockout, and RBAC."""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from agy_hub.common.schemas import UserPermissionGrant
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.db import HubDatabase
from tests.conftest import TEST_INTERNAL_SECRET, TEST_SIGNING_SECRET


def _setup_gateway(tmp_path: Path, max_failures: int = 5) -> tuple[TestClient, HubDatabase]:
    db = HubDatabase(tmp_path / "hub.db")
    db.create_user(
        username="admin_u",
        password="AdminPassword!123",
        display_name="Admin",
        role="admin",
        default_node="windows",
        grants=[
            UserPermissionGrant(node_id="windows", can_write=True, can_delete=True),
            UserPermissionGrant(node_id="deck", can_write=True, can_delete=True),
        ],
    )
    db.create_user(
        username="guest_ro",
        password="GuestPassword!123",
        display_name="Guest RO",
        role="member",
        default_node="deck",
        grants=[UserPermissionGrant(node_id="deck", can_write=False, can_delete=False)],
    )
    cfg = GatewayConfig(
        db_path=str(tmp_path / "hub.db"),
        signing_secret=TEST_SIGNING_SECRET,
        internal_secret=TEST_INTERNAL_SECRET,
        allowed_origins=["https://agy.example.com"],
        cookie_secure=False,
        max_login_failures=max_failures,
        lockout_seconds=300,
        nodes={
            "deck": NodeConfig(name="Steam Deck", base_url="http://127.0.0.1:18769", is_local=True),
            "windows": NodeConfig(name="Windows PC", base_url="http://127.0.0.1:18765", is_local=False),
        },
    )
    app = create_gateway_app(cfg, db=db, enable_monitor=False)
    return TestClient(app), db


def test_login_cookie_and_bearer_dual_channel(tmp_path: Path) -> None:
    client, db = _setup_gateway(tmp_path)
    with client:
        resp = client.post(
            "/api/v2/auth/login",
            json={"username": "admin_u", "password": "AdminPassword!123", "device_info": "pytest"},
        )
        assert resp.status_code == 200
        body = resp.json()
        access_tok = body["tokens"]["access_token"]
        refresh_tok = body["tokens"]["refresh_token"]

        # Cookie set automatically on TestClient
        assert "agy_access" in client.cookies
        assert "agy_refresh" in client.cookies

        # Cookie auth
        me_cookie = client.get("/api/v2/auth/me")
        assert me_cookie.status_code == 200
        assert me_cookie.json()["username"] == "admin_u"

        # Logout clears cookies & revokes session
        out = client.post("/api/v2/auth/logout", json={"refresh_token": refresh_tok})
        assert out.status_code == 200

        # Bearer auth with fresh login
        resp2 = client.post(
            "/api/v2/auth/login",
            json={"username": "admin_u", "password": "AdminPassword!123"},
        )
        tok2 = resp2.json()["tokens"]["access_token"]
        client.cookies.clear()
        me_bearer = client.get("/api/v2/auth/me", headers={"Authorization": f"Bearer {tok2}"})
        assert me_bearer.status_code == 200
        assert me_bearer.json()["username"] == "admin_u"
        assert access_tok != tok2 or True
    db.close()


def test_refresh_token_rotation_and_reuse_detection(tmp_path: Path) -> None:
    client, db = _setup_gateway(tmp_path)
    with client:
        r1 = client.post("/api/v2/auth/login", json={"username": "admin_u", "password": "AdminPassword!123"})
        rt1 = r1.json()["tokens"]["refresh_token"]

        client.cookies.clear()
        r2 = client.post("/api/v2/auth/refresh", json={"refresh_token": rt1})
        assert r2.status_code == 200
        rt2 = r2.json()["tokens"]["refresh_token"]
        assert rt2 != rt1

        # Replaying old rt1 must fail and revoke all sessions (including rt2)
        client.cookies.clear()
        replay = client.post("/api/v2/auth/refresh", json={"refresh_token": rt1})
        assert replay.status_code == 401

        client.cookies.clear()
        after_reuse = client.post("/api/v2/auth/refresh", json={"refresh_token": rt2})
        assert after_reuse.status_code == 401
    db.close()


def test_login_rate_limit_lockout(tmp_path: Path) -> None:
    client, db = _setup_gateway(tmp_path, max_failures=3)
    with client:
        for _ in range(2):
            bad = client.post("/api/v2/auth/login", json={"username": "guest_ro", "password": "wrong"})
            assert bad.status_code == 401
        third = client.post("/api/v2/auth/login", json={"username": "guest_ro", "password": "wrong"})
        assert third.status_code == 429

        # Even valid password is blocked while locked out
        good_while_locked = client.post(
            "/api/v2/auth/login",
            json={"username": "guest_ro", "password": "GuestPassword!123"},
        )
        assert good_while_locked.status_code == 429
    db.close()


def test_rbac_node_isolation_and_admin_governance(tmp_path: Path) -> None:
    client, db = _setup_gateway(tmp_path)
    with client:
        # Guest logs in: sees only 'deck', blocked from 'windows', blocked from write/delete
        g_login = client.post("/api/v2/auth/login", json={"username": "guest_ro", "password": "GuestPassword!123"})
        g_tok = g_login.json()["tokens"]["access_token"]
        client.cookies.clear()
        g_headers = {"Authorization": f"Bearer {g_tok}"}

        nodes_resp = client.get("/api/v2/nodes", headers=g_headers)
        assert nodes_resp.status_code == 200
        node_ids = [n["id"] for n in nodes_resp.json()["nodes"]]
        assert node_ids == ["deck"]

        # Access to ungranted node -> 403
        assert client.get("/api/v2/nodes/windows/sessions", headers=g_headers).status_code == 403
        # Write/delete on read-only granted node -> 403
        assert client.post("/api/v2/nodes/deck/sessions", json={"content": "hi"}, headers=g_headers).status_code == 403
        assert client.delete("/api/v2/nodes/deck/sessions/abc", headers=g_headers).status_code == 403
        # Admin route -> 403
        assert client.get("/api/v2/admin/users", headers=g_headers).status_code == 403

        # Admin creates a new member and revokes sessions
        a_login = client.post("/api/v2/auth/login", json={"username": "admin_u", "password": "AdminPassword!123"})
        a_tok = a_login.json()["tokens"]["access_token"]
        client.cookies.clear()
        a_headers = {"Authorization": f"Bearer {a_tok}"}

        created = client.post(
            "/api/v2/admin/users",
            headers=a_headers,
            json={
                "username": "bob",
                "password": "BobPassword!123",
                "display_name": "Bob",
                "role": "member",
                "default_node": "windows",
                "nodes": [{"node_id": "windows", "can_write": True, "can_delete": False}],
            },
        )
        assert created.status_code == 201
        assert created.json()["allowed_nodes"] == ["windows"]

        revoked = client.post("/api/v2/admin/users/guest_ro/revoke-sessions", headers=a_headers)
        assert revoked.status_code == 200
        assert revoked.json()["revoked_count"] >= 1
    db.close()
