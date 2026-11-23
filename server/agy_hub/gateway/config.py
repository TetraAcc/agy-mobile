"""Gateway configuration schema and static frontend directory resolution."""

from __future__ import annotations

import json
from pathlib import Path

from pydantic import BaseModel, Field, field_validator

from agy_hub.common.security import validate_secret


class NodeConfig(BaseModel):
    name: str = Field(..., min_length=1, max_length=64)
    base_url: str = Field(..., min_length=1)
    is_local: bool = False
    health_timeout_seconds: float = Field(default=2.0, gt=0.1, le=30.0)

    @field_validator("base_url")
    @classmethod
    def _normalize_base_url(cls, value: str) -> str:
        cleaned = value.strip().rstrip("/")
        if "://" not in cleaned:
            cleaned = f"http://{cleaned}"
        return cleaned


class GatewayConfig(BaseModel):
    host: str = "0.0.0.0"
    port: int = Field(default=8768, ge=1, le=65535)
    db_path: str = "hub.db"
    signing_secret: str
    internal_secret: str
    allowed_origins: list[str] = Field(default_factory=list)
    cookie_secure: bool = True
    access_token_ttl_seconds: int = Field(default=1800, ge=60, le=86400)
    refresh_token_ttl_seconds: int = Field(default=86400 * 30, ge=300)
    web_dir: str | None = None
    nodes: dict[str, NodeConfig] = Field(default_factory=dict)
    max_login_failures: int = Field(default=5, ge=1, le=50)
    lockout_seconds: int = Field(default=900, ge=10, le=86400)
    probe_interval_seconds: float = Field(default=5.0, ge=1.0, le=300.0)

    @field_validator("signing_secret")
    @classmethod
    def _check_signing_secret(cls, value: str) -> str:
        return validate_secret(value, "signing_secret")

    @field_validator("internal_secret")
    @classmethod
    def _check_internal_secret(cls, value: str) -> str:
        return validate_secret(value, "internal_secret")

    @field_validator("allowed_origins")
    @classmethod
    def _disallow_wildcard_origins(cls, value: list[str]) -> list[str]:
        cleaned = [origin.strip().rstrip("/") for origin in value if origin and origin.strip()]
        if "*" in cleaned:
            raise ValueError("Wildcard '*' is forbidden in allowed_origins")
        return cleaned


def load_gateway_config(config_path: str | Path) -> GatewayConfig:
    path = Path(config_path)
    if not path.exists():
        raise FileNotFoundError(f"Gateway config file not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("Gateway config must be a JSON object")
    if not Path(data.get("db_path", "hub.db")).is_absolute() and data.get("db_path", "hub.db") != ":memory:":
        data["db_path"] = str((path.parent / data.get("db_path", "hub.db")).resolve())
    return GatewayConfig.model_validate(data)


def resolve_web_dir(configured_dir: str | None, server_dir: Path) -> Path | None:
    """Resolve compiled Flutter web output directory without ever mounting Flutter source web/."""
    candidates: list[Path] = []
    if configured_dir:
        candidates.append(Path(configured_dir).expanduser())
    candidates.extend(
        [
            server_dir.parent / "build" / "web",
            server_dir / "web_dist",
            Path.home() / "agy_remote" / "web",
        ]
    )
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved.is_dir() and (resolved / "index.html").is_file():
            return resolved
    return None
