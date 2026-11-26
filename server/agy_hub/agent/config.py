"""Node Agent configuration schema and platform resolution."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, field_validator

from agy_hub.common.security import validate_secret


class AgentConfig(BaseModel):
    platform: Literal["auto", "windows", "deck"] = "auto"
    host: str = "127.0.0.1"
    port: int = Field(default=8765, ge=1, le=65535)
    internal_secret: str
    roots: dict[str, str] = Field(default_factory=dict)
    brain_dir: str | None = None
    db_path: str | None = None
    default_workspace: str | None = None
    language_server_exe: str | None = None
    daemon_dir: str | None = None
    app_storage_path: str | None = None
    agy_bin: str | None = None
    deck_permission_mode: Literal["default", "auto", "skip_permissions"] = "auto"
    archive_file: str | None = None
    max_upload_bytes: int = Field(default=50 * 1024 * 1024, ge=1024)
    poll_interval_seconds: float = Field(default=0.25, ge=0.05, le=5.0)
    enable_terminal: bool = True
    max_terminal_sessions: int = Field(default=4, ge=1, le=16)

    @field_validator("internal_secret")
    @classmethod
    def _check_internal_secret(cls, value: str) -> str:
        return validate_secret(value, "internal_secret")


def resolve_platform(platform_name: str = "auto") -> Literal["windows", "deck"]:
    target = (platform_name or "auto").strip().lower()
    if target == "auto":
        env_plat = os.environ.get("AGY_PLATFORM", "").strip().lower()
        target = env_plat or ("windows" if sys.platform == "win32" else "deck")
    if target in ("deck", "linux"):
        return "deck"
    return "windows"


def load_agent_config(config_path: str | Path) -> AgentConfig:
    path = Path(config_path)
    if not path.exists():
        raise FileNotFoundError(f"Agent config file not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("Agent config must be a JSON object")
    return AgentConfig.model_validate(data)
