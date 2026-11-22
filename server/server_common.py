import os
import re
import json
import urllib.parse
from typing import Tuple, Optional, List, Dict, Any

# 忽略透传给前端的无用内部系统消息类型
IGNORED_MSG_TYPES = {
    "GENERIC",
    "SYSTEM_MESSAGE",
    "CHECKPOINT",
    "STATUS_UPDATE",
    "TASK_NOTIFICATION",
    "USER_APPROVAL_RESPONSE"
}

# 敏感文件/凭据黑名单正则（杜绝任何形式的密钥与核心配置泄露）
SENSITIVE_PATTERNS = [
    r"[\\/]\.ssh([\\/]|$)",
    r"[\\/]\.gnupg([\\/]|$)",
    r"[\\/]\.aws([\\/]|$)",
    r"[\\/]\.git([\\/]|$)",
    r"[\\/]id_rsa([\\.]|$)",
    r"[\\/]id_ed25519([\\.]|$)",
    r"[\\/]known_hosts",
    r"[\\/]authorized_keys",
    r"[\\/]\.env([\\.]|$)",
    r"[\\/]server_config\.json$",
    r"[\\/]etc[\\/]shadow",
    r"[\\/]etc[\\/]passwd",
    r"[\\/]Windows[\\/]System32[\\/]config"
]

def is_path_safe(
    target_path: str,
    dynamic_workspace: Optional[str] = None,
    allowed_roots: Optional[List[str]] = None,
    extra_dirs: Optional[List[str]] = None
) -> Tuple[bool, str]:
    """
    通用路径安全验证：
    1. 解析规范化真实路径（解析 symlink 与相对路径）；
    2. 黑名单正则拦截敏感私钥与凭证；
    3. 白名单校验：必须落在允许的根目录或当前工作区内。
    """
    if not target_path:
        return False, "Empty path"
    try:
        real_target = os.path.realpath(os.path.abspath(target_path))

        # 1. 黑名单阻断
        for pat in SENSITIVE_PATTERNS:
            if re.search(pat, real_target, re.IGNORECASE):
                return False, "Access to sensitive credentials or configuration is forbidden"

        # 2. 收集白名单
        roots: List[str] = []
        if allowed_roots:
            roots.extend([os.path.realpath(os.path.abspath(r)) for r in allowed_roots if r])
        if dynamic_workspace and os.path.exists(dynamic_workspace):
            roots.append(os.path.realpath(os.path.abspath(dynamic_workspace)))
        if extra_dirs:
            roots.extend([os.path.realpath(os.path.abspath(d)) for d in extra_dirs if d and os.path.exists(d)])

        is_allowed = False
        for r in roots:
            if real_target == r or real_target.startswith(r + os.sep):
                is_allowed = True
                break

        if not is_allowed:
            return False, "Path is outside allowed directories"

        return True, real_target
    except Exception as e:
        return False, str(e)

def build_cors_headers(request: Any, allowed_origins: List[str], base_headers: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """
    基于客户端请求的 Origin 安全构建 CORS 头，杜绝无脑全通配
    """
    headers = dict(base_headers or {})
    origin = request.headers.get("Origin")
    if not origin:
        return headers
    if "*" in allowed_origins:
        headers["Access-Control-Allow-Origin"] = origin
        headers["Access-Control-Allow-Credentials"] = "true"
    elif origin in allowed_origins:
        headers["Access-Control-Allow-Origin"] = origin
        headers["Access-Control-Allow-Credentials"] = "true"
    return headers

def clean_display_content(raw_text: str) -> str:
    """
    清洗 Agent 底层原始日志与系统指令，提取用户真正关心的高可读性对话文本
    """
    if not raw_text:
        return ""
    user_match = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", raw_text, re.DOTALL)
    if user_match:
        return user_match.group(1).strip()
    cleaned = re.sub(r"<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>", "", raw_text, flags=re.DOTALL)
    cleaned = re.sub(r"<SYSTEM_MESSAGE>.*?</SYSTEM_MESSAGE>", "", cleaned, flags=re.DOTALL)
    cleaned = re.sub(r"<INSTRUCTIONS>.*?</INSTRUCTIONS>", "", cleaned, flags=re.DOTALL)

    # 拦截系统注入与控制台爆日志
    if "The following is a" in cleaned or "<SYSTEM_MESSAGE>" in cleaned or "YOU MUST TAKE ONE OF THE FOLLOWING TWO ACTIONS" in cleaned:
        return ""

    stripped = cleaned.strip()
    if stripped.startswith("Created At: 202") and (
        "Command output:" in stripped
        or "Command exited with code" in stripped
        or "Tool is running as a background task" in stripped
        or "cancelled" in stripped
        or "Task Description:" in stripped
        or "Log output:" in stripped
    ):
        return ""

    return stripped

def parse_project_name_and_path(ws_uris: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    """
    解析 Antigravity 数据库存储的 workspace_uris JSON 字段，提取工程展示名与本地路径
    """
    if not ws_uris or ws_uris.strip() in ("", "[]"):
        return None, None
    try:
        uris = json.loads(ws_uris)
        if isinstance(uris, list) and uris:
            raw_uri = uris[0]
            decoded = urllib.parse.unquote(raw_uri)
            if decoded.startswith("file:///"):
                local_path = decoded.replace("file:///", "").replace("/", "\\") if os.name == 'nt' else decoded.replace("file://", "")
                if os.name == 'nt' and len(local_path) > 1 and local_path[1] == ':':
                    pass
                else:
                    local_path = decoded.replace("file://", "")
                clean_path = local_path.rstrip("\\/")
                # 修复 Windows 盘符根目录 (如 Z: 或 Z:\) 解析为项目名
                if len(clean_path) == 2 and clean_path[1] == ':':
                    return clean_path, local_path
                folder_name = os.path.basename(clean_path)
                if not folder_name:
                    folder_name = clean_path
                return folder_name, local_path
            elif decoded.startswith("file://"):
                local_path = decoded.replace("file://", "")
                clean_path = local_path.rstrip("/")
                folder_name = os.path.basename(clean_path)
                return folder_name, local_path
    except Exception:
        pass
    return None, None

def list_workspace_files(base_dir: str, sub_path: str = "") -> Dict[str, Any]:
    """
    安全列出工作区目录结构并按文件夹优先排序
    """
    target_dir = os.path.join(base_dir, sub_path) if sub_path else base_dir
    target_dir = os.path.abspath(target_dir)
    items = []
    if not os.path.exists(target_dir) or not os.path.isdir(target_dir):
        return {"current_path": sub_path.replace("\\", "/"), "items": []}

    try:
        for entry in os.scandir(target_dir):
            if entry.name.startswith(".") and entry.name not in (".env.example", ".gitignore"):
                continue
            if entry.name in ("node_modules", "build", ".dart_tool", "__pycache__", "venv", ".venv"):
                continue
            try:
                is_dir = entry.is_dir()
                rel_path = os.path.join(sub_path, entry.name).replace("\\", "/") if sub_path else entry.name
                items.append({
                    "name": entry.name,
                    "is_dir": is_dir,
                    "path": rel_path,
                    "size": 0 if is_dir else entry.stat().st_size
                })
            except Exception:
                pass
        items.sort(key=lambda x: (not x["is_dir"], x["name"].lower()))
    except Exception as e:
        print(f"[-] 列出文件失败: {e}")

    return {"current_path": sub_path.replace("\\", "/"), "items": items[:80]}

def parse_transcript_line(line_str: str) -> Optional[Dict[str, Any]]:
    """
    通用单行 Transcript 日志结构化解析与安全清洗：
    1. 严格过滤系统内部和底层工具命令行原始执行日志类型（IGNORED_MSG_TYPES）；
    2. 深度清洗内容文本（去除各种 prompt 元数据与命令行回显大黑框）；
    3. 安全提取 tool_calls 和 thinking，消除前端空白无用消息。
    """
    if not line_str or not line_str.strip():
        return None
    try:
        data = json.loads(line_str)
        source = data.get("source", "")
        step_type = data.get("type", "")

        # 1. 严格过滤系统内部和底层工具命令行原始执行日志类型
        if step_type in IGNORED_MSG_TYPES:
            return None

        status = data.get("status", "")
        thinking = data.get("thinking", "")
        raw_content = data.get("content", "")
        clean_content = clean_display_content(raw_content)
        timestamp = data.get("created_at", "")
        step_index = data.get("step_index", 0)
        tool_calls = data.get("tool_calls", [])

        # 若清洗后无任何有效显示内容且不是用户输入，直接抛弃
        if not clean_content and not thinking and not tool_calls and step_type != "USER_INPUT":
            return None

        clean_calls = []
        if isinstance(tool_calls, list):
            for tc in tool_calls:
                fn = tc.get("function", {})
                clean_calls.append({
                    "name": fn.get("name", "tool"),
                    "arguments": fn.get("arguments", {})
                })

        return {
            "step_index": step_index,
            "source": source,
            "msg_type": step_type,
            "status": status,
            "content": clean_content,
            "thinking": thinking,
            "tool_calls": clean_calls,
            "timestamp": timestamp
        }
    except Exception:
        return None

