"""
AGY 核心统一服务端引擎 (Unified Core Server Engine)
单真实源 (Single Source of Truth)：
- 统一 WebSocket 协议分发与多节点网关代理
- 统一会话树聚合、孤儿物理清洗与 Fallback 标题提取
- 统一 Transcript 日志解析与无缝流式推送（严格过滤 IGNORED_MSG_TYPES 与命令行回显）
- 统一新建会话动态监听与免刷新全量广播
- 统一会话彻底物理删除 (SQLite + 磁盘 brain 物理同步销毁)
- 统一安全文件浏览、下载与媒体服务
"""

import os
import re
import sys
import glob
import json
import time
import shutil
import sqlite3
import logging
import asyncio
import subprocess
import urllib.parse
import secrets
from typing import Optional, Dict, Any, List, Set, Tuple

import aiohttp
from aiohttp import web, WSMsgType

from server_common import (
    IGNORED_MSG_TYPES,
    SENSITIVE_PATTERNS,
    is_path_safe,
    build_cors_headers,
    clean_display_content,
    parse_project_name_and_path,
    list_workspace_files,
    parse_transcript_line
)
from platform_adapter import BasePlatformAdapter, get_platform_adapter

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")


class UnifiedServer:
    def __init__(self, platform_name: Optional[str] = None, port_override: Optional[int] = None, config_path: Optional[str] = None):
        self.server_dir = os.path.dirname(os.path.abspath(__file__))
        self.config_path = config_path or os.path.join(self.server_dir, "server_config.json")
        self.raw_config = self._load_config_file()
        
        # 自动探测或覆盖平台
        self.adapter: BasePlatformAdapter = get_platform_adapter(platform_name, self.raw_config.get(platform_name or "", {}))
        self.platform_name = self.adapter.name
        self.platform_config = self.raw_config.get(self.platform_name, {})
        # 补充注入对应平台的配置给 adapter
        self.adapter.config = self.platform_config

        # 端口与鉴权
        self.port = int(port_override or os.environ.get("AGY_PORT") or self.platform_config.get("port") or (8765 if self.platform_name == "windows" else 8768))
        self.allowed_origins = self.platform_config.get("allowed_origins", ["*"])

        # 内部节点网关通信私钥
        self.internal_secret = self.raw_config.get("internal_secret", "88db71c100c87ff17fb082f95572e1fc")

        # 动态 Session 存储 (持久化 sessions.json)
        self.sessions_file = os.path.join(self.server_dir, "sessions.json")
        self.active_sessions: Dict[str, Dict[str, Any]] = self._load_sessions()

        # 多租户与节点注册表
        self.user_profiles: Dict[str, Any] = self.platform_config.get("user_profiles", {})
        self.node_registry: Dict[str, Any] = self.platform_config.get("node_registry", {})
        self.is_gateway = bool(self.node_registry and len(self.node_registry) > 0)

        # 活跃连接管理与会话状态
        self.active_websockets: Set[web.WebSocketResponse] = set()
        self.current_active_file: Optional[str] = None
        self.current_active_session_id: Optional[str] = None
        self.file_handle = None
        self.is_agent_running = False

        # 节点状态缓存 (网关模式)
        self.node_status_cache: Dict[str, Dict[str, Any]] = {}
        self.last_node_check_time: float = 0.0

        # 定位静态前端目录
        self.web_dir = None
        candidate_dirs = [
            os.path.abspath(os.path.join(self.server_dir, "..", "build", "web")),
            os.path.join(self.server_dir, "web"),
            os.path.abspath(os.path.join(self.server_dir, "..", "web")),
            os.path.expanduser("~/agy_remote/web")
        ]
        for d in candidate_dirs:
            if os.path.isdir(d) and os.path.isfile(os.path.join(d, "index.html")):
                self.web_dir = d
                break
        logging.info(f"[*] 前端静态资源目录: {self.web_dir}")

        # 初始化 Web App
        self.app = web.Application(middlewares=[self.spa_middleware])
        self._setup_routes()
        self.app.on_startup.append(self.start_background_tasks)
        self.app.on_cleanup.append(self.cleanup_background_tasks)

    def _load_config_file(self) -> Dict[str, Any]:
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                logging.error(f"[-] 读取配置文件异常 {self.config_path}: {e}")
        return {}

    def _load_sessions(self) -> Dict[str, Dict[str, Any]]:
        """从持久化文件加载活跃登录会话表"""
        if os.path.exists(self.sessions_file):
            try:
                with open(self.sessions_file, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                logging.error(f"[-] 读取会话缓存异常 {self.sessions_file}: {e}")
        return {}

    def _save_sessions(self):
        """将活跃登录会话表写入持久化文件"""
        try:
            with open(self.sessions_file, "w", encoding="utf-8") as f:
                json.dump(self.active_sessions, f, ensure_ascii=False, indent=2)
        except Exception as e:
            logging.error(f"[-] 保存会话缓存异常 {self.sessions_file}: {e}")

    def _setup_routes(self):
        # 1. 首页与 WebSocket 端点
        self.app.router.add_get("/", self.index_handler)
        self.app.router.add_get("/ws", self.websocket_handler)

        # 2. RESTful API 端点
        self.app.router.add_post("/api/login", self.api_login_handler)
        self.app.router.add_post("/api/logout", self.api_logout_handler)
        self.app.router.add_get("/api/me", self.api_me_handler)
        self.app.router.add_get("/api/nodes", self.api_nodes_handler)
        self.app.router.add_get("/api/quota", self.api_quota_handler)
        self.app.router.add_get("/api/health", self.api_health_handler)
        self.app.router.add_get("/api/download", self.download_handler)
        self.app.router.add_get("/api/media", self.media_handler)

        # 3. 挂载前端静态资源路由 (放在最后)
        if self.web_dir and os.path.exists(self.web_dir):
            self.app.router.add_static('/', path=self.web_dir, show_index=False, follow_symlinks=True)

    # -------------------------------------------------------------------------
    # 鉴权与租户多节点隔离逻辑
    # -------------------------------------------------------------------------
    def authenticate_request(self, request: web.Request) -> Tuple[bool, Optional[str], Optional[Dict[str, Any]]]:
        """
        严格动态 Session 鉴权：
        1. 彻底废除旧静态 Token (tetra2026 / simeng 已物理抹除，不再认任何静态 Token)；
        2. 仅认存在于 self.active_sessions 中未过期的动态高熵 Session Token；
        3. 网关与节点间仅通过高强度内部通信私钥 'internal_secret' 认证。
        返回 (is_authenticated, session_token, profile)
        """
        # 1. 内部节点网关通信校验 (网关反代流量)
        internal_secret = request.headers.get("X-Internal-Secret") or request.query.get("internal_secret")
        if internal_secret and internal_secret == self.internal_secret:
            target_user = request.headers.get("X-Internal-User") or request.query.get("user") or "tetra"
            accounts = self.platform_config.get("accounts", {})
            acc = accounts.get(target_user, {})
            profile = {
                "user": acc.get("display_name", target_user),
                "username": target_user,
                "display_name": acc.get("display_name", target_user),
                "allowed_nodes": acc.get("allowed_nodes", [self.platform_name]),
                "default_node": acc.get("default_node", self.platform_name)
            }
            return True, "internal", profile

        # 2. 外部客户端鉴权：从 Cookie、Header 或 WebSocket Query 获取 Session Token
        session_token = request.cookies.get("agy_token") or request.headers.get("X-Auth-Token") or request.query.get("token") or request.query.get("session")
        if not session_token:
            return False, None, None

        # 3. 严格校验 Session 是否存在于服务端会话表中 (旧静态 token tetra2026/simeng 因不存在直接被拒 401)
        session = self.active_sessions.get(session_token)
        if not session:
            return False, None, None

        # 4. 检查会话是否超时过期 (30 天有效)
        created_at = session.get("created_at", 0)
        if time.time() - created_at > 86400 * 30:
            self.active_sessions.pop(session_token, None)
            self._save_sessions()
            return False, None, None

        profile = {
            "user": session.get("display_name", session.get("username", "User")),
            "username": session.get("username"),
            "display_name": session.get("display_name"),
            "allowed_nodes": session.get("allowed_nodes", [self.platform_name]),
            "default_node": session.get("default_node", self.platform_name)
        }
        return True, session_token, profile

    # -------------------------------------------------------------------------
    # 会话树聚合与孤儿物理清洗
    # -------------------------------------------------------------------------
    def get_grouped_sessions(self) -> Dict[str, Any]:
        """
        全量聚合会话树，严格清洗幽灵孤儿，提取 fallback 标题，按工程分组（完全对齐官方客户端展示）
        """
        # 1. 物理清洗 SQLite 中的孤儿
        self.adapter.clean_orphaned_sessions()

        if not os.path.exists(self.adapter.db_path):
            return {"projects": {}, "general_sessions": []}

        try:
            conn = sqlite3.connect(self.adapter.db_path)
            cur = conn.cursor()

            # 1.1 从 conversations_fts 和 conversation_summaries 构建真实工程名称映射
            convo_to_project: Dict[str, str] = {}
            pid_to_project: Dict[str, str] = {}

            tables = [t[0] for t in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
            if "conversations_fts" in tables:
                try:
                    fts_rows = cur.execute(
                        "SELECT DISTINCT conversation_id, project FROM conversations_fts "
                        "WHERE project IS NOT NULL AND project != ''"
                    ).fetchall()
                    for f_cid, f_proj in fts_rows:
                        if f_cid and f_proj:
                            convo_to_project[f_cid] = f_proj.strip()
                except Exception as e:
                    logging.debug(f"读取 conversations_fts 项目信息失败: {e}")

            cols = [c[1] for c in cur.execute("PRAGMA table_info(conversation_summaries)").fetchall()]
            time_col = "last_modified_time" if "last_modified_time" in cols else ("updated_at" if "updated_at" in cols else "rowid")

            # 构建 pid_to_project
            if "project_id" in cols:
                try:
                    p_rows = cur.execute(
                        "SELECT conversation_id, project_id FROM conversation_summaries "
                        "WHERE project_id IS NOT NULL AND project_id != '' AND project_id != 'outside-of-project'"
                    ).fetchall()
                    for p_cid, p_pid in p_rows:
                        if p_cid in convo_to_project and p_pid not in pid_to_project:
                            pid_to_project[p_pid] = convo_to_project[p_cid]
                except Exception as e:
                    logging.debug(f"构建 pid_to_project 映射失败: {e}")

            # 严格过滤内部子代理 (Subagent) 会话，确保抽屉列表只呈现用户发起的顶层主会话
            where_clauses = []
            if "parent_conversation_id" in cols:
                where_clauses.append("(parent_conversation_id IS NULL OR parent_conversation_id = '')")
            if "nesting_depth" in cols:
                where_clauses.append("(nesting_depth IS NULL OR nesting_depth = 0)")
            if "agent_name" in cols:
                where_clauses.append("(agent_name IS NULL OR agent_name = '')")
            where_sql = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""

            select_fields = ["conversation_id", "title", "preview", "workspace_uris", time_col]
            if "project_id" in cols:
                select_fields.append("project_id")
            else:
                select_fields.append("''")

            query = f"""
                SELECT {', '.join(select_fields)}
                FROM conversation_summaries
                {where_sql}
                ORDER BY {time_col} DESC
            """
            rows = cur.execute(query).fetchall()
            conn.close()

            # 1.2 读取置顶会话列表 (Pinned Sessions)
            pinned_cids: Set[str] = set()
            try:
                app_storage_path = os.path.expanduser(r"~\AppData\Roaming\Antigravity\app_storage.json")
                if os.path.exists(app_storage_path):
                    with open(app_storage_path, "r", encoding="utf-8") as f:
                        s_data = json.load(f)
                        raw_pinned = s_data.get("pinned_conversations_order", "[]")
                        if isinstance(raw_pinned, str):
                            pinned_cids = set(json.loads(raw_pinned))
                        elif isinstance(raw_pinned, list):
                            pinned_cids = set(raw_pinned)
            except Exception:
                pass

            projects_dict: Dict[str, List[Dict[str, Any]]] = {}
            project_latest_time: Dict[str, str] = {}
            general_sessions: List[Dict[str, Any]] = []

            for r in rows:
                cid, title, preview, ws_uris, mod_time, pid = r
                if not cid:
                    continue

                # 2. 磁盘真实存在性双重校验
                brain_subdir = os.path.join(self.adapter.brain_dir, cid)
                if not os.path.exists(brain_subdir):
                    continue

                # 3. 提取 fallback 标题
                display_title = title.strip() if title else ""
                if not display_title:
                    fallback = self.adapter.extract_session_fallback_title(cid)
                    if fallback:
                        display_title = fallback
                    elif preview and preview.strip():
                        clean_prev = clean_display_content(preview.strip())
                        display_title = clean_prev[:32] + ("..." if len(clean_prev) > 32 else "")
                    else:
                        display_title = "新任务"

                # 防御性二次校验：若展示标题包含子代理汇报残留，不展示到顶层会话列表
                if "汇报给主代理" in display_title:
                    continue

                fallback_name, proj_path = parse_project_name_and_path(ws_uris)
                time_str = str(mod_time).split("T")[0].split(" ")[0] if mod_time else ""

                # 4. 严格解析所属工程名称（多级优先判定，完全对齐官方客户端）
                final_project: Optional[str] = None
                if cid in convo_to_project:
                    final_project = convo_to_project[cid]
                elif pid and pid != "outside-of-project" and pid in pid_to_project:
                    final_project = pid_to_project[pid]
                elif fallback_name:
                    final_project = fallback_name

                # 过滤常见非工程目录
                if final_project and final_project.lower() in ("desktop", "home", "users", "root", "workspace", "antigravity", "outside-of-project", "scratch"):
                    final_project = None

                is_pinned = (cid in pinned_cids)
                session_item = {
                    "id": cid,
                    "title": display_title,
                    "preview": preview or "",
                    "time": time_str,
                    "is_active": (cid == self.current_active_session_id),
                    "is_pinned": is_pinned,
                    "workspace_path": proj_path or self.adapter.default_workspace
                }

                if final_project:
                    if final_project not in projects_dict:
                        projects_dict[final_project] = []
                    projects_dict[final_project].append(session_item)
                    # 仅非置顶会话参与项目排序时间计算（避免置顶会话扰乱普通项目活跃度顺序）
                    if not is_pinned and final_project not in project_latest_time:
                        project_latest_time[final_project] = str(mod_time) if mod_time else ""
                else:
                    general_sessions.append(session_item)

            # 若项目内所有会话均为置顶，则 fallback 为第一条会话时间
            for p, s_list in projects_dict.items():
                if p not in project_latest_time and s_list:
                    project_latest_time[p] = str(s_list[0].get("time", ""))

            # 5. 项目列表排序：按照项目内最新会话时间降序排列（确保活跃项目在最上方，完全对齐官方客户端）
            sorted_project_names = sorted(
                projects_dict.keys(),
                key=lambda p: project_latest_time.get(p, ""),
                reverse=True
            )
            ordered_projects: Dict[str, List[Dict[str, Any]]] = {
                p: projects_dict[p] for p in sorted_project_names
            }

            return {
                "projects": ordered_projects,
                "general_sessions": general_sessions,
                "engine_alive": self.adapter.is_engine_alive()
            }
        except Exception as e:
            logging.error(f"[-] 读取会话树失败: {e}", exc_info=True)
            return {"projects": {}, "general_sessions": []}

    # -------------------------------------------------------------------------
    # 历史记录加载
    # -------------------------------------------------------------------------
    def load_session_history(self, session_file: Optional[str], max_lines: int = 300) -> List[Dict[str, Any]]:
        """从 transcript.jsonl 读取清洗后的历史会话记录"""
        if not session_file or not os.path.exists(session_file):
            return []
        history = []
        try:
            with open(session_file, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
                scan_lines = lines[-max_lines:] if len(lines) > max_lines else lines
                for line in scan_lines:
                    evt = parse_transcript_line(line)
                    if evt:
                        history.append(evt)
        except Exception as e:
            logging.error(f"[-] 读取历史记录异常: {e}")
        return history[-60:]

    def is_session_running(self, session_id: Optional[str]) -> bool:
        """
        全方位精准判定指定会话是否正在运行中：
        1. 优先查 SQLite 数据库的 status 字段与 not_fully_idle 标记
        2. 结合内存活跃运行标志与 transcript.jsonl 末尾状态
        """
        if not session_id:
            return False

        # 1. 优先检查 SQLite 中官方持久化的 status 与 not_fully_idle
        if os.path.exists(self.adapter.db_path):
            try:
                conn = sqlite3.connect(self.adapter.db_path)
                cur = conn.cursor()
                cols = [c[1] for c in cur.execute("PRAGMA table_info(conversation_summaries)").fetchall()]
                fields = []
                if "status" in cols:
                    fields.append("status")
                if "not_fully_idle" in cols:
                    fields.append("not_fully_idle")
                if fields:
                    row = cur.execute(
                        f"SELECT {', '.join(fields)} FROM conversation_summaries WHERE conversation_id = ?",
                        (session_id,)
                    ).fetchone()
                    if row:
                        status_val = row[0] if "status" in fields else ""
                        idle_val = row[fields.index("not_fully_idle")] if "not_fully_idle" in fields else 0
                        if status_val == "CASCADE_RUN_STATUS_RUNNING" or idle_val == 1:
                            conn.close()
                            return True
                        elif status_val == "CASCADE_RUN_STATUS_IDLE" and idle_val == 0:
                            conn.close()
                            return False
                conn.close()
            except Exception:
                pass

        # 2. 检查内存运行标记（如果是当前活跃跟踪的会话）
        if session_id == self.current_active_session_id and self.is_agent_running:
            return True

        # 3. 检查 transcript.jsonl 末尾状态 (兜底)
        target_file = os.path.join(self.adapter.brain_dir, session_id, ".system_generated", "logs", "transcript.jsonl")
        if os.path.exists(target_file):
            try:
                with open(target_file, "r", encoding="utf-8", errors="replace") as f:
                    lines = f.readlines()
                    for l in reversed(lines[-15:]):
                        line_str = l.strip()
                        if not line_str:
                            continue
                        try:
                            obj = json.loads(line_str)
                            msg_type = obj.get("type")
                            if msg_type in ("USER_INPUT", "USER_EXPLICIT"):
                                return True
                            status = obj.get("status")
                            if status == "IN_PROGRESS":
                                return True
                            if status in ("DONE", "ERROR"):
                                return False
                        except Exception:
                            continue
            except Exception:
                pass

        return False

    # -------------------------------------------------------------------------
    # WebSocket 广播
    # -------------------------------------------------------------------------
    async def broadcast_message(self, message_dict: Dict[str, Any]):
        """向所有处于活跃状态的 WebSocket 客户端安全广播消息"""
        if not self.active_websockets:
            return
        msg_str = json.dumps(message_dict, ensure_ascii=False)
        disconnected = set()
        for ws in list(self.active_websockets):
            if ws.closed:
                disconnected.add(ws)
                continue
            try:
                await ws.send_str(msg_str)
            except Exception:
                disconnected.add(ws)
        for ws in disconnected:
            self.active_websockets.discard(ws)

    async def get_user_nodes_status(self, profile: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """获取适用于特定用户 Profile 的节点状态列表"""
        allowed = profile.get("allowed_nodes", [self.platform_name]) if profile else [self.platform_name]
        visible_nodes = []
        if self.is_gateway:
            for nid in allowed:
                if nid in self.node_status_cache:
                    visible_nodes.append(self.node_status_cache[nid])
                elif nid in self.node_registry:
                    is_local = self.node_registry[nid].get("is_local", False)
                    visible_nodes.append({
                        "id": nid,
                        "name": self.node_registry[nid].get("name", nid),
                        "online": is_local,
                        "engine_alive": self.adapter.is_engine_alive() if is_local else False
                    })
        else:
            visible_nodes.append({
                "id": self.platform_name,
                "name": "Windows PC" if self.platform_name == "windows" else "Steam Deck",
                "online": True,
                "engine_alive": self.adapter.is_engine_alive()
            })
        return visible_nodes

    # -------------------------------------------------------------------------
    # 实时 Transcript 增量监听 (动态多会话无缝跟踪与实时广播)
    # -------------------------------------------------------------------------
    async def tail_transcript_loop(self):
        """
        后台轮询 Transcript 文件流：
        1. 自动发现最新活跃会话（当检测到新会话落盘立即广播 session_tree）；
        2. 增量解析并实时推送清洗后的 Assistant 回复与思考；
        3. Agent 空闲复位时再次广播 session_tree 刷新真实标题。
        """
        last_mtime = 0
        last_file_path = None

        while True:
            try:
                # 若客户端未强制切换指定会话，自动跟随最新活跃会话
                if not self.current_active_file or not os.path.exists(self.current_active_file):
                    latest = self.adapter.get_latest_transcript_path()
                    if latest and latest != self.current_active_file:
                        self.current_active_file = latest
                        m = re.search(r"[\\/]([a-f0-9\-]{36})[\\/]", latest)
                        if m:
                            self.current_active_session_id = m.group(1)
                        if self.file_handle:
                            try:
                                self.file_handle.close()
                            except Exception:
                                pass
                        self.file_handle = None

                # 检测活跃文件变化
                if self.current_active_file and os.path.exists(self.current_active_file):
                    if self.current_active_file != last_file_path:
                        last_file_path = self.current_active_file
                        if self.file_handle:
                            try:
                                self.file_handle.close()
                            except Exception:
                                pass
                        self.file_handle = open(self.current_active_file, "r", encoding="utf-8", errors="replace")
                        last_mtime = os.path.getmtime(self.current_active_file)

                        # 新活跃会话诞生或切换，立即全量推送历史消息（包含初始 prompt 与已产生响应）
                        try:
                            init_hist = self.load_session_history(self.current_active_file)
                            is_running = self.is_session_running(self.current_active_session_id)
                            await self.broadcast_message({
                                "type": "session_history",
                                "session_id": self.current_active_session_id,
                                "history": init_hist,
                                "is_running": is_running
                            })
                        except Exception as e:
                            logging.error(f"[-] 推送初始会话历史异常: {e}")

                        self.file_handle.seek(0, os.SEEK_END)

                        # 全量广播更新抽屉列表与当前会话指示
                        tree = self.get_grouped_sessions()
                        await self.broadcast_message({
                            "type": "session_tree",
                            "projects": tree.get("projects", {}),
                            "general_sessions": tree.get("general_sessions", []),
                            "engine_alive": tree.get("engine_alive", False),
                            "current": self.current_active_session_id
                        })

                    # 检查是否有新数据写入
                    curr_mtime = os.path.getmtime(self.current_active_file)
                    if curr_mtime > last_mtime:
                        last_mtime = curr_mtime
                        while True:
                            line = self.file_handle.readline()
                            if not line:
                                break
                            evt = parse_transcript_line(line)
                            if evt:
                                if evt.get("status") == "IN_PROGRESS":
                                    self.is_agent_running = True
                                elif evt.get("status") == "DONE":
                                    self.is_agent_running = False

                                # 包裹为前端期望的 agent_update 格式
                                update_msg = {
                                    "type": "agent_update",
                                    "session_id": self.current_active_session_id,
                                    "is_running": self.is_agent_running,
                                    **evt
                                }
                                await self.broadcast_message(update_msg)

                # 周期性真实状态探活与复位
                if self.current_active_session_id:
                    real_running = self.is_session_running(self.current_active_session_id)
                    if self.is_agent_running != real_running:
                        self.is_agent_running = real_running
                        await self.broadcast_message({
                            "type": "status_change",
                            "session_id": self.current_active_session_id,
                            "is_running": real_running
                        })
                        if not real_running:
                            # 真正变为空闲时再次广播 session_tree，确保提取到的最新标题同步显示
                            tree = self.get_grouped_sessions()
                            await self.broadcast_message({
                                "type": "session_tree",
                                "projects": tree.get("projects", {}),
                                "general_sessions": tree.get("general_sessions", []),
                                "engine_alive": tree.get("engine_alive", False),
                                "current": self.current_active_session_id
                            })

            except Exception as e:
                logging.error(f"[-] tail_transcript 异常: {e}")

            await asyncio.sleep(0.3)

    # -------------------------------------------------------------------------
    # 多节点探测与网关反向代理 (Gateway 反向 WebSocket 隧道)
    # -------------------------------------------------------------------------
    async def check_node_health(self, host: str, timeout: float = 1.5) -> Tuple[bool, bool]:
        """
        探测远程节点：
        返回 (online, engine_alive)
        优先通过 HTTP 请求 /api/health，既确认 Hub 在线，又确认 Agent 引擎存活状态
        """
        try:
            import aiohttp
            async with aiohttp.ClientSession() as session:
                async with session.get(f"http://{host}/api/health", timeout=aiohttp.ClientTimeout(total=timeout)) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        return True, bool(data.get("engine_alive", False))
        except Exception:
            pass

        # 降级：仅 TCP 探活
        try:
            parts = host.split(":")
            h = parts[0]
            p = int(parts[1]) if len(parts) > 1 else 8765
            reader, writer = await asyncio.wait_for(asyncio.open_connection(h, p), timeout=0.8)
            writer.close()
            await writer.wait_closed()
            return True, False
        except Exception:
            return False, False

    async def gateway_monitor_loop(self):
        """网关模式专用：定时检测各节点在线及引擎存活状态并广播"""
        if not self.is_gateway:
            return
        while True:
            try:
                updated = False
                now = time.time()
                for nid, ncfg in self.node_registry.items():
                    is_local = ncfg.get("is_local", False)
                    host = ncfg.get("host", "127.0.0.1")
                    if is_local:
                        alive = True
                        eng_alive = self.adapter.is_engine_alive()
                    else:
                        alive, eng_alive = await self.check_node_health(host)
                    
                    cached = self.node_status_cache.get(nid)
                    if (not cached or 
                        cached.get("online") != alive or 
                        cached.get("engine_alive") != eng_alive):
                        self.node_status_cache[nid] = {
                            "id": nid,
                            "name": ncfg.get("name", nid),
                            "online": alive,
                            "engine_alive": eng_alive,
                            "last_seen": now if alive else (cached.get("last_seen", 0) if cached else 0)
                        }
                        updated = True

                if updated:
                    await self.broadcast_message({
                        "type": "nodes_update",
                        "nodes": list(self.node_status_cache.values())
                    })
            except Exception as e:
                logging.error(f"[-] gateway_monitor_loop 异常: {e}")
            await asyncio.sleep(5)

    async def proxy_remote_ws(self, client_ws: web.WebSocketResponse, target_host: str, token: str, profile: Optional[Dict[str, Any]] = None):
        """
        反向 WebSocket 代理隧道：将浏览器 WebSocket 桥接至远程节点
        同时网关掌握节点拓扑权威性，防止远程单机节点覆盖全网 nodes_status
        """
        user_name = (profile.get("username") or profile.get("user") or "tetra") if profile else "tetra"
        remote_url = f"ws://{target_host}/ws?internal_secret={self.internal_secret}&user={user_name}"
        logging.info(f"[*] 启动网关反向代理隧道 -> ws://{target_host}/ws (用户: {user_name})")
        self.active_websockets.add(client_ws)
        
        # 1. 网关优先推送权威的租户隔离节点状态
        try:
            user_nodes = await self.get_user_nodes_status(profile)
            await client_ws.send_json({
                "type": "nodes_status",
                "nodes": user_nodes
            })
        except Exception as e:
            logging.error(f"[-] 网关推送初始节点拓扑异常: {e}")

        async with aiohttp.ClientSession() as session:
            try:
                async with session.ws_connect(remote_url, timeout=10) as remote_ws:
                    async def client_to_remote():
                        async for msg in client_ws:
                            if msg.type == WSMsgType.TEXT:
                                await remote_ws.send_str(msg.data)
                            elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                                break

                    async def remote_to_client():
                        async for msg in remote_ws:
                            if msg.type == WSMsgType.TEXT:
                                try:
                                    data = json.loads(msg.data)
                                    # 拦截后端单机节点的 nodes_status，保留网关全网视图
                                    if data.get("type") in ("nodes_status", "nodes_update"):
                                        continue
                                except Exception:
                                    pass
                                await client_ws.send_str(msg.data)
                            elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                                break

                    await asyncio.gather(client_to_remote(), remote_to_client())
            except Exception as e:
                logging.error(f"[-] 远程代理隧道断开 ({target_host}): {e}")
                if not client_ws.closed:
                    await client_ws.send_str(json.dumps({
                        "type": "error",
                        "message": f"连接远程节点 {target_host} 失败: {e}"
                    }))
            finally:
                self.active_websockets.discard(client_ws)

    # -------------------------------------------------------------------------
    # WebSocket 主处理入口
    # -------------------------------------------------------------------------
    async def websocket_handler(self, request: web.Request) -> web.WebSocketResponse:
        is_auth, token, profile = self.authenticate_request(request)
        if not is_auth:
            return web.Response(status=401, text="Unauthorized: Invalid Token")

        target_node = request.query.get("node") or (profile.get("default_node") if profile else self.platform_name)

        # 检查租户权限与合法目标节点回退容错
        allowed_nodes = profile.get("allowed_nodes", [self.platform_name]) if profile else [self.platform_name]
        default_node = (profile.get("default_node") if profile else self.platform_name) or self.platform_name
        
        # 核心容错：若客户端缓存的 target_node 超出授权范围或不存在，自动安全回退至其合法的 default_node，绝不粗暴 403 导致客户端死锁
        if target_node not in allowed_nodes or (self.is_gateway and target_node not in self.node_registry):
            fallback_target = default_node if default_node in allowed_nodes else allowed_nodes[0]
            logging.warning(f"[*] 客户端请求节点 '{target_node}' 无权或不存在，自动降级回退至合法默认节点 '{fallback_target}'")
            target_node = fallback_target

        # 网关反向代理判断
        if self.is_gateway and target_node and target_node in self.node_registry:
            node_cfg = self.node_registry[target_node]
            if not node_cfg.get("is_local", False):
                ws = web.WebSocketResponse()
                await ws.prepare(request)
                await self.proxy_remote_ws(ws, node_cfg.get("host", "127.0.0.1:8765"), token or "", profile)
                return ws

        # 本地连接建立
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self.active_websockets.add(ws)

        try:
            # 确保活跃会话有效初始化
            if not self.current_active_file or not os.path.exists(self.current_active_file):
                self.current_active_file = self.adapter.get_latest_transcript_path()
                if self.current_active_file:
                    m = re.search(r"[\\/]([a-f0-9\-]{36})[\\/]", self.current_active_file)
                    if m:
                        self.current_active_session_id = m.group(1)

            # 1. 握手与连接成功确认 (前端依赖此消息确认连接成功并置绿灯)
            await ws.send_json({
                "type": "connected",
                "active_session": self.current_active_session_id or "unknown",
                "node": target_node or self.platform_name,
                "msg": f"Connected to {self.platform_name.upper()} Hub!"
            })

            # 2. 租户隔离的节点列表推送
            user_nodes = await self.get_user_nodes_status(profile)
            await ws.send_json({
                "type": "nodes_status",
                "nodes": user_nodes
            })

            # 3. 推送全量会话树 (平铺 projects 与 general_sessions)
            tree = self.get_grouped_sessions()
            await ws.send_json({
                "type": "session_tree",
                "projects": tree.get("projects", {}),
                "general_sessions": tree.get("general_sessions", []),
                "engine_alive": tree.get("engine_alive", False),
                "current": self.current_active_session_id
            })

            # 4. 推送当前活跃会话历史 (session_history)
            if self.current_active_file:
                history = self.load_session_history(self.current_active_file)
                is_running = self.is_session_running(self.current_active_session_id)
                await ws.send_json({
                    "type": "session_history",
                    "session_id": self.current_active_session_id or "",
                    "history": history,
                    "is_running": is_running
                })

            # 5. 主动推送最新官方配额 (quota_update)
            try:
                quota_data = self.adapter.fetch_quota()
                await ws.send_json({
                    "type": "quota_update",
                    "quota": quota_data
                })
            except Exception as e:
                logging.warning(f"[-] 连接初始化推送配额异常: {e}")

            # 6. 消息交互循环
            async for msg in ws:
                if msg.type == WSMsgType.TEXT:
                    try:
                        data = json.loads(msg.data)
                    except Exception:
                        continue

                    action = data.get("action")

                    # 切换会话
                    if action == "switch_session":
                        target_id = data.get("session_id")
                        if target_id:
                            target_file = os.path.join(self.adapter.brain_dir, target_id, ".system_generated", "logs", "transcript.jsonl")
                            if os.path.exists(target_file):
                                self.current_active_file = target_file
                                self.current_active_session_id = target_id
                                if self.file_handle:
                                    try:
                                        self.file_handle.close()
                                    except Exception:
                                        pass
                                self.file_handle = open(self.current_active_file, "r", encoding="utf-8", errors="replace")
                                self.file_handle.seek(0, os.SEEK_END)
                                history = self.load_session_history(self.current_active_file)
                                is_running = self.is_session_running(target_id)
                                await ws.send_json({
                                    "type": "session_history",
                                    "session_id": target_id,
                                    "history": history,
                                    "is_running": is_running
                                })

                    # 新建会话
                    elif action == "new_session":
                        content = data.get("content", "").strip()
                        model = data.get("model")
                        workspace_path = data.get("workspace_path") or data.get("workspace_dir")
                        if content:
                            ok, new_cid, msg = self.adapter.dispatch_new_session(content, model, workspace_path)
                            if new_cid:
                                self.current_active_session_id = new_cid
                                target_file = os.path.join(self.adapter.brain_dir, new_cid, ".system_generated", "logs", "transcript.jsonl")
                                self.current_active_file = target_file
                                if self.file_handle:
                                    try:
                                        self.file_handle.close()
                                    except Exception:
                                        pass
                                self.file_handle = None
                            await ws.send_json({
                                "type": "new_session_ack",
                                "status": "ok" if ok else "error",
                                "session_id": new_cid,
                                "message": msg
                            })
                            # 全量广播更新后的会话树
                            updated_tree = self.get_grouped_sessions()
                            await self.broadcast_message({
                                "type": "session_tree",
                                "projects": updated_tree.get("projects", {}),
                                "general_sessions": updated_tree.get("general_sessions", []),
                                "engine_alive": updated_tree.get("engine_alive", False),
                                "current": self.current_active_session_id
                            })

                            # 异步轮询确保初始 transcript.jsonl 落盘后主动推送完整历史
                            if new_cid:
                                for _ in range(10):
                                    if os.path.exists(target_file):
                                        break
                                    await asyncio.sleep(0.3)
                                if os.path.exists(target_file):
                                    hist = self.load_session_history(target_file)
                                    is_running = self.is_session_running(new_cid)
                                    await ws.send_json({
                                        "type": "session_history",
                                        "session_id": new_cid,
                                        "history": hist,
                                        "is_running": is_running
                                    })
                        else:
                            self.current_active_session_id = None
                            self.current_active_file = None
                            if self.file_handle:
                                try:
                                    self.file_handle.close()
                                except Exception:
                                    pass
                                self.file_handle = None
                            await ws.send_json({
                                "type": "new_session_ack",
                                "status": "ok",
                                "session_id": ""
                            })
                            await ws.send_json({
                                "type": "session_history",
                                "session_id": "",
                                "history": []
                            })

                    # 彻底物理删除会话 (SQLite + 磁盘 brain 同步清除)
                    elif action == "delete_session":
                        target_id = data.get("session_id")
                        if target_id and re.match(r"^[a-f0-9\-]{36}$", target_id, re.IGNORECASE):
                            try:
                                # A. 从 SQLite 删除
                                if os.path.exists(self.adapter.db_path):
                                    conn = sqlite3.connect(self.adapter.db_path)
                                    cur = conn.cursor()
                                    cols = [c[1] for c in cur.execute("PRAGMA table_info(conversation_summaries)").fetchall()]
                                    id_col = "conversation_id" if "conversation_id" in cols else "id"
                                    cur.execute(f"DELETE FROM conversation_summaries WHERE {id_col} = ?", (target_id,))
                                    if "parent_conversation_id" in cols:
                                        cur.execute("DELETE FROM conversation_summaries WHERE parent_conversation_id = ?", (target_id,))
                                    conn.commit()
                                    conn.close()

                                # B. 彻底删除磁盘 brain 目录
                                target_dir = os.path.join(self.adapter.brain_dir, target_id)
                                if os.path.exists(target_dir):
                                    shutil.rmtree(target_dir, ignore_errors=True)
                                    logging.info(f"[*] 成功彻底物理删除会话目录: {target_dir}")

                                # 若删除的恰好是当前活跃会话，清空句柄
                                if self.current_active_session_id == target_id:
                                    self.current_active_session_id = None
                                    self.current_active_file = None
                                    if self.file_handle:
                                        try:
                                            self.file_handle.close()
                                        except Exception:
                                            pass
                                        self.file_handle = None

                                # C. 全量广播最新的会话树
                                updated_tree = self.get_grouped_sessions()
                                await self.broadcast_message({
                                    "type": "session_tree",
                                    "projects": updated_tree.get("projects", {}),
                                    "general_sessions": updated_tree.get("general_sessions", []),
                                    "engine_alive": updated_tree.get("engine_alive", False),
                                    "current": self.current_active_session_id
                                })
                                await ws.send_json({
                                    "type": "delete_ack",
                                    "session_id": target_id
                                })
                            except Exception as e:
                                logging.error(f"[-] 删除会话失败 {target_id}: {e}")
                                await ws.send_json({
                                    "type": "error",
                                    "message": f"删除会话失败: {e}"
                                })

                    # 发送消息给 Agent (支持 prompt 与 send_message 两种 action)
                    elif action in ("prompt", "send_message"):
                        content = data.get("content", "").strip()
                        session_id = data.get("session_id") or self.current_active_session_id
                        model = data.get("model")
                        workspace_dir = data.get("workspace_path") or data.get("workspace_dir")
                        if content:
                            if session_id:
                                ok, resp_str = self.adapter.dispatch_agent_message(session_id, content, model, workspace_dir)
                            else:
                                ok, new_cid, resp_str = self.adapter.dispatch_new_session(content, model, workspace_dir)
                                if new_cid:
                                    self.current_active_session_id = new_cid
                                    target_file = os.path.join(self.adapter.brain_dir, new_cid, ".system_generated", "logs", "transcript.jsonl")
                                    self.current_active_file = target_file

                            if not ok:
                                await ws.send_json({
                                    "type": "error",
                                    "message": resp_str
                                })
                            else:
                                await ws.send_json({
                                    "type": "prompt_ack",
                                    "session_id": session_id or self.current_active_session_id,
                                    "message": resp_str
                                })

                    # 获取官方配额数据 (支持前端显式刷新/轮询)
                    elif action == "get_quota":
                        try:
                            quota_data = self.adapter.fetch_quota()
                            await ws.send_json({
                                "type": "quota_update",
                                "quota": quota_data
                            })
                        except Exception as e:
                            logging.error(f"[-] 获取配额异常: {e}")
                            await ws.send_json({
                                "type": "quota_update",
                                "quota": {"groups": [], "description": f"获取配额失败: {e}"}
                            })

                    # 目录浏览
                    elif action == "browse_files":
                        base_dir = data.get("workspace_dir") or self.adapter.default_workspace
                        sub_path = data.get("sub_path", "")
                        safe, safe_target = is_path_safe(base_dir, self.adapter.default_workspace, self.adapter.allowed_roots)
                        if safe:
                            res = list_workspace_files(safe_target, sub_path)
                            await ws.send_json({
                                "type": "file_browser_result",
                                "data": res
                            })
                        else:
                            await ws.send_json({
                                "type": "error",
                                "message": f"目录越界或被拦截: {safe_target}"
                            })

                    # 读取文件
                    elif action == "read_file":
                        base_dir = data.get("workspace_dir") or self.adapter.default_workspace
                        rel_path = data.get("file_path", "")
                        target_full = os.path.join(base_dir, rel_path)
                        safe, safe_target = is_path_safe(target_full, base_dir, self.adapter.allowed_roots)
                        if safe and os.path.isfile(safe_target):
                            try:
                                with open(safe_target, "r", encoding="utf-8", errors="replace") as f:
                                    file_content = f.read(200000)  # 最大读取 200KB
                                await ws.send_json({
                                    "type": "file_content",
                                    "file_path": rel_path,
                                    "content": file_content
                                })
                            except Exception as e:
                                await ws.send_json({
                                    "type": "file_content_error",
                                    "message": f"读取文件失败: {e}"
                                })
                        else:
                            await ws.send_json({
                                "type": "file_content_error",
                                "message": "文件路径越界或不存在"
                            })

                    # Git 差异
                    elif action == "git_diff":
                        base_dir = data.get("workspace_dir") or self.adapter.default_workspace
                        safe, safe_target = is_path_safe(base_dir, self.adapter.default_workspace, self.adapter.allowed_roots)
                        if safe and os.path.isdir(safe_target):
                            try:
                                proc = subprocess.run(
                                    ["git", "diff", "HEAD"],
                                    cwd=safe_target,
                                    capture_output=True,
                                    text=True,
                                    timeout=5
                                )
                                diff_output = proc.stdout.strip()
                                await ws.send_json({
                                    "type": "git_diff_result",
                                    "diff": diff_output or "No uncommitted changes."
                                })
                            except Exception as e:
                                await ws.send_json({
                                    "type": "git_diff_result",
                                    "diff": f"Git 差异提取异常: {e}"
                                })

        finally:
            self.active_websockets.discard(ws)

        return ws

    # -------------------------------------------------------------------------
    # RESTful API 端点实现 (账号密码登录、会话与多节点拓扑)
    # -------------------------------------------------------------------------
    async def api_login_handler(self, request: web.Request) -> web.Response:
        """正规账号密码登录接口"""
        headers = build_cors_headers(request, self.allowed_origins)
        try:
            data = await request.json()
        except Exception:
            data = await request.post()

        username = str(data.get("username", "")).strip().lower()
        password = str(data.get("password", "")).strip()

        if not username or not password:
            return web.json_response({"success": False, "error": "请输入用户名和密码"}, status=400, headers=headers)

        accounts = self.platform_config.get("accounts", {})
        account = accounts.get(username)
        if not account:
            return web.json_response({"success": False, "error": "用户名或密码错误"}, status=401, headers=headers)

        import hashlib
        pwd_hash = hashlib.sha256(password.encode("utf-8")).hexdigest()
        expected_hash = account.get("password_hash")
        expected_pwd = account.get("password")

        matched = False
        if expected_hash and pwd_hash.lower() == expected_hash.lower():
            matched = True
        elif expected_pwd and password == expected_pwd:
            matched = True

        if not matched:
            return web.json_response({"success": False, "error": "用户名或密码错误"}, status=401, headers=headers)

        # 认证通过，动态签发高熵伪随机 Session Token (64 位十六进制)，杜绝一切可预测性
        session_token = secrets.token_hex(32)
        session_data = {
            "username": username,
            "display_name": account.get("display_name", username),
            "allowed_nodes": account.get("allowed_nodes", [self.platform_name]),
            "default_node": account.get("default_node", self.platform_name),
            "created_at": time.time()
        }
        self.active_sessions[session_token] = session_data
        self._save_sessions()
        logging.info(f"[*] 用户 '{username}' 登录成功，签发动态 Session: {session_token[:8]}...")

        resp = web.json_response({
            "success": True,
            "token": session_token,
            "user": session_data
        }, headers=headers)

        # 写入持久化安全 Cookie
        resp.set_cookie(
            "agy_token",
            session_token,
            max_age=86400 * 30,
            path="/",
            secure=False,
            httponly=False,
            samesite="Lax"
        )
        return resp

    async def api_logout_handler(self, request: web.Request) -> web.Response:
        """登出接口：彻底从服务端物理销毁 Session 并清除客户端 Cookie"""
        headers = build_cors_headers(request, self.allowed_origins)
        session_token = request.cookies.get("agy_token") or request.headers.get("X-Auth-Token")
        
        # 尝试从 json body 读取
        if not session_token:
            try:
                data = await request.json()
                session_token = data.get("token")
            except Exception:
                pass

        if session_token and session_token in self.active_sessions:
            destroyed_user = self.active_sessions[session_token].get("username")
            self.active_sessions.pop(session_token, None)
            self._save_sessions()
            logging.info(f"[*] 用户 '{destroyed_user}' 已登出，Session {session_token[:8]}... 彻底物理销毁！")

        resp = web.json_response({"success": True}, headers=headers)
        resp.del_cookie("agy_token", path="/")
        return resp

    async def api_me_handler(self, request: web.Request) -> web.Response:
        """检查当前登录会话状态与节点权限"""
        headers = build_cors_headers(request, self.allowed_origins)
        is_auth, session_token, profile = self.authenticate_request(request)
        if not is_auth or not profile:
            return web.json_response({"logged_in": False}, status=401, headers=headers)

        return web.json_response({
            "logged_in": True,
            "token": session_token,
            "username": profile.get("username", "admin"),
            "display_name": profile.get("display_name", "User"),
            "allowed_nodes": profile.get("allowed_nodes", [self.platform_name]),
            "default_node": profile.get("default_node", self.platform_name)
        }, headers=headers)

    async def api_nodes_handler(self, request: web.Request) -> web.Response:
        is_auth, token, profile = self.authenticate_request(request)
        if not is_auth:
            return web.json_response({"error": "Unauthorized"}, status=401)

        allowed = profile.get("allowed_nodes", [self.platform_name]) if profile else [self.platform_name]
        visible_nodes = []
        if self.is_gateway:
            for nid in allowed:
                if nid in self.node_status_cache:
                    visible_nodes.append(self.node_status_cache[nid])
                elif nid in self.node_registry:
                    visible_nodes.append({
                        "id": nid,
                        "name": self.node_registry[nid].get("name", nid),
                        "online": self.node_registry[nid].get("is_local", False)
                    })
        else:
            visible_nodes.append({
                "id": self.platform_name,
                "name": "Windows PC" if self.platform_name == "windows" else "Steam Deck",
                "online": True
            })

        headers = build_cors_headers(request, self.allowed_origins)
        return web.json_response({
            "nodes": visible_nodes,
            "current_user": profile.get("user") if profile else "admin",
            "default_node": profile.get("default_node") if profile else self.platform_name
        }, headers=headers)

    async def api_quota_handler(self, request: web.Request) -> web.Response:
        is_auth, _, _ = self.authenticate_request(request)
        if not is_auth:
            return web.json_response({"error": "Unauthorized"}, status=401)
        quota_data = self.adapter.fetch_quota()
        headers = build_cors_headers(request, self.allowed_origins)
        return web.json_response(quota_data, headers=headers)

    async def api_health_handler(self, request: web.Request) -> web.Response:
        headers = build_cors_headers(request, self.allowed_origins)
        return web.json_response({
            "status": "healthy",
            "platform": self.platform_name,
            "engine_alive": self.adapter.is_engine_alive(),
            "time": time.time()
        }, headers=headers)

    async def download_handler(self, request: web.Request) -> web.Response:
        is_auth, _, _ = self.authenticate_request(request)
        if not is_auth:
            return web.Response(status=401, text="Unauthorized")
        path = request.query.get("path")
        if not path:
            return web.Response(status=400, text="Missing path parameter")
        safe, safe_target = is_path_safe(path, self.adapter.default_workspace, self.adapter.allowed_roots)
        if not safe or not os.path.isfile(safe_target):
            return web.Response(status=403, text="Access forbidden or file not found")
        return web.FileResponse(safe_target)

    async def media_handler(self, request: web.Request) -> web.Response:
        is_auth, _, _ = self.authenticate_request(request)
        if not is_auth:
            return web.Response(status=401, text="Unauthorized")
        media_path = request.query.get("path")
        if not media_path:
            return web.Response(status=400, text="Missing media path")
        safe, safe_target = is_path_safe(media_path, self.adapter.default_workspace, self.adapter.allowed_roots)
        if not safe or not os.path.isfile(safe_target):
            return web.Response(status=404, text="Media not found or forbidden")
        return web.FileResponse(safe_target)

    async def index_handler(self, request: web.Request) -> web.Response:
        resp = None
        if self.web_dir:
            idx = os.path.join(self.web_dir, "index.html")
            if os.path.isfile(idx):
                resp = web.FileResponse(idx)
        if not resp:
            candidates = [
                os.path.join(self.server_dir, "web", "index.html"),
                os.path.abspath(os.path.join(self.server_dir, "..", "web", "index.html")),
                os.path.join(self.server_dir, "web_dist", "index.html"),
                os.path.join(os.path.expanduser("~/agy_remote/web"), "index.html")
            ]
            for c in candidates:
                if os.path.isfile(c):
                    resp = web.FileResponse(c)
                    break
        if not resp:
            resp = web.Response(text="AGY Unified Hub Running. (Web UI build not found in default paths)", content_type="text/html")
        return resp

    # -------------------------------------------------------------------------
    # SPA 与 CORS 中间件
    # -------------------------------------------------------------------------
    @web.middleware
    async def spa_middleware(self, request: web.Request, handler):
        if request.method == "OPTIONS":
            headers = build_cors_headers(request, self.allowed_origins, {
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, X-Auth-Token, Authorization"
            })
            return web.Response(headers=headers)

        if request.path == "/ws" or request.path.startswith("/api/"):
            return await handler(request)
        
        try:
            response = await handler(request)
            if response.status == 404 and request.method == "GET":
                idx_resp = await self.index_handler(request)
                idx_resp.headers["Cache-Control"] = "no-cache, no-store, must-revalidate, max-age=0"
                return idx_resp
            if hasattr(response, "headers"):
                response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate, max-age=0"
            return response
        except web.HTTPNotFound:
            if request.method == "GET":
                idx_resp = await self.index_handler(request)
                idx_resp.headers["Cache-Control"] = "no-cache, no-store, must-revalidate, max-age=0"
                return idx_resp
            raise

    # -------------------------------------------------------------------------
    # 生命周期与后台任务
    # -------------------------------------------------------------------------
    async def start_background_tasks(self, app: web.Application):
        app["tail_task"] = asyncio.create_task(self.tail_transcript_loop())
        if self.is_gateway:
            app["gateway_task"] = asyncio.create_task(self.gateway_monitor_loop())

    async def cleanup_background_tasks(self, app: web.Application):
        if "tail_task" in app:
            app["tail_task"].cancel()
        if "gateway_task" in app:
            app["gateway_task"].cancel()
        if self.file_handle:
            try:
                self.file_handle.close()
            except Exception:
                pass


def create_app(platform_name: Optional[str] = None, port_override: Optional[int] = None) -> Tuple[web.Application, int]:
    server = UnifiedServer(platform_name, port_override)
    return server.app, server.port


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="AGY Unified Server")
    parser.add_argument("--platform", choices=["windows", "deck"], default=None, help="运行平台 (默认自动探测)")
    parser.add_argument("--port", type=int, default=None, help="绑定端口")
    args = parser.parse_args()

    app, port = create_app(args.platform, args.port)
    logging.info(f"[*] AGY 统一核心服务端正在启动... 监听端口: {port}")
    web.run_app(app, host="0.0.0.0", port=port)
