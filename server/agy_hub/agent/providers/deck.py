"""Steam Deck / Linux EngineProvider using managed agy CLI process groups and Keyring quota."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import signal
import time
from datetime import datetime, timezone
from pathlib import Path

from agy_hub.agent.config import AgentConfig
from agy_hub.agent.providers.base import BaseEngineProvider
from agy_hub.common.sandbox import RootRegistry
from agy_hub.common.schemas import (
    ActionAckResponse,
    CreateSessionResponse,
    ModelOption,
    ModelsResponse,
    QuotaBucket,
    QuotaGroup,
    QuotaResponse,
    TranscriptStep,
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
        self._settings_path = self._brain_dir.parent / "settings.json"
        self._running_procs: dict[str, asyncio.subprocess.Process] = {}
        self._anonymous_procs: set[asyncio.subprocess.Process] = set()
        self._recent_cli_errors: dict[str, tuple[str, str]] = {}
        self._cached_quota: QuotaResponse | None = None
        self._last_quota_sync: float = 0.0
        self._cached_models: ModelsResponse | None = None
        self._last_models_sync: float = 0.0
        self._models_lock = asyncio.Lock()
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
            stdout_b, stderr_b = await proc.communicate()
            stopped_codes = {0, None}
            if hasattr(signal, "SIGTERM"):
                stopped_codes.add(-int(signal.SIGTERM))
            if hasattr(signal, "SIGKILL"):
                stopped_codes.add(-int(signal.SIGKILL))
            if proc.returncode not in stopped_codes:
                raw_err = (stderr_b or b"").decode("utf-8", errors="replace").strip() or (
                    stdout_b or b""
                ).decode("utf-8", errors="replace").strip()
                summary = raw_err[-600:].strip() if raw_err else f"agy CLI exited with code {proc.returncode}"
                logger.warning("Deck CLI exited abnormally (session=%s rc=%s): %s", key, proc.returncode, summary)
                if key and summary:
                    if key in self._recent_cli_errors:
                        self._recent_cli_errors.pop(key, None)
                    elif len(self._recent_cli_errors) >= 32:
                        oldest_key = next(iter(self._recent_cli_errors))
                        self._recent_cli_errors.pop(oldest_key, None)
                    iso_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    self._recent_cli_errors[key] = (iso_ts, summary)
        except Exception as exc:
            logger.debug("Error reaping Deck CLI process (session=%s): %s", key, exc)
        finally:
            if key and self._running_procs.get(key) is proc:
                self._running_procs.pop(key, None)
            self._anonymous_procs.discard(proc)

    def get_synthetic_error_steps(
        self,
        session_id: str,
        *,
        max_existing_step: int = -1,
        existing_error_steps: set[int] | None = None,
    ) -> list[TranscriptStep]:
        sid = self.validate_session_id(session_id)
        entry = self._recent_cli_errors.get(sid)
        if not entry:
            return []
        iso_ts, summary = entry
        next_idx = max(0, max_existing_step) + 1
        while existing_error_steps and next_idx in existing_error_steps:
            next_idx += 1
        return [
            TranscriptStep(
                step_index=next_idx,
                source="SYSTEM",
                msg_type="ERROR_MESSAGE",
                status="ERROR",
                content=f"Deck CLI 执行失败:\n{summary}",
                thinking="",
                tool_calls=[],
                timestamp=iso_ts,
            )
        ]

    async def send_message(
        self,
        session_id: str,
        content: str,
        model: str | None = None,
        workspace_path: str | None = None,
    ) -> ActionAckResponse:
        sid = self.validate_session_id(session_id)
        self._recent_cli_errors.pop(sid, None)
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
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                start_new_session=True,
            )
            self._running_procs[sid] = proc
            asyncio.create_task(self._reap_managed_process(sid, proc))
            return ActionAckResponse(ok=True, session_id=sid, message="Deck CLI task started")
        except Exception as exc:
            return ActionAckResponse(ok=False, session_id=sid, message=f"Failed to start Deck CLI: {exc}")

    def _snapshot_brain_dirs_sync(self) -> set[str]:
        if not self.brain_dir.exists() or not self.brain_dir.is_dir():
            return set()
        try:
            return {p.name for p in self.brain_dir.iterdir() if p.is_dir()}
        except OSError:
            return set()

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

        before_dirs = await asyncio.to_thread(self._snapshot_brain_dirs_sync)
        cmd = [str(self._agy_bin), "-p", content, *self._build_cli_flags(model, mode)]
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=str(target_cwd) if target_cwd.exists() else None,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                start_new_session=True,
            )
            detected_sid = ""
            for _ in range(10):
                await asyncio.sleep(0.2)
                after_dirs = await asyncio.to_thread(self._snapshot_brain_dirs_sync)
                added = sorted(after_dirs - before_dirs)
                if len(added) == 1:
                    detected_sid = added[0]
                    break
                if proc.returncode is not None:
                    break

            if detected_sid:
                self._running_procs[detected_sid] = proc
                asyncio.create_task(self._reap_managed_process(detected_sid, proc))
            else:
                self._anonymous_procs.add(proc)
                asyncio.create_task(self._reap_managed_process(None, proc))
            return CreateSessionResponse(ok=True, session_id=detected_sid, message="Deck CLI session started")
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

    async def _run_cli_query(self, args: list[str], timeout: float = 15.0) -> str:
        """Run a short read-only agy CLI query via systemd-run first, falling back to direct execution."""
        for cmd in (
            ["systemd-run", "--user", "--pipe", str(self._agy_bin), *args],
            [str(self._agy_bin), *args],
        ):
            try:
                proc = await asyncio.create_subprocess_exec(
                    *cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout_b, stderr_b = await asyncio.wait_for(proc.communicate(), timeout=timeout)
                candidate = stdout_b.decode("utf-8", errors="replace").strip()
                if not candidate and cmd[0] != "systemd-run":
                    candidate = stderr_b.decode("utf-8", errors="replace").strip()
                if proc.returncode == 0 and candidate:
                    return candidate
            except Exception:
                continue
        return ""

    @staticmethod
    def parse_cli_models_output(raw_text: str) -> list[ModelOption]:
        """Parse `agy models` TSV output into ModelOption items, filtering headers and placeholders."""
        options: list[ModelOption] = []
        seen_ids: set[str] = set()
        skip_prefixes = (
            "running as unit:",
            "fetching available models",
            "usage:",
            "error:",
            "flags:",
        )
        for line in raw_text.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            low = stripped.lower()
            if any(low.startswith(prefix) for prefix in skip_prefixes):
                continue

            parts = [p.strip() for p in stripped.split("\t") if p.strip()]
            if len(parts) < 2:
                parts = [p.strip() for p in re.split(r"\s{2,}", stripped, maxsplit=1) if p.strip()]
            if len(parts) < 2:
                continue

            model_id, label = parts[0], parts[1]
            if (
                not model_id
                or any(ch.isspace() for ch in model_id)
                or model_id.startswith("-")
                or model_id.upper().startswith("MODEL_PLACEHOLDER_")
                or model_id in seen_ids
            ):
                continue

            seen_ids.add(model_id)
            clean_label = label or BaseEngineProvider.prettify_model_id(model_id)
            options.append(
                ModelOption(
                    id=model_id,
                    label=clean_label,
                    group=BaseEngineProvider.infer_model_group(model_id, clean_label),
                )
            )
        return options

    def _read_default_model_hint_sync(self) -> str:
        """Read preferred model name/ID from ~/.gemini/antigravity-cli/settings.json."""
        if not self._settings_path.exists():
            return ""
        try:
            data = json.loads(self._settings_path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return str(data.get("model") or "").strip()
        except Exception:
            pass
        return ""

    def _apply_quota_overlay(self, catalog: ModelsResponse) -> ModelsResponse:
        """Overlay cached 5h/primary quota fractions onto matching Deck model groups without mutating cached copy."""
        if not self._cached_quota or not self._cached_quota.groups:
            return catalog

        group_quota: dict[str, tuple[float, str]] = {}
        for grp in self._cached_quota.groups:
            if not grp.buckets:
                continue
            chosen = next((b for b in grp.buckets if b.window == "5h" and not b.disabled), None)
            if chosen is None:
                chosen = next((b for b in grp.buckets if not b.disabled), None)
            if chosen is None:
                chosen = grp.buckets[0]
            group_quota[grp.display_name.lower()] = (float(chosen.remaining_fraction), str(chosen.reset_time or ""))

        if not group_quota:
            return catalog

        updated_models: list[ModelOption] = []
        for m in catalog.models:
            grp_key = m.group.lower()
            matched_quota: tuple[float, str] | None = None
            for q_name, q_val in group_quota.items():
                if grp_key in ("gemini", "claude", "gpt") and grp_key in q_name:
                    matched_quota = q_val
                    break
            if matched_quota is not None:
                frac, reset_time = matched_quota
                updated_models.append(
                    m.model_copy(update={"remaining_fraction": frac, "reset_time": reset_time})
                )
            else:
                updated_models.append(m.model_copy())

        return catalog.model_copy(update={"models": updated_models})

    async def fetch_models(self) -> ModelsResponse:
        """Query Steam Deck `agy models` for real account-entitled models instead of static fallbacks."""
        now = time.time()
        if self._cached_models and (now - self._last_models_sync) < 300.0:
            return self._apply_quota_overlay(self._cached_models)

        async with self._models_lock:
            now = time.time()
            if self._cached_models and (now - self._last_models_sync) < 300.0:
                return self._apply_quota_overlay(self._cached_models)

            if not self._agy_bin.exists():
                if self._cached_models:
                    return self._apply_quota_overlay(self._cached_models)
                return await super().fetch_models()

            raw = await self._run_cli_query(["models"], timeout=15.0)
            options = self.parse_cli_models_output(raw) if raw else []
            if options:
                default_hint = await asyncio.to_thread(self._read_default_model_hint_sync)
                hint_low = default_hint.lower()
                default_idx = 0
                if hint_low:
                    for idx, opt in enumerate(options):
                        if opt.id.lower() == hint_low or opt.label.lower() == hint_low:
                            default_idx = idx
                            break

                options[default_idx] = options[default_idx].model_copy(update={"is_default": True})
                catalog = ModelsResponse(
                    models=options,
                    default_model=options[default_idx].id,
                    supports_mid_session_switch=True,
                )
                self._cached_models = catalog
                self._last_models_sync = time.time()
                return self._apply_quota_overlay(catalog)

            if self._cached_models:
                return self._apply_quota_overlay(self._cached_models)
            return await super().fetch_models()

    async def fetch_quota(self) -> QuotaResponse:
        if self._cached_quota and (time.time() - self._last_quota_sync) < 300.0:
            return self._cached_quota

        if not self._agy_bin.exists():
            return QuotaResponse(groups=[], description=f"agy CLI not found: {self._agy_bin}")

        output = await self._run_cli_query(["-p", "/quota"], timeout=15.0)
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
