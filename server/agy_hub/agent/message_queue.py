"""Server-side persistent per-session message queue and auto-dispatcher."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import secrets
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from agy_hub.agent.providers.base import BaseEngineProvider
from agy_hub.common.schemas import (
    ActionAckResponse,
    QueuedMessageItem,
    SessionQueueResponse,
)

logger = logging.getLogger(__name__)


@dataclass
class _SessionQueueEntry:
    paused: bool = False
    last_error: str = ""
    items: list[QueuedMessageItem] = field(default_factory=list)
    last_dispatched_at: float = 0.0


class SessionMessageQueueManager:
    """Persists per-session queued prompts and dispatches FIFO when the engine becomes idle."""

    def __init__(
        self,
        provider: BaseEngineProvider,
        poll_interval: float = 0.5,
        cooldown_seconds: float = 1.5,
    ) -> None:
        self.provider = provider
        self.poll_interval = max(0.05, float(poll_interval))
        self.cooldown_seconds = max(0.0, float(cooldown_seconds))
        self._store_path = provider.brain_dir / ".agy_hub_message_queues.json"
        self._queues: dict[str, _SessionQueueEntry] = {}
        self._session_locks: dict[str, asyncio.Lock] = {}
        self._wakeup = asyncio.Event()
        self._task: asyncio.Task[None] | None = None
        self._stopped = False
        self._load_sync()

    def _lock_for(self, session_id: str) -> asyncio.Lock:
        lock = self._session_locks.get(session_id)
        if lock is None:
            lock = asyncio.Lock()
            self._session_locks[session_id] = lock
        return lock

    def _load_sync(self) -> None:
        if not self._store_path.exists():
            return
        try:
            raw = json.loads(self._store_path.read_text(encoding="utf-8"))
        except Exception as exc:
            logger.warning("Failed to load persisted message queues: %s", exc)
            return
        if not isinstance(raw, dict):
            return
        for sid, entry_data in raw.items():
            if not isinstance(entry_data, dict):
                continue
            raw_items = entry_data.get("items") or []
            parsed_items: list[QueuedMessageItem] = []
            for raw_item in raw_items:
                if not isinstance(raw_item, dict):
                    continue
                try:
                    parsed_items.append(QueuedMessageItem.model_validate(raw_item))
                except Exception:
                    continue
            if parsed_items or entry_data.get("paused") or entry_data.get("last_error"):
                self._queues[str(sid)] = _SessionQueueEntry(
                    paused=bool(entry_data.get("paused", False)),
                    last_error=str(entry_data.get("last_error", "") or ""),
                    items=parsed_items,
                )

    def _persist_sync(self) -> None:
        self._store_path.parent.mkdir(parents=True, exist_ok=True)
        serializable: dict[str, Any] = {}
        for sid, entry in self._queues.items():
            if not entry.items and not entry.paused and not entry.last_error:
                continue
            serializable[sid] = {
                "paused": entry.paused,
                "last_error": entry.last_error,
                "items": [item.model_dump() for item in entry.items],
            }

        fd, tmp_name = tempfile.mkstemp(prefix=".agy_q_", dir=str(self._store_path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(serializable, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
                handle.flush()
            os.replace(tmp_name, self._store_path)
            tmp_name = ""
        finally:
            if tmp_name and os.path.exists(tmp_name):
                try:
                    os.unlink(tmp_name)
                except OSError:
                    pass

    def _has_active_work(self) -> bool:
        return any((not entry.paused and len(entry.items) > 0) for entry in self._queues.values())

    def total_pending_count(self) -> int:
        return sum(len(entry.items) for entry in self._queues.values() if not entry.paused)

    def _to_response(self, sid: str, entry: _SessionQueueEntry | None) -> SessionQueueResponse:
        if entry is None:
            return SessionQueueResponse(session_id=sid)
        return SessionQueueResponse(
            session_id=sid,
            paused=entry.paused,
            last_error=entry.last_error,
            items=list(entry.items),
        )

    def start(self) -> None:
        self._stopped = False
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._dispatch_loop())
            if self._has_active_work():
                self._wakeup.set()

    async def shutdown(self) -> None:
        self._stopped = True
        self._wakeup.set()
        if self._task is not None and not self._task.done():
            self._task.cancel()
            await asyncio.gather(self._task, return_exceptions=True)
        self._task = None

    def get_queue(self, sid: str) -> SessionQueueResponse:
        return self._to_response(sid, self._queues.get(sid))

    async def enqueue(self, sid: str, content: str, model: str | None = None) -> tuple[QueuedMessageItem, int]:
        async with self._lock_for(sid):
            entry = self._queues.setdefault(sid, _SessionQueueEntry())
            item = QueuedMessageItem(
                id=secrets.token_hex(6),
                content=content,
                model=model,
                created_at=time.time(),
            )
            entry.items.append(item)
            self._persist_sync()
            pos = len(entry.items)
        self._wakeup.set()
        return item, pos

    async def update_item(self, sid: str, item_id: str, content: str) -> SessionQueueResponse | None:
        async with self._lock_for(sid):
            entry = self._queues.get(sid)
            if not entry:
                return None
            for idx, item in enumerate(entry.items):
                if item.id == item_id:
                    entry.items[idx] = QueuedMessageItem(
                        id=item.id,
                        content=content,
                        model=item.model,
                        created_at=item.created_at,
                    )
                    self._persist_sync()
                    return self._to_response(sid, entry)
            return None

    async def delete_item(self, sid: str, item_id: str) -> SessionQueueResponse | None:
        async with self._lock_for(sid):
            entry = self._queues.get(sid)
            if not entry:
                return None
            before = len(entry.items)
            entry.items = [item for item in entry.items if item.id != item_id]
            if len(entry.items) == before:
                return None
            if not entry.items:
                entry.paused = False
                entry.last_error = ""
            self._persist_sync()
            return self._to_response(sid, entry)

    async def clear_queue(self, sid: str) -> SessionQueueResponse:
        async with self._lock_for(sid):
            entry = self._queues.get(sid)
            if entry:
                entry.items.clear()
                entry.paused = False
                entry.last_error = ""
                self._persist_sync()
            return SessionQueueResponse(session_id=sid)

    async def set_paused(self, sid: str, paused: bool) -> SessionQueueResponse:
        async with self._lock_for(sid):
            entry = self._queues.setdefault(sid, _SessionQueueEntry())
            entry.paused = paused
            if not paused:
                entry.last_error = ""
            self._persist_sync()
            resp = self._to_response(sid, entry)
        if not paused:
            self._wakeup.set()
        return resp

    async def pause_if_non_empty(self, sid: str) -> bool:
        async with self._lock_for(sid):
            entry = self._queues.get(sid)
            if not entry or not entry.items:
                return False
            entry.paused = True
            self._persist_sync()
            return True

    async def _send_single_item(self, sid: str, item: QueuedMessageItem) -> ActionAckResponse:
        if self.provider.platform_name == "deck" and self.provider.is_managed_process_running(sid):
            await self.provider.stop_session(sid)
        return await self.provider.send_message(sid, content=item.content, model=item.model)

    async def send_item_now(self, sid: str, item_id: str) -> ActionAckResponse:
        async with self._lock_for(sid):
            entry = self._queues.get(sid)
            if not entry:
                return ActionAckResponse(ok=False, session_id=sid, message="队列中没有待发消息")
            target_idx: int | None = None
            for idx, item in enumerate(entry.items):
                if item.id == item_id:
                    target_idx = idx
                    break
            if target_idx is None:
                return ActionAckResponse(ok=False, session_id=sid, message="未找到该条队列消息")

            target = entry.items.pop(target_idx)
            try:
                ack = await self._send_single_item(sid, target)
            except Exception as exc:
                ack = ActionAckResponse(ok=False, session_id=sid, message=str(exc))

            if ack.ok:
                entry.last_dispatched_at = time.monotonic()
                entry.last_error = ""
                if not entry.items:
                    entry.paused = False
            else:
                entry.items.insert(target_idx, target)
                entry.last_error = ack.message or "发送失败"
            self._persist_sync()
            return ack

    async def _try_dispatch_session(self, sid: str) -> None:
        async with self._lock_for(sid):
            entry = self._queues.get(sid)
            if not entry or entry.paused or not entry.items:
                return
            if self.cooldown_seconds > 0 and entry.last_dispatched_at > 0:
                if (time.monotonic() - entry.last_dispatched_at) < self.cooldown_seconds:
                    return
            try:
                is_running = await self.provider.is_session_running(sid)
            except Exception as exc:
                logger.warning("is_session_running failed during queue dispatch for %s: %s", sid, exc)
                return
            if is_running:
                return

            head = entry.items.pop(0)
            try:
                ack = await self.provider.send_message(sid, content=head.content, model=head.model)
            except Exception as exc:
                ack = ActionAckResponse(ok=False, session_id=sid, message=str(exc))

            if ack.ok:
                entry.last_dispatched_at = time.monotonic()
                entry.last_error = ""
            else:
                entry.items.insert(0, head)
                entry.paused = True
                entry.last_error = ack.message or "自动派发失败"
                logger.warning("Queue auto-paused for %s: %s", sid, entry.last_error)
            self._persist_sync()

    async def _dispatch_loop(self) -> None:
        try:
            while not self._stopped:
                if not self._has_active_work():
                    self._wakeup.clear()
                    if not self._has_active_work() and not self._stopped:
                        await self._wakeup.wait()
                    continue

                active_sids = [
                    sid for sid, entry in list(self._queues.items()) if not entry.paused and entry.items
                ]
                for sid in active_sids:
                    if self._stopped:
                        break
                    await self._try_dispatch_session(sid)

                await asyncio.sleep(self.poll_interval)
        except asyncio.CancelledError:
            pass
