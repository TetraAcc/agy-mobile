"""Gateway-to-Agent HMAC signature verification dependencies."""

from __future__ import annotations

from dataclasses import dataclass

from fastapi import HTTPException, Request, WebSocket, status

from agy_hub.common.security import verify_internal_request


@dataclass(frozen=True)
class GatewayCaller:
    username: str
    can_write: bool
    can_delete: bool


def require_gateway_signature(request: Request) -> GatewayCaller:
    secret: str = request.app.state.internal_secret
    ok, info = verify_internal_request(
        secret=secret,
        method=request.method,
        path=request.url.path,
        headers=request.headers,
    )
    if not ok or not isinstance(info, dict):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=info if isinstance(info, str) else "Invalid internal signature",
        )
    perms = info.get("permissions", {})
    return GatewayCaller(
        username=str(info.get("user", "unknown")),
        can_write=bool(perms.get("can_write", False)),
        can_delete=bool(perms.get("can_delete", False)),
    )


def require_write_caller(request: Request) -> GatewayCaller:
    caller = require_gateway_signature(request)
    if not caller.can_write:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Write permission required")
    return caller


def require_delete_caller(request: Request) -> GatewayCaller:
    caller = require_gateway_signature(request)
    if not caller.can_delete:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Delete permission required")
    return caller


def verify_ws_gateway_signature(websocket: WebSocket, internal_secret: str) -> GatewayCaller | None:
    ok, info = verify_internal_request(
        secret=internal_secret,
        method="GET",
        path=websocket.url.path,
        headers=websocket.headers,
    )
    if not ok or not isinstance(info, dict):
        return None
    perms = info.get("permissions", {})
    return GatewayCaller(
        username=str(info.get("user", "unknown")),
        can_write=bool(perms.get("can_write", False)),
        can_delete=bool(perms.get("can_delete", False)),
    )
