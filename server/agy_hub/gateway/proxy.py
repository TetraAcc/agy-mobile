"""Unified HTTP and WebSocket transparent reverse proxy from Gateway to Node Agents."""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Callable

import httpx
import websockets
from fastapi import Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.background import BackgroundTask

from agy_hub.common.schemas import UserPermissionGrant, UserProfile
from agy_hub.common.security import sign_internal_request
from agy_hub.gateway.config import NodeConfig

logger = logging.getLogger(__name__)

_FORWARD_REQ_HEADERS = {"content-type", "accept", "range", "if-none-match", "if-modified-since"}
_SKIP_RESP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-encoding",
}


def _to_ws_url(base_url: str, upstream_path: str) -> str:
    if base_url.startswith("https://"):
        ws_base = "wss://" + base_url[8:]
    elif base_url.startswith("http://"):
        ws_base = "ws://" + base_url[7:]
    else:
        ws_base = f"ws://{base_url}"
    return f"{ws_base}{upstream_path}"


async def proxy_http_to_node(
    request: Request,
    node_cfg: NodeConfig,
    upstream_path: str,
    user: UserProfile,
    perms: UserPermissionGrant,
    internal_secret: str,
    http_client: httpx.AsyncClient,
    override_query: str | None = None,
) -> Any:
    """Proxy an authorized HTTP request to a Node Agent with HMAC internal signatures."""
    query_str = request.url.query if override_query is None else override_query
    target_url = f"{node_cfg.base_url}{upstream_path}"
    if query_str:
        target_url = f"{target_url}?{query_str}"

    perm_json = json.dumps(
        {"can_write": perms.can_write, "can_delete": perms.can_delete},
        separators=(",", ":"),
        sort_keys=True,
    )
    signed_headers = sign_internal_request(
        secret=internal_secret,
        method=request.method,
        path=upstream_path,
        user=user.username,
        permissions=perm_json,
    )

    fwd_headers = dict(signed_headers)
    for k, v in request.headers.items():
        if k.lower() in _FORWARD_REQ_HEADERS:
            fwd_headers[k] = v

    body = await request.body()
    max_attempts = 2 if request.method == "GET" else 1
    upstream_resp: httpx.Response | None = None
    last_exc: Exception | None = None
    for attempt in range(max_attempts):
        try:
            upstream_req = http_client.build_request(
                method=request.method,
                url=target_url,
                headers=fwd_headers,
                content=body if body else None,
            )
            upstream_resp = await http_client.send(upstream_req, stream=True)
            break
        except (httpx.RemoteProtocolError, httpx.ConnectTimeout) as exc:
            last_exc = exc
            if attempt + 1 < max_attempts:
                continue
        except httpx.HTTPError as exc:
            last_exc = exc
            break

    if upstream_resp is None:
        logger.warning(
            "Upstream HTTP proxy error to %s: [%s] %s",
            target_url,
            type(last_exc).__name__,
            last_exc,
        )
        return JSONResponse(status_code=502, content={"detail": f"Node unavailable: {last_exc}"})

    has_content_encoding = any(k.lower() == "content-encoding" for k in upstream_resp.headers.keys())
    resp_headers = {
        k: v
        for k, v in upstream_resp.headers.items()
        if k.lower() not in _SKIP_RESP_HEADERS and not (has_content_encoding and k.lower() == "content-length")
    }
    return StreamingResponse(
        upstream_resp.aiter_bytes(),
        status_code=upstream_resp.status_code,
        headers=resp_headers,
        background=BackgroundTask(upstream_resp.aclose),
    )


async def proxy_ws_to_node(
    client_ws: WebSocket,
    node_cfg: NodeConfig,
    upstream_path: str,
    user: UserProfile,
    perms: UserPermissionGrant,
    internal_secret: str,
    ws_connector: Any = None,
    node_id: str = "",
    on_session_subscription_change: Callable[[str, str, bool], None] | None = None,
    upstream_query: str = "",
) -> None:
    """Bridge a single authenticated client WebSocket to the target Node Agent."""
    upstream_url = _to_ws_url(node_cfg.base_url, upstream_path)
    if upstream_query:
        upstream_url = f"{upstream_url}?{upstream_query}"
    perm_json = json.dumps(
        {"can_write": perms.can_write, "can_delete": perms.can_delete},
        separators=(",", ":"),
        sort_keys=True,
    )
    signed_headers = sign_internal_request(
        secret=internal_secret,
        method="GET",
        path=upstream_path,
        user=user.username,
        permissions=perm_json,
    )
    connector = ws_connector or websockets.connect

    try:
        if ws_connector is None:
            upstream_ctx = websockets.connect(
                upstream_url,
                additional_headers=signed_headers,
                open_timeout=25.0,
                ping_interval=25.0,
                ping_timeout=30.0,
            )
        else:
            upstream_ctx = ws_connector(upstream_url, additional_headers=signed_headers)
        upstream_ws = await upstream_ctx.__aenter__()
    except Exception as exc:
        logger.warning("Upstream WS connection failed to %s: [%s] %s", upstream_url, type(exc).__name__, exc)
        await client_ws.close(code=4502, reason="Node unreachable")
        return

    await client_ws.accept()
    subscribed_sids: set[str] = set()

    def _track_client_command(raw_text: str) -> None:
        if on_session_subscription_change is None or not node_id:
            return
        try:
            payload = json.loads(raw_text)
        except Exception:
            return
        if not isinstance(payload, dict):
            return
        cmd_type = str(payload.get("type") or "").strip().lower()
        sid = str(payload.get("session_id") or "").strip()
        if not sid:
            return
        if cmd_type == "subscribe":
            if sid not in subscribed_sids:
                subscribed_sids.add(sid)
                try:
                    on_session_subscription_change(node_id, sid, True)
                except Exception:
                    pass
        elif cmd_type == "unsubscribe":
            if sid in subscribed_sids:
                subscribed_sids.discard(sid)
                try:
                    on_session_subscription_change(node_id, sid, False)
                except Exception:
                    pass

    async def client_to_upstream() -> None:
        try:
            while True:
                msg = await client_ws.receive()
                msg_type = msg.get("type")
                if msg_type == "websocket.disconnect":
                    break
                if "text" in msg and msg["text"] is not None:
                    text_payload = msg["text"]
                    _track_client_command(text_payload)
                    await upstream_ws.send(text_payload)
                elif "bytes" in msg and msg["bytes"] is not None:
                    await upstream_ws.send(msg["bytes"])
        except WebSocketDisconnect:
            pass
        except Exception:
            pass

    async def upstream_to_client() -> None:
        try:
            async for payload in upstream_ws:
                if isinstance(payload, bytes):
                    await client_ws.send_bytes(payload)
                else:
                    await client_ws.send_text(str(payload))
        except Exception:
            pass

    t_up = asyncio.create_task(client_to_upstream())
    t_down = asyncio.create_task(upstream_to_client())
    try:
        done, pending = await asyncio.wait({t_up, t_down}, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        for task in done:
            _ = task.exception() if not task.cancelled() else None
    finally:
        if on_session_subscription_change is not None and node_id:
            for sid in list(subscribed_sids):
                try:
                    on_session_subscription_change(node_id, sid, False)
                except Exception:
                    pass
        subscribed_sids.clear()
        try:
            await upstream_ctx.__aexit__(None, None, None)
        except Exception:
            pass
        try:
            await client_ws.close()
        except Exception:
            pass
