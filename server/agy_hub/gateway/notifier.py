"""Gateway-side Discord Webhook notification monitor for long-running / blocked Antigravity sessions."""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

import httpx

from agy_hub.common.security import sign_internal_request
from agy_hub.gateway.config import GatewayConfig, NodeConfig
from agy_hub.gateway.registry import NodeRegistryManager

logger = logging.getLogger(__name__)

WebhookSender = Callable[[str, dict[str, Any]], Awaitable[tuple[bool, str]]]

_COLOR_SUCCESS = 0x10B981
_COLOR_WARN = 0xF59E0B
_COLOR_ERROR = 0xEF4444
_COLOR_INFO = 0x3B82F6


def _format_duration_label(seconds: float) -> str:
    total = max(0, int(seconds))
    if total < 60:
        return f"{total}s"
    mins, secs = divmod(total, 60)
    if mins < 60:
        return f"{mins}m {secs}s" if secs else f"{mins}m"
    hours, mins = divmod(mins, 60)
    return f"{hours}h {mins}m" if mins else f"{hours}h"


def _truncate_text(raw: str, max_len: int = 220) -> str:
    cleaned = " ".join((raw or "").strip().split())
    if len(cleaned) <= max_len:
        return cleaned
    return cleaned[: max_len - 1] + "…"


@dataclass
class _TrackedSessionState:
    running: bool = False
    started_at: float = 0.0
    title: str = ""
    project_name: str = ""
    ask_step_index: int | None = None
    ask_first_seen_at: float | None = None
    notified_ask_step: int | None = None
    approval_id: str | None = None
    approval_first_seen_at: float | None = None
    notified_approval_id: str | None = None


class DiscordNotificationMonitor:
    """Monitors online Node Agents and sends Discord Embed notifications when tasks finish, fail, or block."""

    def __init__(
        self,
        config: GatewayConfig,
        registry: NodeRegistryManager,
        http_client: httpx.AsyncClient,
        *,
        webhook_sender: WebhookSender | None = None,
        time_fn: Callable[[], float] | None = None,
    ) -> None:
        self.config = config
        self.registry = registry
        self.http_client = http_client
        self._webhook_sender = webhook_sender
        self._time_fn = time_fn or time.monotonic
        self._active_subs: dict[tuple[str, str], int] = {}
        self._tracked: dict[tuple[str, str], _TrackedSessionState] = {}
        self._primed_nodes: set[str] = set()
        self._task: asyncio.Task[None] | None = None

    @property
    def is_enabled(self) -> bool:
        return bool(self.config.discord_webhook_url.strip())

    def on_ws_subscription_change(self, node_id: str, session_id: str, is_subscribed: bool) -> None:
        key = (node_id, session_id)
        current = self._active_subs.get(key, 0)
        if is_subscribed:
            self._active_subs[key] = current + 1
        elif current <= 1:
            self._active_subs.pop(key, None)
        else:
            self._active_subs[key] = current - 1

    def has_active_subscriber(self, node_id: str, session_id: str) -> bool:
        return self._active_subs.get((node_id, session_id), 0) > 0

    def _signed_get_headers(self, upstream_path: str) -> dict[str, str]:
        return sign_internal_request(
            secret=self.config.internal_secret,
            method="GET",
            path=upstream_path,
            user="gateway_notifier",
            permissions='{"can_delete":false,"can_write":false}',
        )

    async def _node_get_json(self, node_cfg: NodeConfig, upstream_path: str, params: dict[str, Any] | None = None) -> dict[str, Any] | None:
        try:
            resp = await self.http_client.get(
                f"{node_cfg.base_url}{upstream_path}",
                params=params,
                headers=self._signed_get_headers(upstream_path),
                timeout=max(3.0, node_cfg.health_timeout_seconds + 2.0),
            )
            if resp.status_code == 200:
                data = resp.json()
                return data if isinstance(data, dict) else None
        except Exception as exc:
            logger.debug("Notifier GET %s%s failed: %s", node_cfg.base_url, upstream_path, exc)
        return None

    async def _post_webhook(self, payload: dict[str, Any]) -> tuple[bool, str]:
        url = self.config.discord_webhook_url.strip()
        if not url:
            return False, "未配置 discord_webhook_url"
        if self._webhook_sender is not None:
            return await self._webhook_sender(url, payload)
        try:
            resp = await self.http_client.post(url, json=payload, timeout=10.0)
            if 200 <= resp.status_code < 300:
                return True, "通知已发送到 Discord"
            detail = (resp.text or "").strip()[:180]
            return False, f"Discord 返回 HTTP {resp.status_code}: {detail}"
        except Exception as exc:
            return False, f"请求 Discord Webhook 失败: {exc}"

    def _build_embed_payload(
        self,
        *,
        title: str,
        description: str,
        color: int,
        node_cfg: NodeConfig,
        session_title: str,
        project_name: str = "",
        duration_label: str = "",
    ) -> dict[str, Any]:
        fields: list[dict[str, Any]] = [
            {"name": "节点", "value": node_cfg.name, "inline": True},
        ]
        if project_name:
            fields.append({"name": "项目", "value": _truncate_text(project_name, 80), "inline": True})
        if duration_label:
            fields.append({"name": "耗时", "value": duration_label, "inline": True})
        fields.append({"name": "会话", "value": _truncate_text(session_title or "未命名会话", 100), "inline": False})

        embed: dict[str, Any] = {
            "title": _truncate_text(title, 250),
            "description": _truncate_text(description, 1500) if description else "请在手机端查看详情。",
            "color": color,
            "fields": fields,
            "footer": {"text": "AGY Remote Hub"},
        }
        pub_url = self.config.public_base_url.strip().rstrip("/")
        if pub_url:
            embed["url"] = pub_url
        return {"username": "AGY Remote Hub", "embeds": [embed]}

    @staticmethod
    def _extract_ask_question_preview(messages: list[dict[str, Any]]) -> tuple[int, str] | None:
        for msg in reversed(messages):
            if not isinstance(msg, dict):
                continue
            tool_calls = msg.get("tool_calls") or []
            if not isinstance(tool_calls, list):
                continue
            for tc in tool_calls:
                if not isinstance(tc, dict) or tc.get("name") != "ask_question":
                    continue
                step_idx = int(msg.get("step_index") or 0)
                args = tc.get("args") if isinstance(tc.get("args"), dict) else {}
                raw_qs = args.get("questions") if isinstance(args, dict) else None
                preview = "存在待确认交互选项，请打开客户端选择。"
                if isinstance(raw_qs, list) and raw_qs:
                    first = raw_qs[0]
                    if isinstance(first, dict) and first.get("question"):
                        preview = str(first["question"])
                return step_idx, preview
            # Stop at latest non-user response so stale ask_question calls don't re-trigger
            if msg.get("msg_type") != "USER_INPUT" and (msg.get("content") or tool_calls):
                break
        return None

    @staticmethod
    def _extract_pending_approval_preview(approvals: Any) -> tuple[str, str] | None:
        if not isinstance(approvals, list) or not approvals:
            return None
        first = approvals[0]
        if not isinstance(first, dict):
            return None
        approval_id = str(first.get("approval_id") or "").strip()
        if not approval_id:
            return None
        title = str(first.get("title") or "工具操作审批").strip()
        action = str(first.get("action_label") or "").strip()
        target = str(first.get("target") or "").strip()
        lines = [f"**{title}**" + (f" · {action}" if action else "")]
        if target:
            lines.append(f"`{_truncate_text(target, 220)}`")
        if len(approvals) > 1:
            lines.append(f"另有 {len(approvals) - 1} 项等待审批。")
        return approval_id, "\n".join(lines)

    @staticmethod
    def _extract_latest_reply(messages: list[dict[str, Any]]) -> tuple[str, str]:
        for msg in reversed(messages):
            if not isinstance(msg, dict):
                continue
            if msg.get("msg_type") == "USER_INPUT":
                continue
            status_val = str(msg.get("status") or "").upper()
            content = str(msg.get("content") or "").strip()
            if content or status_val == "ERROR":
                return status_val, content
        return "", ""

    async def send_test_notification(self) -> tuple[bool, str]:
        if not self.is_enabled:
            return False, "网关未配置 discord_webhook_url"
        online_names = [
            cfg.name for nid, cfg in self.config.nodes.items() if self.registry.is_node_online(nid)
        ]
        node_summary = "、".join(online_names) if online_names else "暂无在线节点"
        payload = {
            "username": "AGY Remote Hub",
            "embeds": [
                {
                    "title": "[测试通知] AGY Remote Discord Webhook 已连通",
                    "description": "当任务耗时达到阈值完成、异常中断，或 `ask_question` 等待超 10 秒未响应时，会自动向本频道发送卡片提醒。",
                    "color": _COLOR_INFO,
                    "fields": [
                        {"name": "在线节点", "value": node_summary, "inline": True},
                        {
                            "name": "完成提醒阈值",
                            "value": f">= {int(self.config.notify_min_run_seconds)}s",
                            "inline": True,
                        },
                        {
                            "name": "选项等待提醒",
                            "value": f">= {int(self.config.notify_ask_question_delay_seconds)}s",
                            "inline": True,
                        },
                    ],
                    "footer": {"text": "AGY Remote Hub"},
                }
            ],
        }
        return await self._post_webhook(payload)

    async def poll_once(self) -> None:
        if not self.is_enabled:
            return
        now = float(self._time_fn())

        for node_id, node_cfg in self.config.nodes.items():
            if not self.registry.is_node_online(node_id):
                continue
            tree = await self._node_get_json(node_cfg, "/agent/sessions")
            if not tree:
                continue

            is_primed = node_id in self._primed_nodes
            running_ids: set[str] = {
                str(sid) for sid in (tree.get("running_session_ids") or []) if sid
            }
            meta_map: dict[str, tuple[str, str]] = {}

            projects = tree.get("projects") or {}
            if isinstance(projects, dict):
                for proj_name, items in projects.items():
                    if not isinstance(items, list):
                        continue
                    for item in items:
                        if not isinstance(item, dict) or not item.get("id"):
                            continue
                        sid = str(item["id"])
                        meta_map[sid] = (str(item.get("title") or sid), str(proj_name))
                        if item.get("is_running"):
                            running_ids.add(sid)

            for item in tree.get("general_sessions") or []:
                if not isinstance(item, dict) or not item.get("id"):
                    continue
                sid = str(item["id"])
                meta_map[sid] = (str(item.get("title") or sid), "")
                if item.get("is_running"):
                    running_ids.add(sid)

            # Handle newly running or continuing running sessions
            for sid in running_ids:
                key = (node_id, sid)
                tracked = self._tracked.get(key)
                title, proj_name = meta_map.get(sid, (sid, ""))
                if tracked is None:
                    tracked = _TrackedSessionState()
                    self._tracked[key] = tracked
                tracked.title = title or tracked.title
                tracked.project_name = proj_name or tracked.project_name
                if not tracked.running:
                    tracked.running = True
                    tracked.started_at = now
                    tracked.ask_step_index = None
                    tracked.ask_first_seen_at = None
                    tracked.approval_id = None
                    tracked.approval_first_seen_at = None

                msg_data = await self._node_get_json(
                    node_cfg,
                    f"/agent/sessions/{sid}/messages",
                    params={"limit": 3},
                )
                messages = msg_data.get("messages") if isinstance(msg_data, dict) else None
                if isinstance(messages, list):
                    ask_info = self._extract_ask_question_preview(messages)
                    if ask_info is not None:
                        ask_step, preview = ask_info
                        if ask_step != tracked.notified_ask_step:
                            if tracked.ask_step_index != ask_step or tracked.ask_first_seen_at is None:
                                tracked.ask_step_index = ask_step
                                tracked.ask_first_seen_at = now
                            elif (now - tracked.ask_first_seen_at) >= self.config.notify_ask_question_delay_seconds:
                                tracked.notified_ask_step = ask_step
                                payload = self._build_embed_payload(
                                    title=f"[{node_cfg.name}] 需要你确认选项",
                                    description=preview,
                                    color=_COLOR_WARN,
                                    node_cfg=node_cfg,
                                    session_title=tracked.title,
                                    project_name=tracked.project_name,
                                )
                                ok, err_msg = await self._post_webhook(payload)
                                if not ok:
                                    logger.warning("Discord ask_question notification failed: %s", err_msg)
                    else:
                        tracked.ask_step_index = None
                        tracked.ask_first_seen_at = None

                approval_info = (
                    self._extract_pending_approval_preview(msg_data.get("pending_approvals"))
                    if isinstance(msg_data, dict)
                    else None
                )
                if approval_info is not None:
                    approval_id, preview = approval_info
                    if approval_id != tracked.notified_approval_id:
                        if tracked.approval_id != approval_id or tracked.approval_first_seen_at is None:
                            tracked.approval_id = approval_id
                            tracked.approval_first_seen_at = now
                        elif (now - tracked.approval_first_seen_at) >= self.config.notify_ask_question_delay_seconds:
                            tracked.notified_approval_id = approval_id
                            payload = self._build_embed_payload(
                                title=f"[{node_cfg.name}] 等待工具审批",
                                description=preview,
                                color=_COLOR_WARN,
                                node_cfg=node_cfg,
                                session_title=tracked.title,
                                project_name=tracked.project_name,
                            )
                            ok, err_msg = await self._post_webhook(payload)
                            if not ok:
                                logger.warning("Discord tool approval notification failed: %s", err_msg)
                else:
                    tracked.approval_id = None
                    tracked.approval_first_seen_at = None

            # Handle sessions that just transitioned from running -> idle
            for (t_node_id, sid), tracked in list(self._tracked.items()):
                if t_node_id != node_id or not tracked.running or sid in running_ids:
                    continue
                tracked.running = False
                tracked.ask_step_index = None
                tracked.ask_first_seen_at = None
                tracked.approval_id = None
                tracked.approval_first_seen_at = None
                if not is_primed:
                    continue

                elapsed = max(0.0, now - tracked.started_at) if tracked.started_at > 0 else 0.0
                msg_data = await self._node_get_json(
                    node_cfg,
                    f"/agent/sessions/{sid}/messages",
                    params={"limit": 3},
                )
                messages = msg_data.get("messages") if isinstance(msg_data, dict) else None
                last_status, reply_summary = (
                    self._extract_latest_reply(messages) if isinstance(messages, list) else ("", "")
                )

                if self.has_active_subscriber(node_id, sid):
                    continue

                if last_status == "ERROR":
                    payload = self._build_embed_payload(
                        title=f"[{node_cfg.name}] 任务异常中断",
                        description=reply_summary or "执行过程中发生错误，请打开客户端排查。",
                        color=_COLOR_ERROR,
                        node_cfg=node_cfg,
                        session_title=tracked.title,
                        project_name=tracked.project_name,
                        duration_label=_format_duration_label(elapsed),
                    )
                    ok, err_msg = await self._post_webhook(payload)
                    if not ok:
                        logger.warning("Discord error notification failed: %s", err_msg)
                elif elapsed >= self.config.notify_min_run_seconds:
                    payload = self._build_embed_payload(
                        title=f"[{node_cfg.name}] 任务已完成",
                        description=reply_summary or "后台任务已执行完毕。",
                        color=_COLOR_SUCCESS,
                        node_cfg=node_cfg,
                        session_title=tracked.title,
                        project_name=tracked.project_name,
                        duration_label=_format_duration_label(elapsed),
                    )
                    ok, err_msg = await self._post_webhook(payload)
                    if not ok:
                        logger.warning("Discord completion notification failed: %s", err_msg)

            if not is_primed:
                self._primed_nodes.add(node_id)

    def start(self) -> None:
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._monitor_loop())

    async def stop(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._task = None

    async def _monitor_loop(self) -> None:
        while True:
            try:
                await self.poll_once()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.warning("Discord notification monitor error: %s", exc)
            await asyncio.sleep(self.config.notify_poll_interval_seconds)
