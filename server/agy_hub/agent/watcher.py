"""Per-connection session event hub and non-blocking incremental transcript watcher."""

from __future__ import annotations

import asyncio
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path

from fastapi import WebSocket

from agy_hub.agent.providers.base import BaseEngineProvider, InvalidSessionIdError
from agy_hub.common.schemas import (
    TranscriptStep,
    WsEventError,
    WsEventPong,
    WsEventSessionStatus,
    WsEventStepUpsert,
)
from agy_hub.common.transcript import parse_transcript_line

logger = logging.getLogger(__name__)


@dataclass
class _SessionWatchState:
    session_id: str
    subscribers: set[WebSocket] = field(default_factory=set)
    byte_offset: int = 0
    last_running: bool | None = None
    task: asyncio.Task[None] | None = None


def _compute_complete_tail_offset(path: Path) -> int:
    """Return byte offset immediately after the last complete newline."""
    if not path.exists() or not path.is_file():
        return 0
    size = path.stat().st_size
    if size == 0:
        return 0
    # Scan backwards in small chunks up to 64KB to find the last newline
    chunk_size = min(size, 65536)
    with open(path, "rb") as f:
        f.seek(size - chunk_size)
        data = f.read(chunk_size)
    last_nl = data.rfind(b"\n")
    if last_nl == -1:
        # Either single partial line or very long line without trailing newline
        return 0 if size == chunk_size else size
    return (size - chunk_size) + last_nl + 1


def _read_new_complete_steps(path: Path, offset: int) -> tuple[int, list[TranscriptStep]]:
    """Read newly appended complete JSONL lines from offset without holding any persistent file handle."""
    if not path.exists() or not path.is_file():
        return offset, []
    size = path.stat().st_size
    if size < offset:
        offset = 0
    if size <= offset:
        return offset, []

    with open(path, "rb") as f:
        f.seek(offset)
        chunk = f.read(size - offset)

    last_nl = chunk.rfind(b"\n")
    if last_nl == -1:
        # Incomplete line still being flushed; wait until newline arrives
        return offset, []

    complete_bytes = chunk[: last_nl + 1]
    new_offset = offset + len(complete_bytes)
    text = complete_bytes.decode("utf-8", errors="replace")
    steps: list[TranscriptStep] = []
    for line in text.splitlines():
        parsed = parse_transcript_line(line)
        if parsed is not None:
            steps.append(parsed)
    return new_offset, steps


def _read_steps_since(path: Path, since_step: int) -> list[TranscriptStep]:
    if not path.exists() or not path.is_file():
        return []
    steps: list[TranscriptStep] = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parsed = parse_transcript_line(line)
            if parsed is not None and parsed.step_index > since_step:
                steps.append(parsed)
    return steps


class SessionEventHub:
    """Manages per-session file watchers and routes events exclusively to subscribers."""

    def __init__(self, provider: BaseEngineProvider, poll_interval: float = 0.25) -> None:
        self.provider = provider
        self.poll_interval = poll_interval
        self._sessions: dict[str, _SessionWatchState] = {}
        self._ws_subscriptions: dict[WebSocket, set[str]] = {}

    async def subscribe(self, ws: WebSocket, session_id: str, since_step: int | None = None) -> None:
        try:
            sid = self.provider.validate_session_id(session_id)
        except InvalidSessionIdError as exc:
            await self._send_safe(ws, WsEventError(code="invalid_session_id", message=str(exc)).model_dump_json())
            return

        tpath = self.provider.get_transcript_path(sid)
        state = self._sessions.get(sid)
        if state is None:
            initial_offset = await asyncio.to_thread(_compute_complete_tail_offset, tpath)
            initial_running = await self.provider.is_session_running(sid)
            state = _SessionWatchState(
                session_id=sid,
                byte_offset=initial_offset,
                last_running=initial_running,
            )
            self._sessions[sid] = state
            state.task = asyncio.create_task(self._watch_session(sid))

        state.subscribers.add(ws)
        self._ws_subscriptions.setdefault(ws, set()).add(sid)

        if since_step is not None:
            replay_steps = await asyncio.to_thread(_read_steps_since, tpath, since_step)
            is_running_now = await self.provider.is_session_running(sid)
            for step in replay_steps:
                await self._send_safe(
                    ws,
                    WsEventStepUpsert(
                        session_id=sid,
                        step=step,
                        is_running=is_running_now,
                    ).model_dump_json(),
                )

        current_running = await self.provider.is_session_running(sid)
        state.last_running = current_running
        await self._send_safe(
            ws,
            WsEventSessionStatus(session_id=sid, is_running=current_running).model_dump_json(),
        )

    async def unsubscribe(self, ws: WebSocket, session_id: str) -> None:
        sid = session_id.strip()
        subs = self._ws_subscriptions.get(ws)
        if subs:
            subs.discard(sid)
        state = self._sessions.get(sid)
        if state:
            state.subscribers.discard(ws)
            if not state.subscribers:
                await self._stop_session_watcher(sid)

    async def remove_connection(self, ws: WebSocket) -> None:
        sids = list(self._ws_subscriptions.pop(ws, set()))
        for sid in sids:
            state = self._sessions.get(sid)
            if state:
                state.subscribers.discard(ws)
                if not state.subscribers:
                    await self._stop_session_watcher(sid)

    async def send_pong(self, ws: WebSocket) -> None:
        await self._send_safe(ws, WsEventPong().model_dump_json())

    async def _stop_session_watcher(self, session_id: str) -> None:
        state = self._sessions.pop(session_id, None)
        if state and state.task and not state.task.done():
            state.task.cancel()
            try:
                await state.task
            except asyncio.CancelledError:
                pass

    async def shutdown(self) -> None:
        for sid in list(self._sessions.keys()):
            await self._stop_session_watcher(sid)
        self._ws_subscriptions.clear()

    async def _send_safe(self, ws: WebSocket, payload: str) -> bool:
        try:
            await ws.send_text(payload)
            return True
        except Exception:
            return False

    async def _broadcast_to_session(self, state: _SessionWatchState, payload: str) -> None:
        dead: list[WebSocket] = []
        for ws in list(state.subscribers):
            ok = await self._send_safe(ws, payload)
            if not ok:
                dead.append(ws)
        for ws in dead:
            state.subscribers.discard(ws)
            subs = self._ws_subscriptions.get(ws)
            if subs:
                subs.discard(state.session_id)

    async def _watch_session(self, session_id: str) -> None:
        try:
            while True:
                state = self._sessions.get(session_id)
                if state is None or not state.subscribers:
                    break

                tpath = self.provider.get_transcript_path(session_id)
                new_offset, steps = await asyncio.to_thread(_read_new_complete_steps, tpath, state.byte_offset)
                state.byte_offset = new_offset

                is_running = await self.provider.is_session_running(session_id)
                if steps:
                    for step in steps:
                        if session_id not in self._sessions:
                            return
                        evt = WsEventStepUpsert(
                            session_id=session_id,
                            step=step,
                            is_running=is_running,
                        )
                        await self._broadcast_to_session(state, evt.model_dump_json())
                    state.last_running = is_running
                elif state.last_running != is_running:
                    state.last_running = is_running
                    status_evt = WsEventSessionStatus(session_id=session_id, is_running=is_running)
                    await self._broadcast_to_session(state, status_evt.model_dump_json())

                await asyncio.sleep(self.poll_interval)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.exception("Watcher error for session %s: %s", session_id, exc)
