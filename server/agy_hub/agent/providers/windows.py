"""Windows Antigravity EngineProvider using async Connect-RPC and agentapi CLI."""

from __future__ import annotations

import asyncio
import glob
import json
import logging
import os
import socket
import time
from pathlib import Path
from typing import Any

import httpx

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
)

logger = logging.getLogger(__name__)

_MODEL_ALIAS_MAP = {
    "sonnet": "claude-sonnet-4-6",
    "pro": "gemini-2.5-pro",
    "flash": "gemini-3.8-flash-high",
    "flash_lite": "gemini-3.5-flash-lite",
}


class WindowsEngineProvider(BaseEngineProvider):
    platform_name = "windows"

    def __init__(
        self,
        config: AgentConfig,
        registry: RootRegistry,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self._brain_dir = Path(os.path.expanduser(config.brain_dir or r"~\.gemini\antigravity\brain")).resolve()
        self._db_path = Path(
            os.path.expanduser(config.db_path or r"~\.gemini\antigravity\conversation_summaries.db")
        ).resolve()
        self._default_workspace = Path(
            os.path.expanduser(config.default_workspace or r"~\.gemini\antigravity\scratch")
        ).resolve()
        self._daemon_dir = Path(os.path.expanduser(config.daemon_dir or r"~\.gemini\antigravity\daemon")).resolve()
        self._ls_exe = Path(
            os.path.expanduser(
                config.language_server_exe
                or r"~\AppData\Local\Programs\antigravity\resources\bin\language_server.exe"
            )
        )
        self._app_storage_path = Path(
            os.path.expanduser(config.app_storage_path or r"~\AppData\Roaming\Antigravity\app_storage.json")
        )
        self._owned_client = http_client is None
        self._http_client = http_client or httpx.AsyncClient(timeout=6.0)
        self._hub_cache: dict[str, Any] | None = None
        self._hub_cache_ts: float = 0.0
        self._model_catalog_cache: ModelsResponse | None = None
        self._model_id_to_alias: dict[str, dict[str, Any]] = {}
        self._last_models_sync: float = 0.0
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

    async def aclose(self) -> None:
        if self._owned_client:
            await self._http_client.aclose()

    @staticmethod
    def _is_port_reachable(port: int, timeout: float = 0.08) -> bool:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=timeout):
                return True
        except OSError:
            return False

    def _discover_hub_sync(self) -> dict[str, Any] | None:
        now = time.time()
        if self._hub_cache and (now - self._hub_cache_ts) < 3.0:
            return self._hub_cache
        files = glob.glob(str(self._daemon_dir / "hub_*.json"))
        if not files:
            self._hub_cache = None
            return None
        files.sort(key=os.path.getmtime, reverse=True)
        first_valid: dict[str, Any] | None = None
        for fpath in files:
            try:
                data = json.loads(Path(fpath).read_text(encoding="utf-8"))
                port = data.get("httpPort") or data.get("port")
                csrf = data.get("csrfToken") or data.get("csrf_token")
                if port and csrf:
                    candidate = {"port": int(port), "csrf_token": str(csrf), "pid": data.get("pid")}
                    if first_valid is None:
                        first_valid = candidate
                    if self._is_port_reachable(candidate["port"]):
                        self._hub_cache = candidate
                        self._hub_cache_ts = now
                        return candidate
            except Exception:
                continue
        if first_valid is not None:
            self._hub_cache = first_valid
            self._hub_cache_ts = now
            return first_valid
        self._hub_cache = None
        return None

    def _build_agentapi_env(self, hub: dict[str, Any] | None) -> dict[str, str]:
        env = os.environ.copy()
        if hub and hub.get("port"):
            env["ANTIGRAVITY_LS_ADDRESS"] = f"localhost:{hub['port']}"
        if hub and hub.get("csrf_token"):
            env["ANTIGRAVITY_CSRF_TOKEN"] = str(hub["csrf_token"])
        return env

    async def _rpc_post(self, method_name: str, payload: dict[str, Any], timeout: float = 5.0) -> dict[str, Any] | None:
        hub = await asyncio.to_thread(self._discover_hub_sync)
        if not hub:
            return None
        url = f"http://127.0.0.1:{hub['port']}/exa.language_server_pb.LanguageServerService/{method_name}"
        headers = {
            "Content-Type": "application/json",
            "x-codeium-csrf-token": hub["csrf_token"],
        }
        resp = await self._http_client.post(url, json=payload, headers=headers, timeout=timeout)
        resp.raise_for_status()
        return resp.json() if resp.content else {}

    async def is_engine_alive(self) -> bool:
        hub = await asyncio.to_thread(self._discover_hub_sync)
        if not hub:
            return False
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection("127.0.0.1", hub["port"]),
                timeout=0.5,
            )
            writer.close()
            await writer.wait_closed()
            return True
        except Exception:
            return False

    def get_pinned_session_ids(self) -> set[str]:
        if not self._app_storage_path.exists():
            return set()
        try:
            data = json.loads(self._app_storage_path.read_text(encoding="utf-8"))
            raw_pinned = data.get("pinned_conversations_order", "[]")
            if isinstance(raw_pinned, str):
                parsed = json.loads(raw_pinned)
                return {str(x) for x in parsed if x} if isinstance(parsed, list) else set()
            if isinstance(raw_pinned, list):
                return {str(x) for x in raw_pinned if x}
        except Exception:
            pass
        return set()

    async def _sync_model_catalog(self, force: bool = False) -> ModelsResponse | None:
        now = time.time()
        if not force and self._model_catalog_cache and (now - self._last_models_sync) < 120.0:
            return self._model_catalog_cache

        try:
            data = await self._rpc_post("GetCascadeModelConfigData", {}, timeout=5.0)
        except Exception as exc:
            logger.debug("GetCascadeModelConfigData failed: %s", exc)
            return self._model_catalog_cache

        if not isinstance(data, dict):
            return self._model_catalog_cache

        raw_configs = data.get("clientModelConfigs", [])
        if not isinstance(raw_configs, list) or not raw_configs:
            return self._model_catalog_cache

        default_moa = (data.get("defaultOverrideModelConfig") or {}).get("modelOrAlias")
        default_moa_key = default_moa.get("model") if isinstance(default_moa, dict) else None

        models: list[ModelOption] = []
        id_to_alias: dict[str, dict[str, Any]] = {}
        default_model_id = ""
        seen_ids: set[str] = set()

        for cfg in raw_configs:
            if not isinstance(cfg, dict):
                continue
            moa = cfg.get("modelOrAlias")
            moa_dict = moa if isinstance(moa, dict) and moa else None
            raw_moa_val = str(moa_dict.get("model") or moa_dict.get("alias") or "").strip() if moa_dict else ""
            model_id = str(cfg.get("modelId") or "").strip() or raw_moa_val
            if not model_id or model_id in seen_ids:
                continue
            seen_ids.add(model_id)

            label = str(cfg.get("label") or "").strip() or self.prettify_model_id(model_id)
            tag = str(cfg.get("tagTitle") or "").strip()
            quota_info = cfg.get("quotaInfo") if isinstance(cfg.get("quotaInfo"), dict) else {}
            rem_raw = quota_info.get("remainingFraction")
            rem_frac: float | None = None
            if isinstance(rem_raw, (int, float)):
                rem_frac = float(rem_raw)
            reset_time = str(quota_info.get("resetTime") or "").strip()

            is_default = bool(default_moa_key and raw_moa_val == default_moa_key)
            if is_default and not default_model_id:
                default_model_id = model_id

            if moa_dict:
                id_to_alias[model_id.lower()] = moa_dict
                id_to_alias[label.lower()] = moa_dict
                if raw_moa_val:
                    id_to_alias[raw_moa_val.lower()] = moa_dict

            models.append(
                ModelOption(
                    id=model_id,
                    label=label,
                    group=self.infer_model_group(model_id, label),
                    tag=tag,
                    remaining_fraction=rem_frac,
                    reset_time=reset_time,
                    is_default=is_default,
                )
            )

        if not models:
            return self._model_catalog_cache

        if not default_model_id:
            default_model_id = models[0].id
            models[0].is_default = True

        catalog = ModelsResponse(
            models=models,
            default_model=default_model_id,
            supports_mid_session_switch=True,
        )
        self._model_catalog_cache = catalog
        self._model_id_to_alias = id_to_alias
        self._last_models_sync = now
        return catalog

    async def _resolve_model_or_alias(self, model: str | None) -> dict[str, Any] | None:
        raw = (model or "").strip()
        if not raw:
            return None
        mapped = _MODEL_ALIAS_MAP.get(raw.lower(), raw)
        key = mapped.lower()

        cached = self._model_id_to_alias.get(key) or self._model_id_to_alias.get(raw.lower())
        if cached:
            return cached

        should_refresh = not self._model_id_to_alias or (time.time() - self._last_models_sync) > 10.0
        if should_refresh:
            await self._sync_model_catalog(force=True)
            cached = self._model_id_to_alias.get(key) or self._model_id_to_alias.get(raw.lower())
            if cached:
                return cached

        if raw.startswith("MODEL_"):
            return {"model": raw}
        return None

    async def fetch_models(self) -> ModelsResponse:
        catalog = await self._sync_model_catalog()
        if catalog and catalog.models:
            return catalog
        return await super().fetch_models()

    async def send_message(
        self,
        session_id: str,
        content: str,
        model: str | None = None,
        workspace_path: str | None = None,
    ) -> ActionAckResponse:
        sid = self.validate_session_id(session_id)
        base_payload: dict[str, Any] = {
            "cascadeId": sid,
            "messageText": content,
            "items": [{"text": content}],
        }
        requested_model = await self._resolve_model_or_alias(model) if (model and model.strip()) else None
        payload = dict(base_payload)
        if requested_model:
            payload["cascadeConfig"] = {
                "plannerConfig": {
                    "requestedModel": requested_model,
                }
            }
        try:
            await self._rpc_post("SendUserCascadeMessage", payload, timeout=5.0)
            msg = f"Sent via Connect-RPC (model={model.strip()})" if requested_model and model else "Sent via Connect-RPC"
            return ActionAckResponse(ok=True, session_id=sid, message=msg)
        except httpx.HTTPStatusError as exc:
            if requested_model and 400 <= exc.response.status_code < 500:
                logger.warning(
                    "SendUserCascadeMessage rejected cascadeConfig (%s), retrying without model override",
                    exc,
                )
                try:
                    await self._rpc_post("SendUserCascadeMessage", base_payload, timeout=5.0)
                    return ActionAckResponse(ok=True, session_id=sid, message="Sent via Connect-RPC")
                except Exception as retry_exc:
                    logger.warning("SendUserCascadeMessage retry failed (%s), falling back to agentapi", retry_exc)
            else:
                logger.warning("SendUserCascadeMessage failed (%s), falling back to agentapi", exc)
        except Exception as exc:
            logger.warning("SendUserCascadeMessage failed (%s), falling back to agentapi", exc)

        if self._ls_exe.exists():
            hub = await asyncio.to_thread(self._discover_hub_sync)
            sub_env = self._build_agentapi_env(hub)
            proc = await asyncio.create_subprocess_exec(
                str(self._ls_exe),
                "agentapi",
                "send-message",
                "--title=AGY Web",
                sid,
                content,
                env=sub_env,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                stdout_b, stderr_b = await asyncio.wait_for(proc.communicate(), timeout=10.0)
            except TimeoutError:
                proc.kill()
                return ActionAckResponse(ok=False, session_id=sid, message="agentapi send-message timed out")
            if proc.returncode == 0:
                return ActionAckResponse(ok=True, session_id=sid, message="Sent via agentapi")
            err = stderr_b.decode("utf-8", errors="replace").strip() or stdout_b.decode("utf-8", errors="replace").strip()
            return ActionAckResponse(ok=False, session_id=sid, message=err or "agentapi send-message failed")

        return ActionAckResponse(ok=False, session_id=sid, message="Antigravity LanguageServer is not running")

    async def create_session(
        self,
        content: str,
        model: str | None = None,
        mode: str = "auto",
        workspace_path: str | None = None,
    ) -> CreateSessionResponse:
        if not self._ls_exe.exists():
            return CreateSessionResponse(ok=False, session_id="", message="language_server.exe not found")

        hub = await asyncio.to_thread(self._discover_hub_sync)
        sub_env = self._build_agentapi_env(hub)
        if not sub_env.get("ANTIGRAVITY_LS_ADDRESS"):
            return CreateSessionResponse(
                ok=False,
                session_id="",
                message="未检测到运行中的 Antigravity 主进程，请先在电脑上打开 Antigravity",
            )

        raw_model = (model or "gemini-3.8-flash-high").strip().lower()
        model_flag = _MODEL_ALIAS_MAP.get(raw_model, raw_model)

        target_cwd = self.default_workspace
        if workspace_path:
            ws_candidate = Path(os.path.expanduser(workspace_path))
            if ws_candidate.exists() and ws_candidate.is_dir():
                target_cwd = ws_candidate

        cmd = [str(self._ls_exe), "agentapi", "new-conversation", f"--model={model_flag}", content]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=str(target_cwd) if target_cwd.exists() else None,
            env=sub_env,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout_b, stderr_b = await asyncio.wait_for(proc.communicate(), timeout=12.0)
        except TimeoutError:
            proc.kill()
            return CreateSessionResponse(ok=False, session_id="", message="new-conversation timed out")

        out_text = stdout_b.decode("utf-8", errors="replace").strip()
        if proc.returncode == 0:
            new_cid = ""
            try:
                parsed = json.loads(out_text)
                new_cid = str(parsed.get("response", {}).get("newConversation", {}).get("conversationId", ""))
            except Exception:
                pass
            return CreateSessionResponse(ok=True, session_id=new_cid, message=f"Session created (mode={mode})")

        err_text = stderr_b.decode("utf-8", errors="replace").strip() or out_text or "Failed to create session"
        return CreateSessionResponse(ok=False, session_id="", message=err_text)

    async def stop_session(self, session_id: str) -> ActionAckResponse:
        sid = self.validate_session_id(session_id)
        hub = await asyncio.to_thread(self._discover_hub_sync)
        if not hub:
            return ActionAckResponse(ok=False, session_id=sid, message="Active Antigravity daemon hub not found")

        errors: list[str] = []
        any_ok = False
        try:
            await self._rpc_post(
                "CancelCascadeInvocation",
                {"cascadeId": sid, "killBackgroundTasks": True},
                timeout=3.0,
            )
            any_ok = True
        except Exception as exc:
            errors.append(f"CancelCascadeInvocation: {exc}")

        try:
            await self._rpc_post(
                "ForceStopCascadeTree",
                {"conversationId": sid},
                timeout=3.0,
            )
            any_ok = True
        except Exception as exc:
            errors.append(f"ForceStopCascadeTree: {exc}")

        if any_ok:
            return ActionAckResponse(ok=True, session_id=sid, message="Session stop signal dispatched")
        return ActionAckResponse(ok=False, session_id=sid, message="; ".join(errors) or "Stop failed")

    async def fetch_quota(self) -> QuotaResponse:
        try:
            data = await self._rpc_post("RetrieveUserQuotaSummary", {}, timeout=5.0)
        except Exception as exc:
            return QuotaResponse(groups=[], description=f"Failed to retrieve Windows quota: {exc}")

        if not data:
            return QuotaResponse(groups=[], description="Antigravity LanguageServer is not running")

        raw_groups = data.get("response", {}).get("groups", [])
        if not raw_groups:
            raw_groups = data.get("userStatus", {}).get("cascadeModelQuotaStatus", {}).get("groups", [])

        groups: list[QuotaGroup] = []
        for g in raw_groups:
            if not isinstance(g, dict):
                continue
            buckets: list[QuotaBucket] = []
            for b in g.get("buckets", []):
                if not isinstance(b, dict):
                    continue
                buckets.append(
                    QuotaBucket(
                        bucket_id=str(b.get("bucketId", "")),
                        display_name=str(b.get("displayName", "")),
                        window=str(b.get("window", "")),
                        remaining_fraction=float(b.get("remainingFraction", 0.0)),
                        disabled=bool(b.get("disabled", False)),
                        reset_time=str(b.get("resetTime", "")),
                    )
                )
            groups.append(
                QuotaGroup(
                    display_name=str(g.get("displayName", "")),
                    description=str(g.get("description", "")),
                    buckets=buckets,
                )
            )
        return QuotaResponse(groups=groups, description="Windows Antigravity native quota")
