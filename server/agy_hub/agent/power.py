"""Node-level auto shutdown/sleep scheduler once all tasks, queues, and approvals clear."""

from __future__ import annotations

import asyncio
import logging
import math
import time
from typing import Awaitable, Callable, Literal

from agy_hub.agent.message_queue import SessionMessageQueueManager
from agy_hub.agent.providers.base import BaseEngineProvider
from agy_hub.common.schemas import NodePowerStatusResponse

logger = logging.getLogger(__name__)

PowerAction = Literal["shutdown", "sleep"]
PowerState = Literal["off", "waiting_for_activity", "armed", "settling", "countdown", "executing"]
PowerExecutor = Callable[[str, PowerAction], Awaitable[None]]


async def default_power_executor(platform_name: str, action: PowerAction) -> None:
    """Invoke native OS shutdown/sleep command on Windows or Linux/Steam Deck."""
    if platform_name == "windows":
        if action == "sleep":
            cmd = [
                "powershell",
                "-NoProfile",
                "-Command",
                "Add-Type -AssemblyName System.Windows.Forms; "
                "[System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)",
            ]
        else:
            cmd = [
                "shutdown",
                "/s",
                "/t",
                "5",
                "/c",
                "AGY Remote Hub: all tasks completed",
            ]
    else:
        cmd = ["systemctl", "suspend"] if action == "sleep" else ["systemctl", "poweroff"]

    logger.warning("Executing node power action=%s platform=%s cmd=%s", action, platform_name, cmd)
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _, err_b = await proc.communicate()
    if proc.returncode not in (0, None):
        err_msg = err_b.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Power command failed ({proc.returncode}): {err_msg}")


class NodePowerManager:
    """In-memory node power guard triggered only after global task/queue/approval idleness."""

    def __init__(
        self,
        provider: BaseEngineProvider,
        queue_manager: SessionMessageQueueManager,
        *,
        enabled: bool = True,
        poll_interval: float = 1.0,
        executor: PowerExecutor | None = None,
    ) -> None:
        self.provider = provider
        self.queue_manager = queue_manager
        self.enabled = bool(enabled)
        self.poll_interval = max(0.02, float(poll_interval))
        self._executor = executor or default_power_executor

        self._lock = asyncio.Lock()
        self._state: PowerState = "off"
        self._action: PowerAction = "shutdown"
        self._settle_seconds: float = 20.0
        self._countdown_seconds: float = 60.0
        self._armed_by: str = ""
        self._armed_at: float = 0.0
        self._idle_since: float = 0.0
        self._trigger_at: float = 0.0
        self._observed_session_ids: set[str] = set()
        self._running_count: int = 0
        self._queued_count: int = 0
        self._approval_count: int = 0
        self._message: str = ""
        self._task: asyncio.Task[None] | None = None

    @staticmethod
    def _action_label(action: PowerAction) -> str:
        return "睡眠" if action == "sleep" else "关机"

    async def _sample_busy_state(self) -> tuple[set[str], int, int]:
        running_ids: set[str] = set()
        try:
            tree = await self.provider.get_session_tree()
            running_ids = {str(sid) for sid in tree.running_session_ids if sid}
        except Exception as exc:
            logger.debug("Power watcher failed reading session tree: %s", exc)

        queued_count = self.queue_manager.total_pending_count()
        approval_count = 0
        if self.provider.supports_tool_approval:
            check_ids = running_ids | self._observed_session_ids
            for sid in check_ids:
                try:
                    items = await self.provider.get_pending_approvals(sid)
                    approval_count += len(items)
                except Exception:
                    continue

        return running_ids, queued_count, approval_count

    def _build_status(self, now: float | None = None) -> NodePowerStatusResponse:
        if not self.enabled:
            return NodePowerStatusResponse(
                supported=False,
                enabled=False,
                state="off",
                message="节点配置已禁用远程电源控制",
            )

        cur_now = now if now is not None else time.monotonic()
        is_enabled = self._state != "off"
        remaining = 0
        if self._state == "settling" and self._idle_since > 0:
            remaining = max(0, math.ceil(self._settle_seconds - (cur_now - self._idle_since)))
        elif self._state == "countdown" and self._trigger_at > 0:
            remaining = max(0, math.ceil(self._trigger_at - cur_now))

        return NodePowerStatusResponse(
            supported=True,
            enabled=is_enabled,
            action=self._action,
            state=self._state,
            running_sessions=self._running_count,
            queued_messages=self._queued_count,
            pending_approvals=self._approval_count,
            settle_seconds=int(math.ceil(self._settle_seconds)),
            countdown_seconds=int(math.ceil(self._countdown_seconds)),
            remaining_seconds=remaining,
            armed_by=self._armed_by,
            armed_at=self._armed_at,
            trigger_at=self._trigger_at if self._state == "countdown" else 0.0,
            message=self._message,
        )

    def status(self) -> NodePowerStatusResponse:
        return self._build_status()

    async def refresh_status(self) -> NodePowerStatusResponse:
        if not self.enabled:
            return self.status()
        async with self._lock:
            if self._state in ("off", "executing"):
                return self._build_status()
            running_ids, queued_count, approval_count = await self._sample_busy_state()
            self._apply_observation_locked(running_ids, queued_count, approval_count, time.monotonic())
            return self._build_status()

    def _apply_observation_locked(
        self,
        running_ids: set[str],
        queued_count: int,
        approval_count: int,
        now: float,
    ) -> bool:
        """Advance state machine for an observation; returns True if power action should fire now."""
        self._observed_session_ids.update(running_ids)
        self._running_count = len(running_ids)
        self._queued_count = queued_count
        self._approval_count = approval_count

        is_busy = bool(running_ids) or queued_count > 0 or approval_count > 0
        label = self._action_label(self._action)

        if self._state == "waiting_for_activity":
            if is_busy:
                self._state = "armed"
                self._idle_since = 0.0
                self._trigger_at = 0.0
                self._message = f"已检测到运行中的任务，全部结束后将自动{label}"
            else:
                self._message = f"待命中：当前无任务运行，将在下一轮任务启动并全部结束后自动{label}"
            return False

        if self._state == "armed":
            if not is_busy:
                if self._settle_seconds <= 0:
                    self._state = "countdown"
                    self._idle_since = now
                    self._trigger_at = now + self._countdown_seconds
                    self._message = f"任务已全部结束，将在 {math.ceil(self._countdown_seconds)}s 后自动{label}"
                else:
                    self._state = "settling"
                    self._idle_since = now
                    self._message = f"任务已全部完成，正在确认无新任务（防抖 {math.ceil(self._settle_seconds)}s）"
            else:
                self._message = self._busy_summary(label)
            return False

        if self._state == "settling":
            if is_busy:
                self._state = "armed"
                self._idle_since = 0.0
                self._message = self._busy_summary(label)
                return False
            if (now - self._idle_since) >= self._settle_seconds:
                self._state = "countdown"
                self._trigger_at = now + self._countdown_seconds
                self._message = f"已确认节点空闲，将在 {math.ceil(self._countdown_seconds)}s 后自动{label}"
            else:
                left = max(1, math.ceil(self._settle_seconds - (now - self._idle_since)))
                self._message = f"已确认节点空闲，防抖确认剩余 {left}s 后进入关机倒计时"
            return False

        if self._state == "countdown":
            if is_busy:
                self._state = "armed"
                self._idle_since = 0.0
                self._trigger_at = 0.0
                self._message = f"检测到新任务活动，已中断倒计时并继续监听（{self._busy_summary(label)}）"
                return False
            if now >= self._trigger_at:
                self._state = "executing"
                self._message = f"倒计时结束，正在执行系统{label}..."
                return True
            left = max(1, math.ceil(self._trigger_at - now))
            self._message = f"节点已空闲，将在 {left}s 后自动{label}（可随时取消）"
            return False

        return False

    def _busy_summary(self, label: str) -> str:
        parts: list[str] = []
        if self._running_count > 0:
            parts.append(f"{self._running_count} 个运行中会话")
        if self._approval_count > 0:
            parts.append(f"{self._approval_count} 个待审批工具调用")
        if self._queued_count > 0:
            parts.append(f"{self._queued_count} 条排队消息")
        detail = "、".join(parts) if parts else "活动任务"
        return f"监听中（{detail}），全部完成后自动{label}"

    async def schedule(
        self,
        action: PowerAction = "shutdown",
        *,
        armed_by: str = "",
        settle_seconds: float = 20.0,
        countdown_seconds: float = 60.0,
    ) -> NodePowerStatusResponse:
        if not self.enabled:
            raise PermissionError("Remote power control is disabled on this node")

        async with self._lock:
            self._action = action
            self._settle_seconds = max(0.0, float(settle_seconds))
            self._countdown_seconds = max(0.05, float(countdown_seconds))
            self._armed_by = armed_by
            self._armed_at = time.time()
            self._idle_since = 0.0
            self._trigger_at = 0.0
            self._observed_session_ids.clear()

            running_ids, queued_count, approval_count = await self._sample_busy_state()
            self._observed_session_ids.update(running_ids)
            self._running_count = len(running_ids)
            self._queued_count = queued_count
            self._approval_count = approval_count

            is_busy = bool(running_ids) or queued_count > 0 or approval_count > 0
            label = self._action_label(action)
            if is_busy:
                self._state = "armed"
                self._message = self._busy_summary(label)
            else:
                self._state = "waiting_for_activity"
                self._message = f"待命中：当前无任务运行，将在下一轮任务启动并全部结束后自动{label}"

            if self._task is None or self._task.done():
                self._task = asyncio.create_task(self._watch_loop(), name="agy-node-power-watch")

            return self._build_status()

    async def cancel(self, reason: str = "") -> NodePowerStatusResponse:
        task_to_wait: asyncio.Task[None] | None = None
        async with self._lock:
            self._state = "off"
            self._idle_since = 0.0
            self._trigger_at = 0.0
            self._armed_by = ""
            self._armed_at = 0.0
            self._observed_session_ids.clear()
            self._running_count = 0
            self._queued_count = 0
            self._approval_count = 0
            self._message = reason or "已取消自动电源预约"
            if self._task is not None and not self._task.done():
                self._task.cancel()
                task_to_wait = self._task
            self._task = None
            resp = self._build_status()

        if task_to_wait is not None:
            try:
                await task_to_wait
            except asyncio.CancelledError:
                pass
        return resp

    async def shutdown(self) -> None:
        await self.cancel(reason="Node agent shutting down")

    async def _watch_loop(self) -> None:
        try:
            while True:
                await asyncio.sleep(self.poll_interval)
                should_execute = False
                action_to_run: PowerAction = "shutdown"

                async with self._lock:
                    if self._state in ("off", "executing"):
                        return
                    running_ids, queued_count, approval_count = await self._sample_busy_state()
                    should_execute = self._apply_observation_locked(
                        running_ids,
                        queued_count,
                        approval_count,
                        time.monotonic(),
                    )
                    action_to_run = self._action

                if should_execute:
                    try:
                        await self._executor(self.provider.platform_name, action_to_run)
                    except Exception as exc:
                        logger.exception("Failed executing node power action=%s", action_to_run)
                        async with self._lock:
                            self._state = "off"
                            self._message = f"执行系统{self._action_label(action_to_run)}失败: {exc}"
                    else:
                        async with self._lock:
                            self._state = "off"
                    return
        except asyncio.CancelledError:
            return
