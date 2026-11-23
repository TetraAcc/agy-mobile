"""End-to-end acceptance test against the real compiled Flutter build/web bundle and CLI-provisioned user DB."""

from __future__ import annotations

import asyncio
import json
import re
import socket
import subprocess
import sys
from pathlib import Path

import httpx
import pytest
import uvicorn
import websockets

from agy_hub.agent.app import create_agent_app
from agy_hub.gateway.app import create_gateway_app
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.db import HubDatabase
from tests.conftest import TEST_INTERNAL_SECRET, TEST_SIGNING_SECRET, write_transcript_step

SERVER_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = SERVER_DIR.parent
REAL_BUILD_WEB = REPO_ROOT / "build" / "web"


async def _start_server(app) -> tuple[uvicorn.Server, asyncio.Task, int]:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(128)
    port = sock.getsockname()[1]

    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    task = asyncio.create_task(server.serve(sockets=[sock]))
    while not server.started:
        await asyncio.sleep(0.02)
    return server, task, port


async def _stop_server(server: uvicorn.Server, task: asyncio.Task) -> None:
    server.should_exit = True
    await task


@pytest.mark.skipif(not (REAL_BUILD_WEB / "index.html").is_file(), reason="build/web/index.html not compiled yet")
@pytest.mark.asyncio
async def test_real_compiled_web_and_cli_user_e2e(tmp_agent_env: dict) -> None:
    tmp_path: Path = tmp_agent_env["tmp_path"]
    brain_dir: Path = tmp_agent_env["brain_dir"]
    proj_dir: Path = tmp_agent_env["proj_dir"]
    (proj_dir / "sample_pic.png").write_bytes(b"\x89PNG\r\n\x1a\nREALWEB")

    # 1. Provision user via real server.py CLI into temporary hub.db
    db_file = tmp_path / "cli_hub.db"
    proc = subprocess.run(
        [
            sys.executable,
            str(SERVER_DIR / "server.py"),
            "user",
            "add",
            "--db",
            str(db_file),
            "--username",
            "e2euser",
            "--password",
            "E2eStrongPass!2026",
            "--role",
            "admin",
            "--nodes",
            "win",
            "--default-node",
            "win",
            "--allow-delete",
        ],
        cwd=str(SERVER_DIR),
        capture_output=True,
        text=True,
        check=True,
    )
    assert "Created user 'e2euser'" in proc.stdout

    # 2. Boot real Node Agent and real Gateway pointing at compiled build/web
    agent_app = create_agent_app(
        tmp_agent_env["config"],
        provider=tmp_agent_env["provider"],
        registry=tmp_agent_env["registry"],
    )
    ag_srv, ag_task, ag_port = await _start_server(agent_app)

    hub_db = HubDatabase(db_file)
    gw_cfg = GatewayConfig(
        host="127.0.0.1",
        port=8768,
        db_path=str(db_file),
        signing_secret=TEST_SIGNING_SECRET,
        internal_secret=TEST_INTERNAL_SECRET,
        allowed_origins=[],
        cookie_secure=False,
        web_dir=str(REAL_BUILD_WEB),
        nodes={"win": NodeConfig(name="Windows PC", base_url=f"http://127.0.0.1:{ag_port}", is_local=False)},
    )
    gw_app = create_gateway_app(gw_cfg, db=hub_db, enable_monitor=False)
    gw_srv, gw_task, gw_port = await _start_server(gw_app)
    gw_base = f"http://127.0.0.1:{gw_port}"

    try:
        async with httpx.AsyncClient(base_url=gw_base, timeout=15.0) as client:
            # Verify compiled build/web assets and cache headers
            root_resp = await client.get("/")
            assert root_resp.status_code == 200
            assert "AGY Remote Hub" in root_resp.text
            assert "no-store" in root_resp.headers.get("cache-control", "")

            boot_resp = await client.get("/flutter_bootstrap.js")
            assert boot_resp.status_code == 200
            assert "no-store" in boot_resp.headers.get("cache-control", "")
            m_ver = re.search(r'"mainJsPath":"(main\.dart\.js\?v=[0-9a-f]{12})"', boot_resp.text)
            assert m_ver is not None, "Expected cache-busted mainJsPath in flutter_bootstrap.js"

            js_resp = await client.get("/main.dart.js")
            assert js_resp.status_code == 200
            assert "no-store" in js_resp.headers.get("cache-control", "")

            js_ver_resp = await client.get(f"/{m_ver.group(1)}")
            assert js_ver_resp.status_code == 200
            assert "max-age=86400" in js_ver_resp.headers.get("cache-control", "")
            assert len(js_ver_resp.content) == (REAL_BUILD_WEB / "main.dart.js").stat().st_size

            # Verify FontManifest & versioned MaterialIcons font cache busting
            font_manifest_resp = await client.get("/assets/FontManifest.json")
            assert font_manifest_resp.status_code == 200
            assert "no-store" in font_manifest_resp.headers.get("cache-control", "")
            m_font = re.search(r'fonts/(v_[0-9a-f]{12}/MaterialIcons-Regular\.otf)', font_manifest_resp.text)
            assert m_font is not None, "Expected versioned MaterialIcons path in FontManifest.json"

            font_ver_resp = await client.get(f"/assets/fonts/{m_font.group(1)}")
            assert font_ver_resp.status_code == 200
            assert "max-age=86400" in font_ver_resp.headers.get("cache-control", "")
            assert len(font_ver_resp.content) == (
                REAL_BUILD_WEB / "assets" / "fonts" / "MaterialIcons-Regular.otf"
            ).stat().st_size

            raw_font_resp = await client.get("/assets/fonts/MaterialIcons-Regular.otf")
            assert raw_font_resp.status_code == 200
            assert "no-store" in raw_font_resp.headers.get("cache-control", "")

            # Login with CLI-provisioned user
            login_resp = await client.post(
                "/api/v2/auth/login",
                json={"username": "e2euser", "password": "E2eStrongPass!2026"},
            )
            assert login_resp.status_code == 200
            token = login_resp.json()["tokens"]["access_token"]
            headers = {"Authorization": f"Bearer {token}"}

            # Probe /api/v2/nodes (Gateway should see win online via internal/health)
            # Trigger probe directly via registry or /api/v2/nodes when monitor enabled;
            # here verify /sessions, /files/roots, /files/ticket, /files/download, /media, /quota
            sess = await client.get("/api/v2/nodes/win/sessions", headers=headers)
            assert sess.status_code == 200
            assert "MySpecialProject" in sess.json()["projects"]

            roots_resp = await client.get("/api/v2/nodes/win/files/roots", headers=headers)
            assert roots_resp.status_code == 200
            assert any(r["id"] == "scratch" for r in roots_resp.json())

            ticket_resp = await client.post(
                "/api/v2/nodes/win/files/ticket",
                json={"root_id": "scratch", "path": "demo_project/sample_pic.png"},
                headers=headers,
            )
            assert ticket_resp.status_code == 200
            ticket = ticket_resp.json()["ticket"]

            dl_resp = await client.get(f"/api/v2/nodes/win/files/download?ticket={ticket}")
            assert dl_resp.status_code == 200
            assert dl_resp.content == b"\x89PNG\r\n\x1a\nREALWEB"

            media_resp = await client.get(
                f"/api/v2/nodes/win/media?path={(proj_dir / 'sample_pic.png').as_uri()}",
                headers=headers,
            )
            assert media_resp.status_code == 200
            assert media_resp.content == b"\x89PNG\r\n\x1a\nREALWEB"

            quota_resp = await client.get("/api/v2/nodes/win/quota", headers=headers)
            assert quota_resp.status_code == 200
            assert quota_resp.json()["groups"][0]["display_name"] == "Gemini"

        sid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
        async with websockets.connect(
            f"ws://127.0.0.1:{gw_port}/ws/v2/nodes/win/events",
            additional_headers={"Authorization": f"Bearer {token}"},
        ) as ws:
            await ws.send(json.dumps({"type": "subscribe", "session_id": sid}))
            status_evt = json.loads(await asyncio.wait_for(ws.recv(), timeout=3.0))
            assert status_evt["type"] == "session_status"

            write_transcript_step(
                brain_dir,
                sid,
                {"step_index": 77, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "content": "E2E Real Web OK"},
            )
            step_evt = json.loads(await asyncio.wait_for(ws.recv(), timeout=3.0))
            assert step_evt["type"] == "step_upsert"
            assert step_evt["step"]["content"] == "E2E Real Web OK"
    finally:
        await _stop_server(gw_srv, gw_task)
        await _stop_server(ag_srv, ag_task)
        hub_db.close()
