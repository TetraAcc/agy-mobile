"""
平台适配器模块 (Platform Adapter Layer)
统一抽象 Windows 与 Steam Deck (Linux) 的底层环境差异：
- 物理路径与数据库目录
- 孤儿会话物理清洗与 Fallback 标题提取
- Agent 启动与派发机制 (Windows Connect-RPC vs Deck 原生 CLI 子进程)
- 配额与账号查询 (Windows Connect-RPC vs Deck systemd-run Keyring 穿透)
- 引擎健康与进程存活探测
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
import subprocess
import urllib.request
import urllib.parse
from abc import ABC, abstractmethod
from typing import Optional, Tuple, Dict, Any, List, Set

from server_common import IGNORED_MSG_TYPES, clean_display_content

class BasePlatformAdapter(ABC):
    def __init__(self, platform_name: str, config: Optional[Dict[str, Any]] = None):
        self.name = platform_name
        self.config = config or {}
        self.cached_quota: Optional[Dict[str, Any]] = None
        self.last_quota_sync: float = 0.0

    @property
    @abstractmethod
    def brain_dir(self) -> str:
        pass

    @property
    @abstractmethod
    def db_path(self) -> str:
        pass

    @property
    @abstractmethod
    def default_workspace(self) -> str:
        pass

    @property
    def allowed_roots(self) -> List[str]:
        configured = self.config.get("allowed_roots", [])
        return [os.path.expanduser(r) for r in configured]

    def clean_orphaned_sessions(self) -> int:
        """物理校验：清洗 SQLite 中存在但磁盘 brain 物理目录已被删除的幽灵孤儿会话"""
        if not os.path.exists(self.db_path) or not os.path.exists(self.brain_dir):
            return 0
        deleted_count = 0
        try:
            conn = sqlite3.connect(self.db_path)
            cur = conn.cursor()
            cols = [c[1] for c in cur.execute("PRAGMA table_info(conversation_summaries)").fetchall()]
            if not cols:
                conn.close()
                return 0
            id_col = "conversation_id" if "conversation_id" in cols else "id"
            rows = cur.execute(f"SELECT {id_col} FROM conversation_summaries").fetchall()
            orphans = []
            for (cid,) in rows:
                if not cid:
                    continue
                c_dir = os.path.join(self.brain_dir, cid)
                if not os.path.exists(c_dir):
                    orphans.append(cid)
            if orphans:
                cur.executemany(f"DELETE FROM conversation_summaries WHERE {id_col} = ?", [(cid,) for cid in orphans])
                conn.commit()
                deleted_count = len(orphans)
                logging.info(f"[{self.name}] 已自动清理 {deleted_count} 个磁盘不存在的幽灵孤儿会话")
            conn.close()
        except Exception as e:
            logging.error(f"[{self.name}] 清理孤儿会话失败: {e}")
        return deleted_count

    def extract_session_fallback_title(self, cid: str) -> Optional[str]:
        """若 title 为空，尝试从 transcript.jsonl 中提取真实用户提问作为会话展示名"""
        tpath = os.path.join(self.brain_dir, cid, ".system_generated", "logs", "transcript.jsonl")
        if not os.path.exists(tpath):
            return None
        try:
            user_input = None
            thinking_question = None
            with open(tpath, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if not line.strip():
                        continue
                    try:
                        obj = json.loads(line)
                        if obj.get("source") == "USER_EXPLICIT" or obj.get("type") == "USER_INPUT":
                            content = obj.get("content", "").strip()
                            clean = clean_display_content(content)
                            if clean:
                                user_input = clean[:32] + ("..." if len(clean) > 32 else "")
                                break
                        if not thinking_question and obj.get("type") == "PLANNER_RESPONSE":
                            thinking = obj.get("thinking", "")
                            import re
                            m = re.search(r'The user\'s question,\s*["“]([^"”]+)["”]', thinking)
                            if m:
                                thinking_question = m.group(1).strip()
                    except Exception:
                        continue
            if user_input:
                return user_input
            if thinking_question:
                return thinking_question[:32] + ("..." if len(thinking_question) > 32 else "")
        except Exception:
            pass
        return None

    def get_top_level_session_ids(self) -> Optional[Set[str]]:
        """从 SQLite 获取所有顶层主会话 ID 集合，用于严格过滤子代理"""
        if not os.path.exists(self.db_path):
            return None
        try:
            conn = sqlite3.connect(self.db_path)
            cur = conn.cursor()
            cols = [c[1] for c in cur.execute("PRAGMA table_info(conversation_summaries)").fetchall()]
            if not cols:
                conn.close()
                return None
            id_col = "conversation_id" if "conversation_id" in cols else "id"
            where_clauses = []
            if "parent_conversation_id" in cols:
                where_clauses.append("(parent_conversation_id IS NULL OR parent_conversation_id = '')")
            if "nesting_depth" in cols:
                where_clauses.append("(nesting_depth IS NULL OR nesting_depth = 0)")
            if "agent_name" in cols:
                where_clauses.append("(agent_name IS NULL OR agent_name = '')")
            where_sql = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""
            rows = cur.execute(f"SELECT {id_col} FROM conversation_summaries {where_sql}").fetchall()
            conn.close()
            return {r[0] for r in rows if r[0]}
        except Exception as e:
            logging.error(f"[{self.name}] 查询顶层会话 ID 异常: {e}")
            return None

    def get_latest_transcript_path(self) -> Optional[str]:
        """获取当前平台最新活跃会话的 transcript.jsonl（必须为顶层主会话，严格过滤内部子代理）"""
        pattern = os.path.join(self.brain_dir, "*", ".system_generated", "logs", "transcript.jsonl")
        files = glob.glob(pattern)
        if not files:
            return None
        
        top_cids = self.get_top_level_session_ids()
        files.sort(key=lambda x: os.path.getmtime(x), reverse=True)

        for f in files:
            m = re.search(r"[\\/]([a-f0-9\-]{36})[\\/]", f)
            if not m:
                continue
            cid = m.group(1)
            # 若数据库可读取顶层主会话集合，则必须在此集合内
            if top_cids is not None:
                if cid in top_cids:
                    return f
            else:
                return f
        return files[0] if files else None

    @abstractmethod
    def dispatch_agent_message(self, session_id: Optional[str], content: str, model: Optional[str] = None, workspace_dir: Optional[str] = None) -> Tuple[bool, str]:
        """派发消息给底层 Agent"""
        pass

    def dispatch_new_session(self, content: str, model: Optional[str] = None, workspace_dir: Optional[str] = None) -> Tuple[bool, str, str]:
        """开启全新会话，返回 (ok, new_conversation_id, message)"""
        return False, "", "平台未实现"

    @abstractmethod
    def fetch_quota(self) -> Dict[str, Any]:
        """获取当前节点真实配额数据"""
        pass

    @abstractmethod
    def is_engine_alive(self) -> bool:
        """检查底层 Agent 引擎状态"""
        pass


class WindowsPlatformAdapter(BasePlatformAdapter):
    def __init__(self, config: Optional[Dict[str, Any]] = None):
        super().__init__("windows", config)
        self._brain_dir = os.path.expanduser(r"~\.gemini\antigravity\brain")
        self._db_path = os.path.expanduser(r"~\.gemini\antigravity\conversation_summaries.db")
        self._default_workspace = os.path.expanduser(r"~\.gemini\antigravity\scratch")
        self._daemon_dir = os.path.expanduser(r"~\.gemini\antigravity\daemon")
        self._ls_exe = os.path.expanduser(r"~\AppData\Local\Programs\antigravity\resources\bin\language_server.exe")

    @property
    def brain_dir(self) -> str:
        return self._brain_dir

    @property
    def db_path(self) -> str:
        return self._db_path

    @property
    def default_workspace(self) -> str:
        return self._default_workspace

    def _get_active_hub_info(self) -> Optional[Dict[str, Any]]:
        """从 daemon/hub_*.json 获取活跃 Connect-RPC 端口和 csrf_token"""
        daemon_pattern = os.path.join(self._daemon_dir, "hub_*.json")
        files = glob.glob(daemon_pattern)
        if not files:
            return None
        files.sort(key=lambda x: os.path.getmtime(x), reverse=True)
        for f in files:
            try:
                with open(f, "r", encoding="utf-8") as fp:
                    data = json.load(fp)
                    port = data.get("httpPort") or data.get("port")
                    csrf = data.get("csrfToken") or data.get("csrf_token")
                    if port and csrf:
                        return {"port": port, "csrf_token": csrf, "pid": data.get("pid")}
            except Exception:
                continue
        return None

    def is_engine_alive(self) -> bool:
        """检查 Windows 本地 Antigravity 宿主引擎及 RPC 端口是否存活"""
        info = self._get_active_hub_info()
        if not info:
            return False
        port = info.get("port")
        if not port:
            return False
        try:
            import socket
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except Exception:
            return False

    def dispatch_agent_message(self, session_id: Optional[str], content: str, model: Optional[str] = None, workspace_dir: Optional[str] = None) -> Tuple[bool, str]:
        """
        Windows 优先通过 LanguageServerService/SendUserCascadeMessage 发送原生真实用户消息！
        消除突兀胶囊，与在 IDE 输入框亲手敲击回车完全一致。
        若 RPC 失败，自动降级为官方 agentapi send-message。
        """
        info = self._get_active_hub_info()
        if info:
            port = info.get("port")
            csrf_token = info.get("csrf_token")
            if port and csrf_token:
                payload = {
                    "cascadeId": session_id or "",
                    "messageText": content,
                    "items": [{"text": content}]
                }
                req_data = json.dumps(payload).encode("utf-8")
                req = urllib.request.Request(
                    f"http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/SendUserCascadeMessage",
                    data=req_data,
                    headers={
                        "Content-Type": "application/json",
                        "x-codeium-csrf-token": csrf_token
                    }
                )
                try:
                    with urllib.request.urlopen(req, timeout=5) as response:
                        if response.status == 200:
                            return True, "Windows 原生 RPC 消息发送成功"
                except Exception as e:
                    logging.warning(f"[-] SendUserCascadeMessage 异常: {e}，准备降级为 agentapi")

        # 降级：使用 language_server.exe agentapi send-message
        if session_id and os.path.exists(self._ls_exe):
            cmd = [self._ls_exe, "agentapi", "send-message", "--title=AGY Web", session_id, content]
            try:
                res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=8)
                if res.returncode == 0:
                    return True, "Windows agentapi 发送成功"
                else:
                    return False, res.stderr.strip() or res.stdout.strip()
            except Exception as e:
                return False, f"调用 agentapi 异常: {e}"

        return False, "发送失败：未找到活跃的 Antigravity 引擎"

    def dispatch_new_session(self, content: str, model: Optional[str] = None, workspace_dir: Optional[str] = None) -> Tuple[bool, str, str]:
        """
        Windows: 调用 agentapi new-conversation 开启新会话
        返回 (ok, new_conversation_id, message)
        """
        if not os.path.exists(self._ls_exe):
            return False, "", "未找到 language_server.exe"

        raw_model = (model or "gemini-3.8-flash-high").strip().lower()
        if raw_model == "sonnet":
            model_flag = "claude-sonnet-4-6"
        elif raw_model == "pro":
            model_flag = "gemini-2.5-pro"
        elif raw_model == "flash":
            model_flag = "gemini-3.8-flash-high"
        else:
            model_flag = raw_model

        cmd = [self._ls_exe, "agentapi", "new-conversation", f"--model={model_flag}", content]
        target_cwd = workspace_dir if (workspace_dir and os.path.exists(workspace_dir)) else self.default_workspace
        logging.info(f"[*] Windows 启动新会话: cmd={' '.join(cmd)}, cwd={target_cwd}")
        try:
            res = subprocess.run(cmd, cwd=target_cwd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=12)
            out = res.stdout.strip()
            new_cid = ""
            if res.returncode == 0:
                try:
                    parsed = json.loads(out)
                    new_cid = parsed.get("response", {}).get("newConversation", {}).get("conversationId", "")
                except Exception:
                    pass
                return True, new_cid, "新会话创建成功"
            else:
                return False, "", res.stderr.strip() or res.stdout.strip() or "创建新会话失败"
        except Exception as e:
            return False, "", f"创建新会话异常: {e}"

    def fetch_quota(self) -> Dict[str, Any]:
        """通过 Connect-RPC LanguageServerService/RetrieveUserQuotaSummary 获取配额"""
        info = self._get_active_hub_info()
        if not info:
            return {"groups": [], "description": "Antigravity LanguageServer 未运行"}
        port = info.get("port")
        csrf_token = info.get("csrf_token")
        if not port or not csrf_token:
            return {"groups": [], "description": "daemon 配置无效"}
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
                data=b"{}",
                headers={
                    "Content-Type": "application/json",
                    "x-codeium-csrf-token": csrf_token
                }
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                data = json.loads(response.read().decode("utf-8"))
                groups = data.get("response", {}).get("groups", [])
                if not groups:
                    groups = data.get("userStatus", {}).get("cascadeModelQuotaStatus", {}).get("groups", [])
                return {"groups": groups, "description": "Windows Antigravity 原生官方配额"}
        except Exception as e:
            return {"groups": [], "description": f"获取 Windows 配额失败: {e}"}


class DeckPlatformAdapter(BasePlatformAdapter):
    def __init__(self, config: Optional[Dict[str, Any]] = None):
        super().__init__("deck", config)
        self._brain_dir = os.path.expanduser("~/.gemini/antigravity-cli/brain")
        self._db_path = os.path.expanduser("~/.gemini/antigravity-cli/conversation_summaries.db")
        self._default_workspace = os.path.expanduser("~/")
        self._agy_bin = "/home/deck/.local/bin/agy"
        if not os.path.exists(self._agy_bin):
            self._agy_bin = shutil.which("agy") or os.path.expanduser("~/.local/bin/agy")

    @property
    def brain_dir(self) -> str:
        return self._brain_dir

    @property
    def db_path(self) -> str:
        return self._db_path

    @property
    def default_workspace(self) -> str:
        return self._default_workspace

    def is_engine_alive(self) -> bool:
        """Deck 属于按需 CLI 调用，直接返回 CLI 二进制是否存在"""
        return os.path.exists(self._agy_bin)

    def dispatch_agent_message(self, session_id: Optional[str], content: str, model: Optional[str] = None, workspace_dir: Optional[str] = None) -> Tuple[bool, str]:
        """
        Steam Deck: 通过原生 agy CLI 异步子进程拉起任务
        """
        if not os.path.exists(self._agy_bin):
            return False, f"未找到 agy CLI 路径: {self._agy_bin}"

        cmd = [self._agy_bin]
        if session_id:
            cmd.append(f"--conversation={session_id}")
        cmd.extend(["-p", content, "--mode=auto", "--dangerously-skip-permissions"])
        if model:
            cmd.append(f"--model={model}")

        target_cwd = workspace_dir if (workspace_dir and os.path.exists(workspace_dir)) else self.default_workspace

        logging.info(f"[*] Steam Deck 异步启动 Agent 任务: cmd={' '.join(cmd)}, cwd={target_cwd}")
        try:
            subprocess.Popen(
                cmd,
                cwd=target_cwd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True
            )
            return True, "Deck 原生 CLI 任务已异步启动"
        except Exception as e:
            return False, f"Deck 启动任务异常: {e}"

    def dispatch_new_session(self, content: str, model: Optional[str] = None, workspace_dir: Optional[str] = None) -> Tuple[bool, str, str]:
        """
        Steam Deck: 异步通过原生 agy CLI 开启全新任务
        """
        if not os.path.exists(self._agy_bin):
            return False, "", f"未找到 agy CLI 路径: {self._agy_bin}"

        cmd = [self._agy_bin, "-p", content, "--mode=auto", "--dangerously-skip-permissions"]
        if model:
            cmd.append(f"--model={model}")

        target_cwd = workspace_dir if (workspace_dir and os.path.exists(workspace_dir)) else self.default_workspace
        logging.info(f"[*] Steam Deck 异步启动新会话: cmd={' '.join(cmd)}, cwd={target_cwd}")
        try:
            subprocess.Popen(
                cmd,
                cwd=target_cwd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True
            )
            return True, "", "Deck 原生 CLI 新会话已异步启动"
        except Exception as e:
            return False, "", f"Deck 启动新会话异常: {e}"

    def fetch_quota(self) -> Dict[str, Any]:
        """
        Steam Deck: 穿透 Keyring 抓取原生 /quota TSV 并解析
        带 300 秒轻量缓存，防止高频调用
        """
        if self.cached_quota and (time.time() - self.last_quota_sync < 300):
            return self.cached_quota

        output = ""
        # 1. 优先尝试 systemd-run --user --pipe（穿透 D-Bus Session 访问 GNOME Keyring）
        try:
            proc = subprocess.run(
                ["systemd-run", "--user", "--pipe", self._agy_bin, "-p", "/quota"],
                capture_output=True,
                text=True,
                timeout=15
            )
            output = proc.stdout.strip()
        except Exception:
            pass

        # 2. 降级直接调用 agy -p /quota
        if not output:
            try:
                proc = subprocess.run(
                    [self._agy_bin, "-p", "/quota"],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                output = proc.stdout.strip() or proc.stderr.strip()
            except Exception as e:
                logging.error(f"Deck 原生 /quota 调用异常: {e}")

        groups = self._parse_cli_quota_output(output)
        if groups:
            self.cached_quota = {"groups": groups, "description": "Steam Deck 本地 CLI 原生配额"}
            self.last_quota_sync = time.time()
            return self.cached_quota

        return self.cached_quota or {"groups": [], "description": "未获取到 Deck 配额"}

    @staticmethod
    def _parse_cli_quota_output(raw_text: str) -> List[Dict[str, Any]]:
        """解析 agy -p /quota 返回的制表符分割 TSV 格式"""
        groups_dict: Dict[str, Dict[str, Any]] = {}
        import re
        for line in raw_text.splitlines():
            line = line.strip()
            if not line or "Running as unit:" in line:
                continue
            parts = [p.strip() for p in line.split('\t') if p.strip()]
            if len(parts) < 3:
                parts = re.split(r'\s{2,}', line)
            if len(parts) >= 3:
                group_name = parts[0]
                bucket_name = parts[1]
                percent_str = parts[2]
                reset_time = parts[3] if len(parts) > 3 else ""

                frac = 0.0
                disabled = False
                if "%" in percent_str:
                    try:
                        frac = float(percent_str.replace("%", "").strip()) / 100.0
                    except Exception:
                        pass
                elif "disabled" in percent_str.lower():
                    disabled = True
                    frac = 1.0

                if group_name not in groups_dict:
                    groups_dict[group_name] = {
                        "displayName": group_name,
                        "description": f"Models within {group_name}",
                        "buckets": []
                    }

                is_weekly = "weekly" in bucket_name.lower()
                groups_dict[group_name]["buckets"].append({
                    "bucketId": "weekly" if is_weekly else "5h",
                    "displayName": bucket_name,
                    "description": f"{group_name} {bucket_name}",
                    "window": "weekly" if is_weekly else "5h",
                    "remainingFraction": frac,
                    "disabled": disabled,
                    "resetTime": reset_time
                })
        return list(groups_dict.values())


def get_platform_adapter(platform_override: Optional[str] = None, config: Optional[Dict[str, Any]] = None) -> BasePlatformAdapter:
    """根据操作系统或覆盖参数自动构建对应的平台适配器"""
    target = platform_override or os.environ.get("AGY_PLATFORM")
    if not target:
        target = "windows" if sys.platform == "win32" else "deck"
    target = target.lower()

    if target in ("deck", "linux"):
        return DeckPlatformAdapter(config)
    else:
        return WindowsPlatformAdapter(config)
