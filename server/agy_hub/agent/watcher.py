"""Per-connection session event hub and non-blocking incremental transcript watcher."""

from __future__ import annotations

import asyncio
import json
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
    watched_path: Path | None = None
    byte_offset: int = 0
    last_step_index: int = -1
    last_running: bool | None = None
    last_conv_db_mtime_ns: int = -1
    last_conv_db_size: int = -1
    emitted_error_steps: set[int] = field(default_factory=set)
    emitted_error_sigs: set[str] = field(default_factory=set)
    task: asyncio.Task[None] | None = None


def _stat_file_sig(path: Path) -> tuple[int, int]:
    try:
        st = path.stat()
        return st.st_mtime_ns, st.st_size
    except OSError:
        return -1, -1


def _compute_complete_tail_offset_and_step(path: Path) -> tuple[int, int]:
    """Return (byte offset immediately after last complete newline, last seen step_index)."""
    if not path.exists() or not path.is_file():
        return 0, -1
    size = path.stat().st_size
    if size == 0:
        return 0, -1
    chunk_size = 65536
    pos = size
    tail_offset = 0
    last_step = -1
    with open(path, "rb") as f:
        while pos > 0:
            read_len = min(chunk_size, pos)
            pos -= read_len
            f.seek(pos)
            data = f.read(read_len)
            last_nl = data.rfind(b"\n")
            if last_nl != -1:
                tail_offset = pos + last_nl + 1
                prefix = data[:last_nl].decode("utf-8", errors="replace")
                for raw_line in reversed(prefix.splitlines()):
                    stripped = raw_line.strip()
                    if not stripped:
                        continue
                    try:
                        obj = json.loads(stripped)
                        if isinstance(obj, dict) and "step_index" in obj:
                            last_step = int(obj.get("step_index", -1) or -1)
                            break
                    except Exception:
                        continue
                break
    return tail_offset, last_step


def _compute_complete_tail_offset(path: Path) -> int:
    """Return byte offset immediately after the last complete newline."""
    offset, _ = _compute_complete_tail_offset_and_step(path)
    return offset


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


def _read_steps_since_with_offset(path: Path, since_step: int) -> tuple[int, list[TranscriptStep]]:
    """Read complete JSONL lines from start of path and return (tail_offset, steps > since_step)."""
    new_offset, all_steps = _read_new_complete_steps(path, 0)
    return new_offset, [s for s in all_steps if s.step_index > since_step]


def _read_steps_since(path: Path, since_step: int) -> list[TranscriptStep]:
    _, steps = _read_steps_since_with_offset(path, since_step)
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
            if tpath.exists():
                initial_offset, initial_step = await asyncio.to_thread(
                    _compute_complete_tail_offset_and_step, tpath
                )
                watched_path: Path | None = tpath
            else:
                initial_offset, initial_step = 0, -1
                watched_path = None
            conv_path = self.provider.get_conversation_db_path(sid)
            conv_mtime_ns, conv_size = await asyncio.to_thread(_stat_file_sig, conv_path)
            init_errs = await asyncio.to_thread(self.provider.read_supplemental_error_steps_sync, sid)
            emitted_error_steps = {s.step_index for s in init_errs}
            emitted_error_sigs = {f"{s.timestamp}|{s.content}" for s in init_errs}
            if emitted_error_steps:
                initial_step = max(initial_step, max(emitted_error_steps))
            initial_running = await self.provider.is_session_running(sid)
            state = _SessionWatchState(
                session_id=sid,
                watched_path=watched_path,
                byte_offset=initial_offset,
                last_step_index=initial_step,
                last_running=initial_running,
                last_conv_db_mtime_ns=conv_mtime_ns,
                last_conv_db_size=conv_size,
                emitted_error_steps=emitted_error_steps,
                emitted_error_sigs=emitted_error_sigs,
            )
            self._sessions[sid] = state
            state.task = asyncio.create_task(self._watch_session(sid))

        state.subscribers.add(ws)
        self._ws_subscriptions.setdefault(ws, set()).add(sid)

        if since_step is not None:
            replay_steps = await asyncio.to_thread(_read_steps_since, tpath, since_step)
            replay_err_ids = {
                s.step_index
                for s in replay_steps
                if s.msg_type == "ERROR_MESSAGE" or s.status.upper() == "ERROR"
            }
            max_replay_step = max((s.step_index for s in replay_steps), default=since_step)
            supp_replay = await asyncio.to_thread(
                self.provider.read_supplemental_error_steps_sync,
                sid,
                min_step_index=since_step,
                existing_error_steps=replay_err_ids,
                max_existing_step=max_replay_step,
            )
            for s in supp_replay:
                state.emitted_error_steps.add(s.step_index)
                state.emitted_error_sigs.add(f"{s.timestamp}|{s.content}")
            combined_replay = sorted(replay_steps + supp_replay, key=lambda s: s.step_index)
            is_running_now = await self.provider.is_session_running(sid)
            for step in combined_replay:
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
                if state.watched_path != tpath:
                    if not tpath.exists():
                        new_offset, steps = 0, []
                    elif state.watched_path is None:
                        new_offset, steps = await asyncio.to_thread(_read_new_complete_steps, tpath, 0)
                        state.watched_path = tpath
                    else:
                        new_offset, steps = await asyncio.to_thread(
                            _read_steps_since_with_offset, tpath, state.last_step_index
                        )
                        state.watched_path = tpath
                else:
                    new_offset, steps = await asyncio.to_thread(
                        _read_new_complete_steps, tpath, state.byte_offset
                    )
                state.byte_offset = new_offset

                for s in steps:
                    if s.msg_type == "ERROR_MESSAGE" or s.status.upper() == "ERROR":
                        state.emitted_error_steps.add(s.step_index)
                        state.emitted_error_sigs.add(f"{s.timestamp}|{s.content}")

                is_running = await self.provider.is_session_running(session_id)

                conv_path = self.provider.get_conversation_db_path(session_id)
                conv_mtime_ns, conv_size = await asyncio.to_thread(_stat_file_sig, conv_path)
                conv_changed = (conv_mtime_ns, conv_size) != (state.last_conv_db_mtime_ns, state.last_conv_db_size)
                just_finished = state.last_running is True and not is_running
                max_seen_step = max(state.last_step_index, max((s.step_index for s in steps), default=-1))
                syn_candidates = self.provider.get_synthetic_error_steps(
                    session_id,
                    max_existing_step=max_seen_step,
                    existing_error_steps=state.emitted_error_steps,
                )
                has_new_synthetic = any(
                    f"{s.timestamp}|{s.content}" not in state.emitted_error_sigs for s in syn_candidates
                )
                if conv_changed or just_finished or has_new_synthetic:
                    state.last_conv_db_mtime_ns = conv_mtime_ns
                    state.last_conv_db_size = conv_size
                    supp_steps = await asyncio.to_thread(
                        self.provider.read_supplemental_error_steps_sync,
                        session_id,
                        existing_error_steps=state.emitted_error_steps,
                        max_existing_step=max_seen_step,
                    )
                    added_supp = False
                    for supp in supp_steps:
                        sig = f"{supp.timestamp}|{supp.content}"
                        if supp.step_index in state.emitted_error_steps or sig in state.emitted_error_sigs:
                            continue
                        state.emitted_error_steps.add(supp.step_index)
                        state.emitted_error_sigs.add(sig)
                        steps.append(supp)
                        added_supp = True
                    if added_supp:
                        steps.sort(key=lambda item: item.step_index)

                if steps:
                    state.last_step_index = max(state.last_step_index, steps[-1].step_index)
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
