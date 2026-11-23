"""Stateless FastAPI Node Agent application assembly."""

from __future__ import annotations

import asyncio
import json
import mimetypes
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Literal

from fastapi import Depends, FastAPI, File, HTTPException, Query, UploadFile, WebSocket, WebSocketDisconnect, status
from fastapi.responses import FileResponse

from agy_hub.agent.auth import (
    GatewayCaller,
    require_delete_caller,
    require_gateway_signature,
    require_write_caller,
    verify_ws_gateway_signature,
)
from agy_hub.agent.config import AgentConfig, resolve_platform
from agy_hub.agent.message_queue import SessionMessageQueueManager
from agy_hub.agent.providers.base import BaseEngineProvider, InvalidSessionIdError
from agy_hub.agent.providers.deck import DeckEngineProvider
from agy_hub.agent.providers.windows import WindowsEngineProvider
from agy_hub.agent.watcher import SessionEventHub
from agy_hub.common.sandbox import BinaryFileError, RootRegistry, SandboxError, is_sensitive_path
from agy_hub.common.schemas import (
    ActionAckResponse,
    CreateSessionRequest,
    CreateSessionResponse,
    DeleteSessionResponse,
    FileContentResponse,
    FileRootItem,
    FileTreeResponse,
    GitDiffResponse,
    GitRepoItem,
    GitReposResponse,
    QueuePauseRequest,
    QuotaResponse,
    SendMessageRequest,
    SessionArtifactsResponse,
    SessionChangesResponse,
    SessionMessagesResponse,
    SessionQueueResponse,
    SessionTreeResponse,
    ToolCallOutputResponse,
    UpdateQueuedMessageRequest,
    UploadResponse,
    WriteFileContentRequest,
    WriteFileContentResponse,
    WsEventError,
)
from agy_hub.common.session_diff import extract_session_changes
from agy_hub.common.session_inspect import get_step_tool_output, list_session_artifacts

_IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"}


def _build_default_provider(config: AgentConfig, registry: RootRegistry) -> BaseEngineProvider:
    platform = resolve_platform(config.platform)
    if platform == "deck":
        return DeckEngineProvider(config, registry)
    return WindowsEngineProvider(config, registry)


def create_agent_app(
    config: AgentConfig,
    provider: BaseEngineProvider | None = None,
    registry: RootRegistry | None = None,
) -> FastAPI:
    root_registry = registry or RootRegistry()
    engine_provider = provider or _build_default_provider(config, root_registry)
    event_hub = SessionEventHub(engine_provider, poll_interval=config.poll_interval_seconds)
    queue_manager = SessionMessageQueueManager(engine_provider)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        queue_manager.start()
        try:
            yield
        finally:
            await queue_manager.shutdown()
            await event_hub.shutdown()
            await engine_provider.aclose()

    app = FastAPI(title="AGY Remote Node Agent", version="2.0.0", lifespan=lifespan)
    app.state.internal_secret = config.internal_secret
    app.state.provider = engine_provider
    app.state.registry = root_registry
    app.state.event_hub = event_hub
    app.state.queue_manager = queue_manager

    @app.get("/internal/health")
    async def internal_health() -> dict[str, Any]:
        return {
            "status": "healthy",
            "platform": engine_provider.platform_name,
            "engine_alive": await engine_provider.is_engine_alive(),
            "time": time.time(),
        }

    @app.get("/agent/sessions", response_model=SessionTreeResponse)
    async def list_sessions(_caller: GatewayCaller = Depends(require_gateway_signature)) -> SessionTreeResponse:
        return await engine_provider.get_session_tree()

    @app.post("/agent/sessions", response_model=CreateSessionResponse)
    async def create_session(
        payload: CreateSessionRequest,
        _caller: GatewayCaller = Depends(require_write_caller),
    ) -> CreateSessionResponse:
        ws_path = payload.workspace_path
        if not ws_path and payload.root_id:
            try:
                _, resolved_root, _ = root_registry.get_root(payload.root_id)
                ws_path = str(resolved_root)
            except SandboxError as exc:
                raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
        return await engine_provider.create_session(
            content=payload.content,
            model=payload.model,
            mode=payload.mode,
            workspace_path=ws_path,
        )

    @app.get("/agent/sessions/{sid}/messages", response_model=SessionMessagesResponse)
    async def get_session_messages(
        sid: str,
        before_step: int | None = Query(default=None),
        limit: int = Query(default=60, ge=1, le=500),
        _caller: GatewayCaller = Depends(require_gateway_signature),
    ) -> SessionMessagesResponse:
        try:
            return await engine_provider.get_session_messages(sid, before_step=before_step, limit=limit)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    @app.get("/agent/sessions/{sid}/changes", response_model=SessionChangesResponse)
    async def get_session_changes(
        sid: str,
        include_hunks: bool = Query(default=False),
        file_path: str | None = Query(default=None),
        _caller: GatewayCaller = Depends(require_gateway_signature),
    ) -> SessionChangesResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        return await asyncio.to_thread(
            extract_session_changes,
            engine_provider.brain_dir,
            clean_sid,
            include_hunks=include_hunks,
            file_path_filter=file_path,
        )

    @app.get("/agent/sessions/{sid}/steps/{step_index}/tool-output", response_model=ToolCallOutputResponse)
    async def get_session_step_tool_output(
        sid: str,
        step_index: int,
        _caller: GatewayCaller = Depends(require_gateway_signature),
    ) -> ToolCallOutputResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        return await asyncio.to_thread(
            get_step_tool_output,
            engine_provider.brain_dir,
            clean_sid,
            step_index,
        )

    @app.get("/agent/sessions/{sid}/artifacts", response_model=SessionArtifactsResponse)
    async def get_session_artifacts(
        sid: str,
        _caller: GatewayCaller = Depends(require_gateway_signature),
    ) -> SessionArtifactsResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        return await asyncio.to_thread(
            list_session_artifacts,
            engine_provider.brain_dir,
            clean_sid,
        )

    @app.post("/agent/sessions/{sid}/messages", response_model=ActionAckResponse)
    async def send_session_message(
        sid: str,
        payload: SendMessageRequest,
        _caller: GatewayCaller = Depends(require_write_caller),
    ) -> ActionAckResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

        if payload.delivery_mode == "queue":
            is_running = await engine_provider.is_session_running(clean_sid)
            existing_queue = queue_manager.get_queue(clean_sid)
            if is_running or existing_queue.items:
                _, pos = await queue_manager.enqueue(clean_sid, content=payload.content, model=payload.model)
                return ActionAckResponse(
                    ok=True,
                    session_id=clean_sid,
                    message=f"已加入待发队列 (第 {pos} 条)",
                    queued=True,
                    queue_position=pos,
                )

        if payload.delivery_mode == "immediate":
            if engine_provider.platform_name == "deck" and engine_provider.is_managed_process_running(clean_sid):
                await engine_provider.stop_session(clean_sid)

        return await engine_provider.send_message(clean_sid, content=payload.content, model=payload.model)

    @app.post("/agent/sessions/{sid}/stop", response_model=ActionAckResponse)
    async def stop_session(
        sid: str,
        _caller: GatewayCaller = Depends(require_write_caller),
    ) -> ActionAckResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        ack = await engine_provider.stop_session(clean_sid)
        await queue_manager.pause_if_non_empty(clean_sid)
        return ack

    @app.get("/agent/sessions/{sid}/queue", response_model=SessionQueueResponse)
    async def get_session_queue(
        sid: str,
        _caller: GatewayCaller = Depends(require_gateway_signature),
    ) -> SessionQueueResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        return queue_manager.get_queue(clean_sid)

    @app.put("/agent/sessions/{sid}/queue/{item_id}", response_model=SessionQueueResponse)
    async def update_session_queue_item(
        sid: str,
        item_id: str,
        payload: UpdateQueuedMessageRequest,
        _caller: GatewayCaller = Depends(require_write_caller),
    ) -> SessionQueueResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        updated = await queue_manager.update_item(clean_sid, item_id, payload.content)
        if updated is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Queued message not found")
        return updated

    @app.delete("/agent/sessions/{sid}/queue/{item_id}", response_model=SessionQueueResponse)
    async def delete_session_queue_item(
        sid: str,
        item_id: str,
        _caller: GatewayCaller = Depends(require_write_caller),
    ) -> SessionQueueResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        updated = await queue_manager.delete_item(clean_sid, item_id)
        if updated is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Queued message not found")
        return updated

    @app.delete("/agent/sessions/{sid}/queue", response_model=SessionQueueResponse)
    async def clear_session_queue(
        sid: str,
        _caller: GatewayCaller = Depends(require_write_caller),
    ) -> SessionQueueResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        return await queue_manager.clear_queue(clean_sid)

    @app.post("/agent/sessions/{sid}/queue/pause", response_model=SessionQueueResponse)
    async def pause_session_queue(
        sid: str,
        payload: QueuePauseRequest,
        _caller: GatewayCaller = Depends(require_write_caller),
    ) -> SessionQueueResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        return await queue_manager.set_paused(clean_sid, payload.paused)

    @app.post("/agent/sessions/{sid}/queue/{item_id}/send-now", response_model=ActionAckResponse)
    async def send_session_queue_item_now(
        sid: str,
        item_id: str,
        _caller: GatewayCaller = Depends(require_write_caller),
    ) -> ActionAckResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        return await queue_manager.send_item_now(clean_sid, item_id)

    @app.delete("/agent/sessions/{sid}", response_model=DeleteSessionResponse)
    async def delete_session(
        sid: str,
        purge_disk: bool = Query(default=False),
        _caller: GatewayCaller = Depends(require_delete_caller),
    ) -> DeleteSessionResponse:
        try:
            return await engine_provider.archive_session(sid, purge_disk=purge_disk)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    @app.post("/agent/sessions/{sid}/uploads", response_model=UploadResponse)
    async def upload_session_file(
        sid: str,
        file: UploadFile = File(...),
        _caller: GatewayCaller = Depends(require_write_caller),
    ) -> UploadResponse:
        try:
            clean_sid = engine_provider.validate_session_id(sid)
        except InvalidSessionIdError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

        raw_name = Path(file.filename or "upload.bin").name
        safe_name = raw_name.replace(" ", "_").replace("..", "_") or "upload.bin"
        timestamp_ms = int(time.time() * 1000)
        saved_name = f"media_{timestamp_ms}_{safe_name}"

        upload_dir = (engine_provider.brain_dir / clean_sid / ".user_uploaded").resolve()
        brain_resolved = engine_provider.brain_dir.resolve()
        if not upload_dir.is_relative_to(brain_resolved):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid upload target")

        total_bytes = 0
        chunks: list[bytes] = []
        while True:
            chunk = await file.read(65536)
            if not chunk:
                break
            total_bytes += len(chunk)
            if total_bytes > config.max_upload_bytes:
                raise HTTPException(
                    status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                    detail=f"Upload exceeds limit ({config.max_upload_bytes} bytes)",
                )
            chunks.append(chunk)

        target_path = upload_dir / saved_name

        def _write_upload() -> None:
            upload_dir.mkdir(parents=True, exist_ok=True)
            with open(target_path, "wb") as out_f:
                for c in chunks:
                    out_f.write(c)

        await asyncio.to_thread(_write_upload)
        rel_path = os.path.relpath(target_path, brain_resolved).replace("\\", "/")
        is_image = target_path.suffix.lower() in _IMAGE_EXTS
        return UploadResponse(
            filename=safe_name,
            root_id="brain",
            path=rel_path,
            abs_path=str(target_path),
            is_image=is_image,
            size=total_bytes,
        )

    @app.get("/agent/files/roots", response_model=list[FileRootItem])
    async def list_file_roots(_caller: GatewayCaller = Depends(require_gateway_signature)) -> list[FileRootItem]:
        await asyncio.to_thread(engine_provider.sync_workspace_roots_sync)
        return root_registry.list_roots()

    @app.get("/agent/files/tree", response_model=FileTreeResponse)
    async def list_files_tree(
        root_id: str = Query(..., min_length=1),
        path: str = Query(default=""),
        _caller: GatewayCaller = Depends(require_gateway_signature),
    ) -> FileTreeResponse:
        try:
            return await asyncio.to_thread(root_registry.list_directory, root_id, path)
        except SandboxError as exc:
            raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc

    @app.get("/agent/files/content", response_model=FileContentResponse)
    async def read_file_content(
        root_id: str = Query(..., min_length=1),
        path: str = Query(..., min_length=1),
        _caller: GatewayCaller = Depends(require_gateway_signature),
    ) -> FileContentResponse:
        try:
            return await asyncio.to_thread(root_registry.read_text_file, root_id, path)
        except BinaryFileError as exc:
            raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
        except SandboxError as exc:
            raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc

    @app.put("/agent/files/content", response_model=WriteFileContentResponse)
    async def write_file_content(
        payload: WriteFileContentRequest,
        _caller: GatewayCaller = Depends(require_write_caller),
    ) -> WriteFileContentResponse:
        try:
            return await asyncio.to_thread(
                root_registry.write_text_file,
                payload.root_id,
                payload.path,
                payload.content,
                payload.expected_mtime,
            )
        except BinaryFileError as exc:
            raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
        except SandboxError as exc:
            raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc

    @app.get("/agent/files/download")
    async def download_file(
        root_id: str = Query(..., min_length=1),
        path: str = Query(..., min_length=1),
        _caller: GatewayCaller = Depends(require_gateway_signature),
    ) -> FileResponse:
        try:
            target = root_registry.resolve_in_root(root_id, path)
        except SandboxError as exc:
            raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
        if not target.exists() or not target.is_file():
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")
        return FileResponse(target, filename=target.name, content_disposition_type="attachment")

    _INLINE_MEDIA_MIME = {
        ".pdf": "application/pdf",
        ".svg": "image/svg+xml",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".webp": "image/webp",
        ".gif": "image/gif",
        ".bmp": "image/bmp",
    }

    @app.get("/agent/media")
    async def serve_media(
        path: str = Query(..., min_length=1),
        root_id: str | None = Query(default=None),
        _caller: GatewayCaller = Depends(require_gateway_signature),
    ) -> FileResponse:
        try:
            _, target = root_registry.resolve_media_path(path, root_id=root_id)
        except SandboxError as exc:
            raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
        if not target.exists() or not target.is_file():
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Media file not found")
        suffix = target.suffix.lower()
        media_type = _INLINE_MEDIA_MIME.get(suffix) or mimetypes.guess_type(target.name)[0]
        return FileResponse(
            target,
            media_type=media_type,
            filename=target.name,
            content_disposition_type="inline",
        )

    async def _run_git_cmd(cwd: Path, args: list[str], timeout: float = 5.0) -> tuple[int, str, str]:
        proc = await asyncio.create_subprocess_exec(
            "git",
            *args,
            cwd=str(cwd),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out_b, err_b = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return (
            proc.returncode or 0,
            out_b.decode("utf-8", errors="replace").strip(),
            err_b.decode("utf-8", errors="replace").strip(),
        )

    @app.get("/agent/git/repos", response_model=GitReposResponse)
    async def list_git_repos(_caller: GatewayCaller = Depends(require_gateway_signature)) -> GitReposResponse:
        candidates: list[tuple[str, str, str, Path]] = []
        seen_paths: set[str] = set()

        roots = root_registry.list_roots()
        # Register direct non-brain roots first so explicit ws_* roots take precedence over parent scans.
        for item in roots:
            if item.id == "brain":
                continue
            p = Path(item.path).resolve()
            norm = os.path.normcase(str(p))
            if (p / ".git").exists() and not is_sensitive_path(p) and norm not in seen_paths:
                seen_paths.add(norm)
                candidates.append((item.id, "", item.name or p.name, p))

        # Scan direct children of scratch / home roots for unregistered local git repositories.
        for item in roots:
            if item.id not in ("scratch", "home"):
                continue
            base_dir = Path(item.path).resolve()
            if not base_dir.is_dir():
                continue
            try:
                entries = list(os.scandir(base_dir))
            except OSError:
                continue
            for entry in entries:
                if entry.name.startswith("."):
                    continue
                try:
                    if not entry.is_dir(follow_symlinks=False):
                        continue
                    child_p = Path(entry.path).resolve()
                    norm = os.path.normcase(str(child_p))
                    if norm in seen_paths or is_sensitive_path(child_p):
                        continue
                    if (child_p / ".git").exists():
                        seen_paths.add(norm)
                        candidates.append((item.id, entry.name, entry.name, child_p))
                except OSError:
                    continue

        async def _probe_repo(root_id: str, sub_path: str, name: str, repo_dir: Path) -> GitRepoItem | None:
            try:
                rc_b, branch_out, _ = await _run_git_cmd(repo_dir, ["rev-parse", "--abbrev-ref", "HEAD"], timeout=3.0)
                branch = branch_out if rc_b == 0 else ""
                _, status_out, _ = await _run_git_cmd(repo_dir, ["status", "--short"], timeout=3.0)
                changes = len([ln for ln in status_out.splitlines() if ln.strip()]) if status_out else 0
                repo_key = f"{root_id}/{sub_path}" if sub_path else root_id
                return GitRepoItem(
                    id=repo_key,
                    root_id=root_id,
                    sub_path=sub_path,
                    name=name,
                    branch=branch,
                    change_count=changes,
                )
            except Exception:
                return None

        probed = await asyncio.gather(*[_probe_repo(rid, sub, nm, dp) for rid, sub, nm, dp in candidates])
        repos = [r for r in probed if r is not None]
        repos.sort(key=lambda r: (0 if r.change_count > 0 else 1, -r.change_count, r.name.lower()))
        return GitReposResponse(repos=repos)

    @app.get("/agent/git/diff", response_model=GitDiffResponse)
    async def get_git_diff(
        root_id: str = Query(..., min_length=1),
        sub_path: str = Query(default=""),
        scope: Literal["uncommitted", "head"] = Query(default="uncommitted"),
        _caller: GatewayCaller = Depends(require_gateway_signature),
    ) -> GitDiffResponse:
        try:
            ws_dir = root_registry.resolve_in_root(root_id, sub_path)
        except SandboxError as exc:
            raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc
        if not ws_dir.exists() or not ws_dir.is_dir():
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Workspace directory not found")

        try:
            git_rc, is_tree_out, _ = await _run_git_cmd(ws_dir, ["rev-parse", "--is-inside-work-tree"])
            if git_rc != 0 or is_tree_out.lower() != "true":
                return GitDiffResponse(
                    root_id=root_id,
                    workspace=str(ws_dir),
                    status="",
                    diff="Not a Git repository",
                )
            _, status_out, _ = await _run_git_cmd(ws_dir, ["status", "--short"])
            if scope == "head":
                rc, diff_out, diff_err = await _run_git_cmd(ws_dir, ["show", "--stat", "--patch", "HEAD"])
                if rc != 0:
                    diff_out = "No commits yet" if ("unknown revision" in diff_err or "bad default revision" in diff_err) else diff_err
            else:
                rc, diff_out, diff_err = await _run_git_cmd(ws_dir, ["diff", "HEAD"])
                if rc != 0:
                    _, diff_out, _ = await _run_git_cmd(ws_dir, ["diff"])
                    if not diff_out and diff_err and "ambiguous argument 'HEAD'" not in diff_err:
                        diff_out = diff_err
        except Exception as exc:
            status_out = ""
            diff_out = f"Git diff failed: {exc}"

        return GitDiffResponse(
            root_id=root_id,
            workspace=str(ws_dir),
            status=status_out,
            diff=diff_out,
        )

    @app.get("/agent/quota", response_model=QuotaResponse)
    async def get_quota(_caller: GatewayCaller = Depends(require_gateway_signature)) -> QuotaResponse:
        return await engine_provider.fetch_quota()

    @app.websocket("/agent/ws/events")
    async def ws_events(websocket: WebSocket) -> None:
        caller = verify_ws_gateway_signature(websocket, config.internal_secret)
        if caller is None:
            await websocket.close(code=4401, reason="Invalid internal signature")
            return
        await websocket.accept()
        try:
            while True:
                raw_text = await websocket.receive_text()
                try:
                    msg = json.loads(raw_text)
                except Exception:
                    await websocket.send_text(
                        WsEventError(code="bad_json", message="Invalid JSON frame").model_dump_json()
                    )
                    continue
                if not isinstance(msg, dict):
                    continue
                cmd_type = msg.get("type")
                if cmd_type == "ping":
                    await event_hub.send_pong(websocket)
                elif cmd_type == "subscribe":
                    sid = str(msg.get("session_id", ""))
                    since_step = msg.get("since_step")
                    since_int = int(since_step) if isinstance(since_step, int) else None
                    await event_hub.subscribe(websocket, sid, since_step=since_int)
                elif cmd_type == "unsubscribe":
                    sid = str(msg.get("session_id", ""))
                    await event_hub.unsubscribe(websocket, sid)
                else:
                    await websocket.send_text(
                        WsEventError(code="unknown_command", message=f"Unsupported command: {cmd_type}").model_dump_json()
                    )
        except WebSocketDisconnect:
            pass
        finally:
            await event_hub.remove_connection(websocket)

    return app
