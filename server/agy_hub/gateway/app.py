"""FastAPI Edge Gateway application assembly."""

from __future__ import annotations

import hashlib
import re
import urllib.parse
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request, Response, WebSocket, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse

from agy_hub.common.schemas import (
    DownloadTicketRequest,
    DownloadTicketResponse,
    LoginRequest,
    LoginResponse,
    NodesResponse,
    RefreshRequest,
    UserCreateRequest,
    UserPermissionsUpdateRequest,
    UserProfile,
)
from agy_hub.common.security import issue_file_ticket, verify_file_ticket
from agy_hub.gateway.auth import REFRESH_COOKIE_NAME, AuthService
from agy_hub.gateway.config import GatewayConfig, resolve_web_dir
from agy_hub.gateway.db import HubDatabase
from agy_hub.gateway.proxy import proxy_http_to_node, proxy_ws_to_node
from agy_hub.gateway.registry import NodeRegistryManager

_NO_CACHE_FILES = {
    "index.html",
    "flutter_bootstrap.js",
    "manifest.json",
    "version.json",
    "flutter_service_worker.js",
    "FontManifest.json",
    "AssetManifest.bin.json",
    "AssetManifest.bin",
}
_NO_CACHE_CONTROL = "no-cache, no-store, must-revalidate, max-age=0"
_VERSIONED_FONT_RE = re.compile(r"^assets/fonts/v_[0-9a-f]{12}/MaterialIcons-Regular\.otf$")
_MATERIAL_FONT_REL = "assets/fonts/MaterialIcons-Regular.otf"
_SAFE_FONT_NAME_RE = re.compile(r"^[a-zA-Z0-9._-]+\.(?:ttf|otf)$")


class _StaticFileVersioner:
    """Computes and caches a short content digest for a static build/web file."""

    def __init__(self, web_dir: Path, rel_path: str) -> None:
        self._target = web_dir / rel_path
        self._cached_stat: tuple[int, int] | None = None
        self._cached_ver: str = ""

    def get_version(self) -> str:
        target = self._target
        try:
            st = target.stat()
        except OSError:
            self._cached_stat = None
            self._cached_ver = ""
            return ""
        sig = (st.st_size, st.st_mtime_ns)
        if sig == self._cached_stat and self._cached_ver:
            return self._cached_ver
        h = hashlib.sha256()
        with open(target, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                h.update(chunk)
        self._cached_stat = sig
        self._cached_ver = h.hexdigest()[:12]
        return self._cached_ver


def create_gateway_app(
    config: GatewayConfig,
    db: HubDatabase | None = None,
    http_client: httpx.AsyncClient | None = None,
    ws_connector: Any = None,
    enable_monitor: bool = True,
) -> FastAPI:
    owned_db = db is None
    hub_db = db or HubDatabase(config.db_path)
    owned_client = http_client is None
    client = http_client or httpx.AsyncClient(
        timeout=httpx.Timeout(connect=10.0, read=120.0, write=60.0, pool=10.0),
    )
    auth_service = AuthService(hub_db, config)
    registry = NodeRegistryManager(
        config.nodes,
        http_client=client,
        probe_interval_seconds=config.probe_interval_seconds,
    )

    server_dir = Path(__file__).resolve().parents[2]
    web_dir = resolve_web_dir(config.web_dir, server_dir)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        if enable_monitor:
            await registry.probe_all()
            registry.start()
        try:
            yield
        finally:
            await registry.stop()
            if owned_client:
                await client.aclose()
            if owned_db:
                hub_db.close()

    app = FastAPI(title="AGY Remote Hub Gateway", version="2.0.0", lifespan=lifespan)

    if config.allowed_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=config.allowed_origins,
            allow_credentials=True,
            allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type"],
        )

    def get_current_user(request: Request) -> UserProfile:
        return auth_service.authenticate_http(request)

    def require_admin(user: UserProfile = Depends(get_current_user)) -> UserProfile:
        if user.role != "admin":
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin privilege required")
        return user

    @app.get("/api/v2/health")
    async def health() -> dict[str, Any]:
        return {"status": "healthy", "service": "gateway", "version": "2.0.0"}

    @app.post("/api/v2/auth/login", response_model=LoginResponse)
    async def login(payload: LoginRequest, request: Request, response: Response) -> LoginResponse:
        client_ip = request.client.host if request.client else "unknown"
        profile, tokens = auth_service.login(
            username=payload.username,
            password=payload.password,
            client_ip=client_ip,
            device_info=payload.device_info or request.headers.get("user-agent", ""),
        )
        auth_service.set_auth_cookies(response, tokens)
        return LoginResponse(ok=True, user=profile, tokens=tokens)

    @app.post("/api/v2/auth/refresh", response_model=LoginResponse)
    async def refresh(request: Request, response: Response, payload: RefreshRequest | None = None) -> LoginResponse:
        raw_refresh = (payload.refresh_token if payload else None) or request.cookies.get(REFRESH_COOKIE_NAME)
        profile, tokens = auth_service.refresh(
            raw_refresh_token=raw_refresh,
            device_info=request.headers.get("user-agent", ""),
        )
        auth_service.set_auth_cookies(response, tokens)
        return LoginResponse(ok=True, user=profile, tokens=tokens)

    @app.post("/api/v2/auth/logout")
    async def logout(request: Request, response: Response, payload: RefreshRequest | None = None) -> dict[str, bool]:
        raw_refresh = (payload.refresh_token if payload else None) or request.cookies.get(REFRESH_COOKIE_NAME)
        auth_service.logout(raw_refresh)
        auth_service.clear_auth_cookies(response)
        return {"ok": True}

    @app.get("/api/v2/auth/me", response_model=UserProfile)
    async def me(user: UserProfile = Depends(get_current_user)) -> UserProfile:
        return user

    @app.get("/api/v2/nodes", response_model=NodesResponse)
    async def list_nodes(user: UserProfile = Depends(get_current_user)) -> NodesResponse:
        if enable_monitor:
            await registry.probe_all()
        visible = registry.get_visible_nodes(user)
        return NodesResponse(nodes=visible, default_node=user.default_node)

    # Admin user governance endpoints
    @app.get("/api/v2/admin/users")
    async def admin_list_users(_admin: UserProfile = Depends(require_admin)) -> dict[str, Any]:
        return {"users": [u.model_dump() for u in hub_db.list_users()]}

    @app.post("/api/v2/admin/users", response_model=UserProfile, status_code=status.HTTP_201_CREATED)
    async def admin_create_user(
        payload: UserCreateRequest,
        _admin: UserProfile = Depends(require_admin),
    ) -> UserProfile:
        if hub_db.get_user_profile_by_username(payload.username):
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Username already exists")
        return hub_db.create_user(
            username=payload.username,
            password=payload.password,
            display_name=payload.display_name,
            role=payload.role,
            default_node=payload.default_node,
            grants=payload.nodes,
        )

    @app.put("/api/v2/admin/users/{username}/permissions", response_model=UserProfile)
    async def admin_update_permissions(
        username: str,
        payload: UserPermissionsUpdateRequest,
        _admin: UserProfile = Depends(require_admin),
    ) -> UserProfile:
        updated = hub_db.set_user_permissions(username, payload.nodes, default_node=payload.default_node)
        if not updated:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
        return updated

    @app.post("/api/v2/admin/users/{username}/revoke-sessions")
    async def admin_revoke_sessions(
        username: str,
        _admin: UserProfile = Depends(require_admin),
    ) -> dict[str, Any]:
        if not hub_db.get_user_profile_by_username(username):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
        count = hub_db.revoke_all_user_sessions(username)
        return {"ok": True, "revoked_count": count}

    @app.post("/api/v2/nodes/{node_id}/files/ticket", response_model=DownloadTicketResponse)
    async def issue_node_file_ticket(
        node_id: str,
        payload: DownloadTicketRequest,
        user: UserProfile = Depends(get_current_user),
    ) -> DownloadTicketResponse:
        auth_service.check_node_access(user, node_id, require_write=False, require_delete=False)
        ticket = issue_file_ticket(
            secret=config.signing_secret,
            node_id=node_id,
            root_id=payload.root_id,
            rel_path=payload.path,
            username=user.username,
            ttl_seconds=60,
        )
        filename = Path(payload.path).name or "download"
        return DownloadTicketResponse(ticket=ticket, expires_in=60, filename=filename)

    @app.api_route(
        "/api/v2/nodes/{node_id}/{subpath:path}",
        methods=["GET", "POST", "PUT", "DELETE"],
    )
    async def proxy_node_http(node_id: str, subpath: str, request: Request) -> Any:
        clean_subpath = subpath.lstrip("/")
        override_query: str | None = None

        ticket_param = request.query_params.get("ticket")
        if request.method == "GET" and clean_subpath in ("files/download", "media") and ticket_param:
            ticket_data = verify_file_ticket(config.signing_secret, ticket_param)
            if not ticket_data or ticket_data.get("node_id") != node_id:
                raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired file ticket")
            user = hub_db.get_user_profile_by_username(str(ticket_data.get("username", "")))
            if not user or not user.is_active:
                raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User inactive or missing")
            perms = auth_service.check_node_access(user, node_id)
            override_query = urllib.parse.urlencode(
                {
                    "root_id": ticket_data["root_id"],
                    "path": ticket_data["rel_path"],
                }
            )
        else:
            user = auth_service.authenticate_http(request)
            require_delete = request.method == "DELETE"
            require_write = request.method in ("POST", "PUT", "PATCH")
            perms = auth_service.check_node_access(
                user,
                node_id,
                require_write=require_write,
                require_delete=require_delete,
            )

        node_cfg = config.nodes[node_id]
        upstream_path = f"/agent/{clean_subpath}"
        return await proxy_http_to_node(
            request=request,
            node_cfg=node_cfg,
            upstream_path=upstream_path,
            user=user,
            perms=perms,
            internal_secret=config.internal_secret,
            http_client=client,
            override_query=override_query,
        )

    @app.websocket("/ws/v2/nodes/{node_id}/events")
    async def proxy_node_ws(node_id: str, websocket: WebSocket) -> None:
        user = auth_service.authenticate_ws(websocket)
        if not user:
            await websocket.close(code=4401, reason="Unauthorized")
            return
        try:
            perms = auth_service.check_node_access(user, node_id)
        except HTTPException as exc:
            code = 4404 if exc.status_code == 404 else 4403
            await websocket.close(code=code, reason=str(exc.detail))
            return

        node_cfg = config.nodes[node_id]
        await proxy_ws_to_node(
            client_ws=websocket,
            node_cfg=node_cfg,
            upstream_path="/agent/ws/events",
            user=user,
            perms=perms,
            internal_secret=config.internal_secret,
            ws_connector=ws_connector,
        )

    # Self-hosted optional UI fonts (persisted outside build/web so web deploys keep them)
    font_search_dirs: list[Path] = [(server_dir.parent / "fonts").resolve()]
    if web_dir:
        font_search_dirs.append((web_dir / "fonts").resolve())

    @app.get("/static-fonts/{filename}")
    async def serve_static_font(filename: str) -> Response:
        if not _SAFE_FONT_NAME_RE.fullmatch(filename):
            return JSONResponse(status_code=404, content={"detail": "Font not found"})
        for root in font_search_dirs:
            candidate = (root / filename).resolve()
            if candidate.is_relative_to(root) and candidate.is_file():
                media_type = "font/otf" if filename.lower().endswith(".otf") else "font/ttf"
                resp = FileResponse(candidate, media_type=media_type)
                resp.headers["Cache-Control"] = "public, max-age=31536000, immutable"
                return resp
        return JSONResponse(status_code=404, content={"detail": "Font not found"})

    # Static frontend serving & SPA fallback (never intercept /api/* or /ws/*)
    if web_dir:
        main_js_versioner = _StaticFileVersioner(web_dir, "main.dart.js")
        material_font_versioner = _StaticFileVersioner(web_dir, _MATERIAL_FONT_REL)

        @app.get("/{full_path:path}")
        async def serve_spa(full_path: str, request: Request) -> Response:
            if full_path.startswith("api/") or full_path == "api" or full_path.startswith("ws/") or full_path == "ws":
                return JSONResponse(status_code=404, content={"detail": "Not found"})

            rel = full_path.lstrip("/")
            is_versioned_font = False
            if not rel:
                target = web_dir / "index.html"
            elif _VERSIONED_FONT_RE.fullmatch(rel):
                font_candidate = (web_dir / _MATERIAL_FONT_REL).resolve()
                if font_candidate.is_relative_to(web_dir) and font_candidate.is_file():
                    target = font_candidate
                    is_versioned_font = True
                else:
                    return JSONResponse(status_code=404, content={"detail": "Static asset not found"})
            else:
                candidate = (web_dir / rel).resolve()
                if candidate.is_relative_to(web_dir) and candidate.is_file():
                    target = candidate
                else:
                    # Fallback to index.html for SPA routes unless requesting a file extension asset
                    if "." in Path(rel).name:
                        return JSONResponse(status_code=404, content={"detail": "Static asset not found"})
                    target = web_dir / "index.html"

            if target.name == "flutter_bootstrap.js":
                text = target.read_text(encoding="utf-8", errors="replace")
                ver = main_js_versioner.get_version()
                if ver and '"mainJsPath":"main.dart.js"' in text:
                    text = text.replace('"mainJsPath":"main.dart.js"', f'"mainJsPath":"main.dart.js?v={ver}"')
                return Response(
                    content=text,
                    media_type="application/javascript",
                    headers={"Cache-Control": _NO_CACHE_CONTROL},
                )

            if rel == "assets/FontManifest.json":
                text = target.read_text(encoding="utf-8", errors="replace")
                font_ver = material_font_versioner.get_version()
                if font_ver and "fonts/MaterialIcons-Regular.otf" in text:
                    text = text.replace(
                        "fonts/MaterialIcons-Regular.otf",
                        f"fonts/v_{font_ver}/MaterialIcons-Regular.otf",
                    )
                return Response(
                    content=text,
                    media_type="application/json",
                    headers={"Cache-Control": _NO_CACHE_CONTROL},
                )

            resp = FileResponse(target)
            if is_versioned_font:
                resp.headers["Cache-Control"] = "public, max-age=86400"
            elif target.name in _NO_CACHE_FILES or rel == _MATERIAL_FONT_REL:
                resp.headers["Cache-Control"] = _NO_CACHE_CONTROL
            elif target.name == "main.dart.js":
                has_version = bool(request.query_params.get("v", "").strip())
                resp.headers["Cache-Control"] = "public, max-age=86400" if has_version else _NO_CACHE_CONTROL
            else:
                resp.headers["Cache-Control"] = "public, max-age=86400"
            return resp

    return app
