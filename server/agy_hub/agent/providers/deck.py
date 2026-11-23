"""Steam Deck / Linux EngineProvider using managed agy CLI process groups and Keyring quota."""

from __future__ import annotations

import asyncio
import logging
import os
import re
import shutil
import signal
import time
from pathlib import Path

from agy_hub.agent.config import AgentConfig
from agy_hub.agent.providers.base import BaseEngineProvider
from agy_hub.common.sandbox import RootRegistry
from agy_hub.common.schemas import (
    ActionAckResponse,
    CreateSessionResponse,
    QuotaBucket,
    QuotaGroup,
    QuotaResponse,
)

logger = logging.getLogger(__name__)


class DeckEngineProvider(BaseEngineProvider):
    platform_name = "deck"

    def __init__(self, config: AgentConfig, registry: RootRegistry) -> None:
        self._brain_dir = Path(os.path.expanduser(config.brain_dir or "~/.gemini/antigravity-cli/brain")).resolve()
        self._db_path = Path(
            os.path.expanduser(config.db_path or "~/.gemini/antigravity-cli/conversation_summaries.db")
        ).resolve()
        self._default_workspace = Path(os.path.expanduser(config.default_workspace or "~/")).resolve()
        default_bin = shutil.which("agy") or os.path.expanduser("~/.local/bin/agy")
        self._agy_bin = Path(os.path.expanduser(config.agy_bin or default_bin))
        self._running_procs: dict[str, asyncio.subprocess.Process] = {}
        self._anonymous_procs: set[asyncio.subprocess.Process] = set()
        self._cached_quota: QuotaResponse | None = None
        self._last_quota_sync: float = 0.0
        super().__init__(config, registry)

    @property
    def brain_dir(self) -> Path:
        return self._brain_dir

    @property
    def db_path(self) -> Path:
        return self._db_path

    @property
    def default_workspace(self) -> Path:
        return self._default_workspace

    def is_managed_process_running(self, session_id: str) -> bool:
        proc = self._running_procs.get(session_id)
        return proc is not None and proc.returncode is None

    async def is_engine_alive(self) -> bool:
        return self._agy_bin.exists()

    def _build_cli_flags(self, model: str | None, mode: str = "auto") -> list[str]:
        cli_mode = mode if mode in ("auto", "accept-edits", "plan") else "auto"
        flags: list[str] = [f"--mode={cli_mode}"]
        if self.config.deck_permission_mode == "skip_permissions":
            flags.append("--dangerously-skip-permissions")
        if model:
            flags.append(f"--model={model}")
        return flags

    async def _reap_managed_process(self, key: str | None, proc: asyncio.subprocess.Process) -> None:
        try:
            await proc.wait()
        finally:
            if key and self._running_procs.get(key) is proc:
                self._running_procs.pop(key, None)
            self._anonymous_procs.discard(proc)

    async def send_message(
        self,
        session_id: str,
        content: str,
        model: str | None = None,
        workspace_path: str | None = None,
    ) -> ActionAckResponse:
        sid = self.validate_session_id(session_id)
        if not self._agy_bin.exists():
            return ActionAckResponse(ok=False, session_id=sid, message=f"agy CLI not found: {self._agy_bin}")

        target_cwd = self.default_workspace
        if workspace_path:
            ws_candidate = Path(os.path.expanduser(workspace_path))
            if ws_candidate.exists() and ws_candidate.is_dir():
                target_cwd = ws_candidate

        cmd = [str(self._agy_bin), f"--conversation={sid}", "-p", content, *self._build_cli_flags(model, "auto")]
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=str(target_cwd) if target_cwd.exists() else None,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
                start_new_session=True,
            )
            self._running_procs[sid] = proc
            asyncio.create_task(self._reap_managed_process(sid, proc))
            return ActionAckResponse(ok=True, session_id=sid, message="Deck CLI task started")
        except Exception as exc:
            return ActionAckResponse(ok=False, session_id=sid, message=f"Failed to start Deck CLI: {exc}")

    async def create_session(
        self,
        content: str,
        model: str | None = None,
        mode: str = "auto",
        workspace_path: str | None = None,
    ) -> CreateSessionResponse:
        if not self._agy_bin.exists():
            return CreateSessionResponse(ok=False, session_id="", message=f"agy CLI not found: {self._agy_bin}")

        target_cwd = self.default_workspace
        if workspace_path:
            ws_candidate = Path(os.path.expanduser(workspace_path))
            if ws_candidate.exists() and ws_candidate.is_dir():
                target_cwd = ws_candidate

        cmd = [str(self._agy_bin), "-p", content, *self._build_cli_flags(model, mode)]
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=str(target_cwd) if target_cwd.exists() else None,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
                start_new_session=True,
            )
            self._anonymous_procs.add(proc)
            asyncio.create_task(self._reap_managed_process(None, proc))
            return CreateSessionResponse(ok=True, session_id="", message="Deck CLI session started")
        except Exception as exc:
            return CreateSessionResponse(ok=False, session_id="", message=f"Failed to create Deck session: {exc}")

    async def stop_session(self, session_id: str) -> ActionAckResponse:
        sid = self.validate_session_id(session_id)
        proc = self._running_procs.get(sid)
        if proc is None or proc.returncode is not None:
            return ActionAckResponse(ok=False, session_id=sid, message="No active managed process for session")

        try:
            if hasattr(os, "killpg"):
                os.killpg(proc.pid, signal.SIGTERM)
            else:
                proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), timeout=3.0)
            except TimeoutError:
                if hasattr(os, "killpg"):
                    os.killpg(proc.pid, signal.SIGKILL)
                else:
                    proc.kill()
                await proc.wait()
            return ActionAckResponse(ok=True, session_id=sid, message="Managed process group terminated")
        except ProcessLookupError:
            return ActionAckResponse(ok=True, session_id=sid, message="Process already exited")
        except Exception as exc:
            return ActionAckResponse(ok=False, session_id=sid, message=f"Failed to stop process: {exc}")

    async def fetch_quota(self) -> QuotaResponse:
        if self._cached_quota and (time.time() - self._last_quota_sync) < 300.0:
            return self._cached_quota

        if not self._agy_bin.exists():
            return QuotaResponse(groups=[], description=f"agy CLI not found: {self._agy_bin}")

        output = ""
        for cmd in (
            ["systemd-run", "--user", "--pipe", str(self._agy_bin), "-p", "/quota"],
            [str(self._agy_bin), "-p", "/quota"],
        ):
            try:
                proc = await asyncio.create_subprocess_exec(
                    *cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout_b, stderr_b = await asyncio.wait_for(proc.communicate(), timeout=15.0)
                candidate = stdout_b.decode("utf-8", errors="replace").strip()
                if not candidate and cmd[0] != "systemd-run":
                    candidate = stderr_b.decode("utf-8", errors="replace").strip()
                if candidate:
                    output = candidate
                    break
            except Exception:
                continue

        groups = self.parse_cli_quota_output(output)
        if groups:
            self._cached_quota = QuotaResponse(groups=groups, description="Steam Deck CLI native quota")
            self._last_quota_sync = time.time()
            return self._cached_quota

        return self._cached_quota or QuotaResponse(groups=[], description="Failed to fetch Deck quota")

    @staticmethod
    def parse_cli_quota_output(raw_text: str) -> list[QuotaGroup]:
        groups_map: dict[str, QuotaGroup] = {}
        for line in raw_text.splitlines():
            stripped = line.strip()
            if not stripped or "Running as unit:" in stripped:
                continue
            parts = [p.strip() for p in stripped.split("\t") if p.strip()]
            if len(parts) < 3:
                parts = re.split(r"\s{2,}", stripped)
            if len(parts) < 3:
                continue

            group_name, bucket_name, percent_str = parts[0], parts[1], parts[2]
            reset_time = parts[3] if len(parts) > 3 else ""

            frac = 0.0
            disabled = False
            if "%" in percent_str:
                try:
                    frac = float(percent_str.replace("%", "").strip()) / 100.0
                except ValueError:
                    pass
            elif "disabled" in percent_str.lower():
                disabled = True
                frac = 1.0

            if group_name not in groups_map:
                groups_map[group_name] = QuotaGroup(
                    display_name=group_name,
                    description=f"Models within {group_name}",
                    buckets=[],
                )
            is_weekly = "weekly" in bucket_name.lower()
            groups_map[group_name].buckets.append(
                QuotaBucket(
                    bucket_id="weekly" if is_weekly else "5h",
                    display_name=bucket_name,
                    window="weekly" if is_weekly else "5h",
                    remaining_fraction=frac,
                    disabled=disabled,
                    reset_time=reset_time,
                )
            )
        return list(groups_map.values())
