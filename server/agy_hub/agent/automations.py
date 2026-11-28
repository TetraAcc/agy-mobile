"""Local Antigravity native scheduled sidecar (Automations) store."""

from __future__ import annotations

import json
import os
import re
import shutil
from pathlib import Path
from typing import Any
from urllib.parse import quote, unquote, urlparse

from agy_hub.common.schemas import (
    AutomationItem,
    AutomationListResponse,
    AutomationLogsResponse,
    AutomationRunEvent,
    AutomationUpsertRequest,
)

_AUTOMATION_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_TZ_RE = re.compile(r"^[A-Za-z0-9_/+.-]{1,64}$")
_NEXT_EXEC_RE = re.compile(r"Next execution scheduled\s+(.+)$")


class AutomationError(Exception):
    """Domain error mapped to HTTP status codes by Agent routes."""

    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.message = message


def _slugify_id(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9_-]+", "-", raw.strip().lower()).strip("-_")
    if not cleaned:
        return ""
    if not cleaned[0].isalnum():
        cleaned = f"a-{cleaned}"
    return cleaned[:64]


def _validate_id(aid: str) -> str:
    clean = aid.strip()
    if not _AUTOMATION_ID_RE.fullmatch(clean):
        raise AutomationError(
            400,
            "自动化 ID 须由小写字母、数字、'-' 或 '_' 组成（1-64位且以字母或数字开头）",
        )
    return clean


def _path_to_file_uri(path: str) -> str:
    norm = path.strip().replace("\\", "/")
    if not norm:
        return ""
    if norm.startswith("file://"):
        return norm
    if len(norm) >= 2 and norm[1] == ":":
        # Windows drive path: file:///C:/foo/bar
        drive = norm[:2]
        rest = quote(norm[2:], safe="/")
        if not rest.startswith("/"):
            rest = f"/{rest}"
        return f"file:///{drive}{rest}"
    if not norm.startswith("/"):
        norm = f"/{norm}"
    return f"file://{quote(norm, safe='/')}"


def _file_uri_to_path(uri: str) -> str:
    raw = uri.strip()
    if not raw:
        return ""
    if not raw.startswith("file://"):
        return raw
    parsed = urlparse(raw)
    path_str = unquote(parsed.path or "")
    if re.match(r"^/[A-Za-z]:/", path_str):
        return path_str[1:]
    return path_str


def _parse_schedule_arg(raw: str) -> tuple[str, str]:
    """Return (timezone, 5-field cron_expr) from 'CRON_TZ=<tz> <cron>' or '<cron>'."""
    text = raw.strip()
    if not text:
        return "", ""
    parts = text.split()
    tz = ""
    if parts and (parts[0].startswith("CRON_TZ=") or parts[0].startswith("TZ=")):
        tz = parts[0].split("=", 1)[1].strip()
        parts = parts[1:]
    return tz, " ".join(parts)


def _format_schedule_arg(cron_expr: str, timezone: str) -> tuple[str, str, str]:
    clean_cron = " ".join(cron_expr.strip().split())
    if len(clean_cron.split()) != 5:
        raise AutomationError(400, "Cron 表达式必须包含标准 5 个字段（分 时 日 月 周）")
    clean_tz = timezone.strip() or "Asia/Tokyo"
    if not _TZ_RE.fullmatch(clean_tz):
        raise AutomationError(400, "时区格式非法，请使用 IANA 时区名（如 Asia/Tokyo）")
    return f"CRON_TZ={clean_tz} {clean_cron}", clean_cron, clean_tz


def _extract_prompt_from_args(args: list[Any]) -> tuple[str, str]:
    """Return (schedule_raw, prompt) from sidecar.json args array."""
    str_args = [str(a) for a in args]
    schedule_raw = str_args[0] if str_args else ""
    if "--" in str_args:
        idx = str_args.index("--")
        if idx + 1 < len(str_args):
            return schedule_raw, str_args[idx + 1]
    if len(str_args) >= 4:
        return schedule_raw, str_args[-1]
    return schedule_raw, ""


class AutomationStore:
    """Thread-safe / atomic reader and editor for native Antigravity scheduled sidecars."""

    def __init__(self, config_dir: Path | None = None, data_dir: Path | None = None) -> None:
        self.config_dir = (config_dir or (Path.home() / ".gemini" / "config")).resolve()
        self.data_dir = (data_dir or (Path.home() / ".gemini" / "antigravity" / "sidecar_data")).resolve()
        self.sidecars_dir = self.config_dir / "sidecars"
        self.config_json_path = self.config_dir / "config.json"

    def _sidecar_json_path(self, aid: str) -> Path:
        clean = _validate_id(aid)
        target_dir = (self.sidecars_dir / clean).resolve()
        if not target_dir.is_relative_to(self.sidecars_dir.resolve()):
            raise AutomationError(400, "非法的自动化目录路径")
        return target_dir / "sidecar.json"

    def _data_subdir(self, aid: str) -> Path:
        clean = _validate_id(aid)
        target = (self.data_dir / clean).resolve()
        if not target.is_relative_to(self.data_dir.resolve()):
            raise AutomationError(400, "非法的日志数据目录路径")
        return target

    def _read_config_json(self) -> dict[str, Any]:
        if not self.config_json_path.is_file():
            return {}
        try:
            raw = self.config_json_path.read_text(encoding="utf-8", errors="replace")
            data = json.loads(raw)
            return data if isinstance(data, dict) else {}
        except Exception as exc:
            raise AutomationError(500, f"读取 config.json 失败: {exc}") from exc

    def _write_json_atomic(self, path: Path, payload: dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = path.with_suffix(path.suffix + ".tmp")
        tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp_path, path)

    def _read_recent_events(self, aid: str, limit: int = 20) -> tuple[int, list[AutomationRunEvent]]:
        events_dir = self._data_subdir(aid) / "events"
        if not events_dir.is_dir():
            return 0, []
        files = sorted(events_dir.glob("*.json"), key=lambda p: p.name, reverse=True)
        total_count = len(files)
        parsed: list[AutomationRunEvent] = []
        for fpath in files[: max(1, limit)]:
            try:
                raw = json.loads(fpath.read_text(encoding="utf-8", errors="replace"))
                if not isinstance(raw, dict):
                    continue
                ts_ms = int(raw.get("timestampMs") or 0)
                started_ms = int(raw.get("commandInvocationTimestampMs") or 0)
                err = str(raw.get("error") or "").strip()
                payload = raw.get("payload")
                conv_id = ""
                if isinstance(payload, dict):
                    new_conv = payload.get("newConversation")
                    if isinstance(new_conv, dict):
                        conv_id = str(new_conv.get("conversationId") or "").strip()
                parsed.append(
                    AutomationRunEvent(
                        event_id=fpath.stem,
                        timestamp_ms=ts_ms,
                        started_at_ms=started_ms,
                        ok=(err == ""),
                        error=err,
                        conversation_id=conv_id,
                    )
                )
            except Exception:
                continue
        parsed.sort(key=lambda e: (e.timestamp_ms, e.event_id), reverse=True)
        return total_count, parsed

    def _read_next_run_text(self, aid: str) -> str:
        log_file = self._data_subdir(aid) / "logs" / "sidecar.log"
        if not log_file.is_file():
            return ""
        try:
            lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
        except Exception:
            return ""
        for line in reversed(lines[-80:]):
            m = _NEXT_EXEC_RE.search(line)
            if m:
                return m.group(1).strip()
        return ""

    def _build_item(
        self,
        aid: str,
        sidecar_data: dict[str, Any],
        sidecar_cfg_map: dict[str, Any],
        *,
        event_limit: int = 20,
    ) -> AutomationItem | None:
        if str(sidecar_data.get("builtin") or "").strip() != "schedule":
            return None

        args = sidecar_data.get("args")
        schedule_raw, prompt = _extract_prompt_from_args(args if isinstance(args, list) else [])
        tz, cron_expr = _parse_schedule_arg(schedule_raw)

        perms = sidecar_data.get("agent_permissions")
        if not isinstance(perms, dict):
            perms = {}
        ws_uris = [str(u) for u in (perms.get("workspace_uris") or []) if str(u).strip()]
        grants = [str(g) for g in (perms.get("access_grants") or []) if str(g).strip()]
        ws_path = _file_uri_to_path(ws_uris[0]) if ws_uris else ""

        cfg_entry = sidecar_cfg_map.get(aid)
        enabled = bool(cfg_entry.get("enabled")) if isinstance(cfg_entry, dict) else False

        event_count, events = self._read_recent_events(aid, limit=event_limit)
        last_evt = events[0] if events else None
        next_run_text = self._read_next_run_text(aid) if enabled else ""

        return AutomationItem(
            id=aid,
            display_name=str(sidecar_data.get("display_name") or aid),
            description=str(sidecar_data.get("description") or ""),
            enabled=enabled,
            cron_expr=cron_expr,
            timezone=tz,
            schedule_raw=schedule_raw,
            prompt=prompt,
            workspace_path=ws_path,
            workspace_uris=ws_uris,
            access_grants=grants,
            next_run_text=next_run_text,
            last_run_at_ms=last_evt.timestamp_ms if last_evt else 0,
            last_run_ok=last_evt.ok if last_evt else None,
            last_run_error=last_evt.error if last_evt else "",
            event_count=event_count,
            recent_events=events,
        )

    def list_automations(self, *, event_limit: int = 20) -> AutomationListResponse:
        if not self.sidecars_dir.is_dir():
            return AutomationListResponse(items=[], config_dir=str(self.config_dir))

        cfg = self._read_config_json()
        sidecar_cfg_map = cfg.get("sidecars")
        if not isinstance(sidecar_cfg_map, dict):
            sidecar_cfg_map = {}

        items: list[AutomationItem] = []
        for entry in sorted(self.sidecars_dir.iterdir(), key=lambda p: p.name):
            if not entry.is_dir():
                continue
            sc_file = entry / "sidecar.json"
            if not sc_file.is_file():
                continue
            if not _AUTOMATION_ID_RE.fullmatch(entry.name):
                continue
            try:
                sc_data = json.loads(sc_file.read_text(encoding="utf-8", errors="replace"))
                if not isinstance(sc_data, dict):
                    continue
                item = self._build_item(entry.name, sc_data, sidecar_cfg_map, event_limit=event_limit)
                if item is not None:
                    items.append(item)
            except Exception:
                continue

        items.sort(
            key=lambda x: (
                0 if x.enabled else 1,
                -x.last_run_at_ms,
                x.display_name.lower(),
            )
        )
        return AutomationListResponse(items=items, config_dir=str(self.config_dir))

    def get_automation(self, aid: str, *, event_limit: int = 20) -> AutomationItem:
        sc_file = self._sidecar_json_path(aid)
        if not sc_file.is_file():
            raise AutomationError(404, f"自动化 '{aid}' 不存在")
        try:
            sc_data = json.loads(sc_file.read_text(encoding="utf-8", errors="replace"))
        except Exception as exc:
            raise AutomationError(500, f"读取自动化配置失败: {exc}") from exc
        if not isinstance(sc_data, dict) or str(sc_data.get("builtin") or "").strip() != "schedule":
            raise AutomationError(404, f"自动化 '{aid}' 不是定时自动化任务")

        cfg = self._read_config_json()
        sidecar_cfg_map = cfg.get("sidecars") if isinstance(cfg.get("sidecars"), dict) else {}
        item = self._build_item(aid.strip(), sc_data, sidecar_cfg_map, event_limit=event_limit)
        if item is None:
            raise AutomationError(404, f"自动化 '{aid}' 不存在")
        return item

    def _merge_workspace_permissions(
        self,
        existing_perms: dict[str, Any] | None,
        workspace_path: str,
        *,
        preserve_permissions: bool,
    ) -> dict[str, Any] | None:
        ws_clean = workspace_path.strip().replace("\\", "/")
        ws_uri = _path_to_file_uri(ws_clean) if ws_clean else ""
        base_uris = list(existing_perms.get("workspace_uris") or []) if (preserve_permissions and existing_perms) else []
        base_grants = list(existing_perms.get("access_grants") or []) if (preserve_permissions and existing_perms) else []

        uris = [str(u) for u in base_uris if str(u).strip()]
        grants = [str(g) for g in base_grants if str(g).strip()]

        if ws_uri:
            uris = [ws_uri, *[u for u in uris if u != ws_uri]]
            for candidate in (f"read_file({ws_clean})", f"write_file({ws_clean})"):
                if candidate not in grants:
                    grants.append(candidate)

        if not uris and not grants:
            return None
        out: dict[str, Any] = {}
        if uris:
            out["workspace_uris"] = uris
        if grants:
            out["access_grants"] = grants
        return out

    def create_automation(self, req: AutomationUpsertRequest) -> AutomationItem:
        raw_id = req.id.strip() or _slugify_id(req.display_name)
        aid = _validate_id(raw_id)
        sc_file = self._sidecar_json_path(aid)
        if sc_file.exists():
            raise AutomationError(409, f"自动化 ID '{aid}' 已存在")

        display_name = req.display_name.strip()
        prompt = req.prompt.strip()
        if not display_name or not prompt:
            raise AutomationError(400, "任务名称与执行指令 Prompt 不能为空")

        schedule_raw, _cron, _tz = _format_schedule_arg(req.cron_expr, req.timezone)
        payload: dict[str, Any] = {
            "builtin": "schedule",
            "args": [schedule_raw, "agentapi", "new-conversation", "--", prompt],
            "restart_policy": "always",
            "display_name": display_name,
            "description": req.description.strip(),
        }
        perms = self._merge_workspace_permissions(
            None,
            req.workspace_path,
            preserve_permissions=False,
        )
        if perms is not None:
            payload["agent_permissions"] = perms

        self._write_json_atomic(sc_file, payload)
        if req.enabled is not None:
            self._set_config_enabled(aid, bool(req.enabled))
        return self.get_automation(aid)

    def update_automation(self, aid: str, req: AutomationUpsertRequest) -> AutomationItem:
        clean_id = _validate_id(aid)
        sc_file = self._sidecar_json_path(clean_id)
        if not sc_file.is_file():
            raise AutomationError(404, f"自动化 '{clean_id}' 不存在")
        try:
            existing = json.loads(sc_file.read_text(encoding="utf-8", errors="replace"))
        except Exception as exc:
            raise AutomationError(500, f"读取自动化配置失败: {exc}") from exc
        if not isinstance(existing, dict) or str(existing.get("builtin") or "").strip() != "schedule":
            raise AutomationError(404, f"自动化 '{clean_id}' 不是定时自动化任务")

        display_name = req.display_name.strip()
        prompt = req.prompt.strip()
        if not display_name or not prompt:
            raise AutomationError(400, "任务名称与执行指令 Prompt 不能为空")

        schedule_raw, _cron, _tz = _format_schedule_arg(req.cron_expr, req.timezone)
        updated = dict(existing)
        updated["builtin"] = "schedule"
        updated["restart_policy"] = str(existing.get("restart_policy") or "always")
        updated["display_name"] = display_name
        updated["description"] = req.description.strip()
        updated["args"] = [schedule_raw, "agentapi", "new-conversation", "--", prompt]

        old_perms = existing.get("agent_permissions") if isinstance(existing.get("agent_permissions"), dict) else None
        merged_perms = self._merge_workspace_permissions(
            old_perms,
            req.workspace_path,
            preserve_permissions=req.preserve_permissions,
        )
        if merged_perms is not None:
            updated["agent_permissions"] = merged_perms
        elif not req.preserve_permissions and "agent_permissions" in updated:
            updated.pop("agent_permissions", None)

        self._write_json_atomic(sc_file, updated)
        if req.enabled is not None:
            self._set_config_enabled(clean_id, bool(req.enabled))
        return self.get_automation(clean_id)

    def _set_config_enabled(self, aid: str, enabled: bool) -> None:
        cfg = self._read_config_json()
        sidecars = cfg.get("sidecars")
        if not isinstance(sidecars, dict):
            sidecars = {}
            cfg["sidecars"] = sidecars
        entry = sidecars.get(aid)
        if not isinstance(entry, dict):
            entry = {"schemaVersion": 1}
        else:
            entry = dict(entry)
        entry["enabled"] = bool(enabled)
        sidecars[aid] = entry
        self._write_json_atomic(self.config_json_path, cfg)

    def toggle_automation(self, aid: str, enabled: bool) -> AutomationItem:
        clean_id = _validate_id(aid)
        # Ensure target exists and is a scheduled sidecar
        self.get_automation(clean_id)
        self._set_config_enabled(clean_id, enabled)
        return self.get_automation(clean_id)

    def delete_automation(self, aid: str) -> None:
        clean_id = _validate_id(aid)
        # Ensure target exists and is a scheduled sidecar before touching disk
        self.get_automation(clean_id)
        target_dir = (self.sidecars_dir / clean_id).resolve()
        if target_dir.is_dir():
            shutil.rmtree(target_dir)

        if self.config_json_path.is_file():
            cfg = self._read_config_json()
            sidecars = cfg.get("sidecars")
            if isinstance(sidecars, dict) and clean_id in sidecars:
                sidecars.pop(clean_id, None)
                self._write_json_atomic(self.config_json_path, cfg)

    def get_logs(self, aid: str, *, tail: int = 80) -> AutomationLogsResponse:
        clean_id = _validate_id(aid)
        self.get_automation(clean_id)
        log_file = self._data_subdir(clean_id) / "logs" / "sidecar.log"
        if not log_file.is_file():
            return AutomationLogsResponse(id=clean_id, log_file=str(log_file), lines=[])
        try:
            all_lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
        except Exception as exc:
            raise AutomationError(500, f"读取调度日志失败: {exc}") from exc
        clamped = max(1, min(tail, 500))
        return AutomationLogsResponse(id=clean_id, log_file=str(log_file), lines=all_lines[-clamped:])
