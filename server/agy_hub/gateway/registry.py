"""Node registry health probing and tenant-scoped status filtering."""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

import httpx

from agy_hub.common.schemas import NodeStatus, UserProfile
from agy_hub.gateway.config import NodeConfig

logger = logging.getLogger(__name__)


class NodeRegistryManager:
    """Probes registered Node Agents and tracks online / engine_alive status."""

    def __init__(
        self,
        nodes: dict[str, NodeConfig],
        http_client: httpx.AsyncClient,
        probe_interval_seconds: float = 5.0,
    ) -> None:
        self.nodes = nodes
        self.http_client = http_client
        self.probe_interval_seconds = probe_interval_seconds
        self._cache: dict[str, dict[str, Any]] = {
            nid: {
                "online": False,
                "engine_alive": False,
                "last_seen": 0.0,
                "version": "",
            }
            for nid in nodes
        }
        self._task: asyncio.Task[None] | None = None

    async def probe_node(self, node_id: str) -> dict[str, Any]:
        cfg = self.nodes.get(node_id)
        if not cfg:
            return {"online": False, "engine_alive": False, "last_seen": 0.0, "version": ""}
        now = time.time()
        try:
            resp = await self.http_client.get(
                f"{cfg.base_url}/internal/health",
                timeout=cfg.health_timeout_seconds,
            )
            if resp.status_code == 200:
                data = resp.json()
                entry = {
                    "online": True,
                    "engine_alive": bool(data.get("engine_alive", False)),
                    "last_seen": now,
                    "version": str(data.get("version", "") or ""),
                }
                self._cache[node_id] = entry
                return entry
        except Exception as exc:
            logger.debug("Probe failed for node %s (%s): %s", node_id, cfg.base_url, exc)

        prev = self._cache.get(node_id, {})
        entry = {
            "online": False,
            "engine_alive": False,
            "last_seen": float(prev.get("last_seen", 0.0)),
            "version": str(prev.get("version", "") or ""),
        }
        self._cache[node_id] = entry
        return entry

    async def probe_all(self) -> None:
        if not self.nodes:
            return
        await asyncio.gather(*(self.probe_node(nid) for nid in self.nodes), return_exceptions=True)

    def is_node_online(self, node_id: str) -> bool:
        cached = self._cache.get(node_id)
        return bool(cached and cached.get("online", False))

    def get_visible_nodes(self, user: UserProfile) -> list[NodeStatus]:
        visible: list[NodeStatus] = []
        for node_id, grant in user.node_permissions.items():
            cfg = self.nodes.get(node_id)
            if not cfg:
                continue
            cached = self._cache.get(node_id, {})
            visible.append(
                NodeStatus(
                    id=node_id,
                    name=cfg.name,
                    online=bool(cached.get("online", False)),
                    engine_alive=bool(cached.get("engine_alive", False)),
                    is_local=cfg.is_local,
                    last_seen=float(cached.get("last_seen", 0.0)),
                    version=str(cached.get("version", "") or ""),
                    can_write=grant.can_write,
                    can_delete=grant.can_delete,
                )
            )
        return visible

    def get_all_nodes(self) -> list[NodeStatus]:
        all_nodes: list[NodeStatus] = []
        for node_id, cfg in self.nodes.items():
            cached = self._cache.get(node_id, {})
            all_nodes.append(
                NodeStatus(
                    id=node_id,
                    name=cfg.name,
                    online=bool(cached.get("online", False)),
                    engine_alive=bool(cached.get("engine_alive", False)),
                    is_local=cfg.is_local,
                    last_seen=float(cached.get("last_seen", 0.0)),
                    version=str(cached.get("version", "") or ""),
                    can_write=True,
                    can_delete=True,
                )
            )
        return all_nodes

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
                await self.probe_all()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.warning("Node monitor loop error: %s", exc)
            await asyncio.sleep(self.probe_interval_seconds)
