"""End-to-end integration tests with real Gateway + real Uvicorn Node Agent + WS proxy + SPA cache headers."""

from __future__ import annotations

import asyncio
import json
import socket
from pathlib import Path

import httpx
import pytest
import uvicorn
import websockets

from agy_hub.agent.app import create_agent_app
from agy_hub.common.schemas import UserPermissionGrant
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.db import HubDatabase
from tests.conftest import TEST_INTERNAL_SECRET, TEST_SIGNING_SECRET, write_transcript_step


async def _start_uvicorn_server(app) -> tuple[uvicorn.Server, asyncio.Task, int]:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(128)
    port = sock.getsockname()[1]

    config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning")
    server = uvicorn.Server(config)
    task = asyncio.create_task(server.serve(sockets=[sock]))
    while not server.started:
        await asyncio.sleep(0.02)
    return server, task, port


async def _stop_uvicorn_server(server: uvicorn.Server, task: asyncio.Task) -> None:
    server.should_exit = True
    await task


@pytest.mark.asyncio
async def test_gateway_to_agent_e2e_http_ticket_ws_and_static_cache(tmp_agent_env: dict) -> None:
    tmp_path: Path = tmp_agent_env["tmp_path"]
    brain_dir: Path = tmp_agent_env["brain_dir"]
    proj_dir: Path = tmp_agent_env["proj_dir"]
    (proj_dir / "diagram.png").write_bytes(b"\x89PNG\r\n\x1a\n123456")

    # Build a mock compiled Flutter web directory
    web_dist = tmp_path / "web_dist"
    (web_dist / "canvaskit").mkdir(parents=True)
    (web_dist / "index.html").write_text("<html><body>AGY v2</body></html>", encoding="utf-8")
    (web_dist / "main.dart.js").write_text("console.log('app');", encoding="utf-8")
    (web_dist / "canvaskit" / "canvaskit.wasm").write_bytes(b"\x00asm\x01\x00\x00\x00")

    # 1. Start real Node Agent
    agent_app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    ag_server, ag_task, ag_port = await _start_uvicorn_server(agent_app)

    # 2. Setup Gateway database with two isolated users
    db_file = tmp_path / "hub.db"
    hub_db = HubDatabase(db_file)
    hub_db.create_user(
        username="tetra",
        password="TetraStrongPassword!9",
        display_name="Tetra",
        role="admin",
        default_node="win",
        grants=[UserPermissionGrant(node_id="win", can_write=True, can_delete=True)],
    )
    hub_db.create_user(
        username="other",
        password="OtherStrongPassword!9",
        display_name="Other",
        role="member",
        default_node="deck",
        grants=[UserPermissionGrant(node_id="deck", can_write=True, can_delete=False)],
    )

    gw_cfg = GatewayConfig(
        host="127.0.0.1",
        port=8768,
        db_path=str(db_file),
        signing_secret=TEST_SIGNING_SECRET,
        internal_secret=TEST_INTERNAL_SECRET,
        allowed_origins=["https://agy.example.com"],
        cookie_secure=False,
        web_dir=str(web_dist),
        nodes={
            "win": NodeConfig(name="Windows PC", base_url=f"http://127.0.0.1:{ag_port}", is_local=False),
            "deck": NodeConfig(name="Steam Deck", base_url="http://127.0.0.1:19999", is_local=True),
        },
    )
    gw_app = create_gateway_app(gw_cfg, db=hub_db, enable_monitor=False)
    gw_server, gw_task, gw_port = await _start_uvicorn_server(gw_app)
    gw_base = f"http://127.0.0.1:{gw_port}"

    try:
        async with httpx.AsyncClient(base_url=gw_base, timeout=10.0) as client:
            # Verify static asset caching policy
            idx_resp = await client.get("/")
            assert idx_resp.status_code == 200
            assert "no-store" in idx_resp.headers.get("cache-control", "")

            js_resp = await client.get("/main.dart.js")
            assert js_resp.status_code == 200
            assert "no-store" in js_resp.headers.get("cache-control", "")

            js_ver_resp = await client.get("/main.dart.js?v=testdigest")
            assert js_ver_resp.status_code == 200
            assert "max-age=86400" in js_ver_resp.headers.get("cache-control", "")

            wasm_resp = await client.get("/canvaskit/canvaskit.wasm")
            assert wasm_resp.status_code == 200
            assert "max-age=86400" in wasm_resp.headers.get("cache-control", "")

            # Verify self-hosted /static-fonts route with immutable caching and strict filename check
            fonts_dir = web_dist / "fonts"
            fonts_dir.mkdir(exist_ok=True)
            (fonts_dir / "DemoFont.ttf").write_bytes(b"\x00\x01\x00\x00" + b"0" * 32)
            font_ok = await client.get("/static-fonts/DemoFont.ttf")
            assert font_ok.status_code == 200
            assert "immutable" in font_ok.headers.get("cache-control", "")
            font_bad = await client.get("/static-fonts/secret.json")
            assert font_bad.status_code == 404

            # Login as tetra (cookie & bearer)
            login_resp = await client.post(
                "/api/v2/auth/login",
                json={"username": "tetra", "password": "TetraStrongPassword!9"},
            )
            assert login_resp.status_code == 200
            tetra_token = login_resp.json()["tokens"]["access_token"]
            auth_headers = {"Authorization": f"Bearer {tetra_token}"}

            # Fetch sessions through Gateway proxy (with cookie automatically stored on client)
            sess_resp = await client.get("/api/v2/nodes/win/sessions")
            assert sess_resp.status_code == 200
            assert "MySpecialProject" in sess_resp.json()["projects"]

            # Send message & multipart upload through Gateway proxy
            sid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
            msg_resp = await client.post(
                f"/api/v2/nodes/win/sessions/{sid}/messages",
                json={"content": "E2E hello"},
                headers=auth_headers,
            )
            assert msg_resp.status_code == 200
            assert tmp_agent_env["provider"].sent_messages[-1]["content"] == "E2E hello"

            up_resp = await client.post(
                f"/api/v2/nodes/win/sessions/{sid}/uploads",
                files={"file": ("e2e.png", b"\x89PNG\r\n\x1a\nabcd", "image/png")},
                headers=auth_headers,
            )
            assert up_resp.status_code == 200
            uploaded_rel = up_resp.json()["path"]

            # Issue short-lived single-file ticket and download without cookies/Bearer
            ticket_resp = await client.post(
                "/api/v2/nodes/win/files/ticket",
                json={"root_id": "brain", "path": uploaded_rel},
                headers=auth_headers,
            )
            assert ticket_resp.status_code == 200
            ticket = ticket_resp.json()["ticket"]

            async with httpx.AsyncClient(base_url=gw_base, timeout=10.0) as anon_client:
                dl_resp = await anon_client.get(f"/api/v2/nodes/win/files/download?ticket={ticket}")
                assert dl_resp.status_code == 200
                assert dl_resp.content == b"\x89PNG\r\n\x1a\nabcd"
                assert dl_resp.headers.get("content-length") == str(len(dl_resp.content))

                # Ticket bound to 'win' cannot be reused on 'deck'
                bad_node_dl = await anon_client.get(f"/api/v2/nodes/deck/files/download?ticket={ticket}")
                assert bad_node_dl.status_code == 401

            # Read local media via file:/// URI through Gateway
            media_resp = await client.get(
                f"/api/v2/nodes/win/media?path={(proj_dir / 'diagram.png').as_uri()}",
                headers=auth_headers,
            )
            assert media_resp.status_code == 200
            assert media_resp.content == b"\x89PNG\r\n\x1a\n123456"

            # Verify other tenant cannot access 'win' via HTTP or WebSocket
            async with httpx.AsyncClient(base_url=gw_base, timeout=10.0) as other_client:
                other_login = await other_client.post(
                    "/api/v2/auth/login",
                    json={"username": "other", "password": "OtherStrongPassword!9"},
                )
                other_tok = other_login.json()["tokens"]["access_token"]
                denied = await other_client.get(
                    "/api/v2/nodes/win/sessions",
                    headers={"Authorization": f"Bearer {other_tok}"},
                )
                assert denied.status_code == 403

                with pytest.raises(Exception):
                    async with websockets.connect(
                        f"ws://127.0.0.1:{gw_port}/ws/v2/nodes/win/events",
                        additional_headers={"Authorization": f"Bearer {other_tok}"},
                    ):
                        pass

        # Connect WebSocket through Gateway -> Agent using Bearer token and receive live step
        async with websockets.connect(
            f"ws://127.0.0.1:{gw_port}/ws/v2/nodes/win/events",
            additional_headers={"Authorization": f"Bearer {tetra_token}"},
        ) as ws:
            await ws.send(json.dumps({"type": "subscribe", "session_id": sid}))
            first_msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=3.0))
            assert first_msg["type"] == "session_status"

            write_transcript_step(
                brain_dir,
                sid,
                {"step_index": 50, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "content": "Live via GW proxy"},
            )
            live_evt = json.loads(await asyncio.wait_for(ws.recv(), timeout=3.0))
            assert live_evt["type"] == "step_upsert"
            assert live_evt["step"]["content"] == "Live via GW proxy"
    finally:
        await _stop_uvicorn_server(gw_server, gw_task)
        await _stop_uvicorn_server(ag_server, ag_task)
        hub_db.close()
