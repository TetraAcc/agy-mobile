import os
import sys
import json
import time
import glob
import re
import sqlite3
import subprocess
import urllib.parse
import asyncio
import base64
from aiohttp import web, WSMsgType
from server_common import (
    IGNORED_MSG_TYPES,
    SENSITIVE_PATTERNS,
    is_path_safe as common_is_path_safe,
    build_cors_headers as common_build_cors_headers,
    clean_display_content,
    parse_project_name_and_path,
    list_workspace_files
)

BRAIN_DIR = os.path.expanduser(r"~\.gemini\antigravity\brain")
DB_PATH = os.path.expanduser(r"~\.gemini\antigravity\conversation_summaries.db")
AGENT_API_PATH = os.path.expanduser(r"~\.gemini\antigravity\bin\agentapi.bat")
LANGUAGE_SERVER_EXE = os.path.expanduser(r"~\AppData\Local\Programs\antigravity\resources\bin\language_server.exe")
FLUTTER_WEB_DIR = os.path.expanduser(r"~\.gemini\antigravity\scratch\agy_mobile_app\build\web")

# ==========================================
# 🛡️ 外部配置文件加载与安全参数化
# ==========================================
CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "server_config.json")
def load_windows_config():
    cfg = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
                cfg = data.get("windows", data)
        except Exception as e:
            print(f"[-] 加载 server_config.json 异常: {e}")
    return cfg

WIN_CONFIG = load_windows_config()
PORT = int(WIN_CONFIG.get("port") or os.environ.get("AGY_PORT", 8765))
AUTH_TOKEN = WIN_CONFIG.get("auth_token") or os.environ.get("AGY_AUTH_TOKEN", "change_me_to_your_token")
ALLOWED_ORIGINS = WIN_CONFIG.get("allowed_origins", ["*"])

# 允许访问的目录白名单（默认只允许 brain 目录和 scratch 目录）
raw_roots = WIN_CONFIG.get("allowed_roots", [
    r"~\.gemini\antigravity\brain",
    r"~\.gemini\antigravity\scratch"
])
ALLOWED_ROOTS = [os.path.realpath(os.path.expanduser(r)) for r in raw_roots]

def is_path_safe(target_path, dynamic_workspace=None):
    return common_is_path_safe(
        target_path,
        dynamic_workspace=dynamic_workspace,
        allowed_roots=ALLOWED_ROOTS,
        extra_dirs=[FLUTTER_WEB_DIR]
    )

def build_cors_headers(request, base_headers=None):
    return common_build_cors_headers(request, allowed_origins=ALLOWED_ORIGINS, base_headers=base_headers)

connected_ws_clients = set()
current_active_session_id = None
current_active_file = None
current_workspace_dir = None
file_handle = None
is_current_session_running = False
last_log_active_time = time.time()

def get_grouped_sessions():
    if not os.path.exists(DB_PATH):
        return {"projects": {}, "general_sessions": []}
    try:
        conn = sqlite3.connect(DB_PATH)
        cur = conn.cursor()
        query = """
            SELECT conversation_id, title, preview, last_modified_time, workspace_uris, project_id
            FROM conversation_summaries
            WHERE parent_conversation_id = '' OR parent_conversation_id IS NULL
            ORDER BY last_modified_time DESC
            LIMIT 50
        """
        rows = cur.execute(query).fetchall()
        conn.close()

        projects_map = {}
        general_sessions = []

        for r in rows:
            cid, title, preview, mtime, ws_uris, pid = r
            display_title = title.strip() if title and title.strip() else (preview.strip() if preview else "未命名会话")
            if len(display_title) > 28:
                display_title = display_title[:28] + "..."

            proj_name, ws_path = parse_project_name_and_path(ws_uris)
            item = {
                "id": cid,
                "title": display_title,
                "time": mtime.split(" ")[0] if mtime else "",
                "is_active": (cid == current_active_session_id),
                "workspace_path": ws_path or ""
            }

            if proj_name:
                if proj_name not in projects_map:
                    projects_map[proj_name] = []
                projects_map[proj_name].append(item)
            else:
                general_sessions.append(item)

        return {
            "projects": projects_map,
            "general_sessions": general_sessions
        }
    except Exception as e:
        print(f"[-] 读取会话树失败: {e}")
        return {"projects": {}, "general_sessions": []}

def get_latest_transcript_path():
    pattern = os.path.join(BRAIN_DIR, "*", ".system_generated", "logs", "transcript.jsonl")
    files = glob.glob(pattern)
    if not files:
        return None
    files.sort(key=lambda x: os.path.getmtime(x), reverse=True)
    return files[0]

def stop_cascade_invocation(session_id):
    if not session_id:
        return False, "缺少 session_id"
    daemon_pattern = os.path.join(os.path.expanduser(r"~\.gemini\antigravity\daemon"), "hub_*.json")
    files = glob.glob(daemon_pattern)
    if not files:
        return False, "未找到 language_server daemon 配置文件"
    files.sort(key=lambda x: os.path.getmtime(x), reverse=True)
    latest_hub = files[0]

    try:
        with open(latest_hub, "r", encoding="utf-8") as f:
            hub = json.load(f)
        port = hub.get("httpPort")
        csrf_token = hub.get("csrfToken")
        if not port or not csrf_token:
            return False, "daemon 配置不完整"

        headers = {
            "x-codeium-csrf-token": csrf_token,
            "Content-Type": "application/json"
        }

        # 1. 调用 CancelCascadeInvocation 打断当前生成并杀后台任务
        try:
            url_cancel = f"http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/CancelCascadeInvocation"
            payload = json.dumps({"cascadeId": session_id, "killBackgroundTasks": True}).encode()
            req = urllib.request.Request(url_cancel, data=payload, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=3) as resp:
                print(f"[+] CancelCascadeInvocation 成功打断底层生成: {session_id}")
        except Exception as e:
            print(f"[-] CancelCascadeInvocation 调用提示: {e}")

        # 2. 调用 ForceStopCascadeTree 停止树
        try:
            url_force = f"http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/ForceStopCascadeTree"
            payload = json.dumps({"conversationId": session_id}).encode()
            req = urllib.request.Request(url_force, data=payload, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=3) as resp:
                print(f"[+] ForceStopCascadeTree 成功强制停止会话树: {session_id}")
        except Exception as e:
            print(f"[-] ForceStopCascadeTree 调用提示: {e}")

        return True, "ok"
    except Exception as e:
        print(f"[-] stop_cascade_invocation 异常: {e}")
        return False, str(e)

def send_native_user_message(target_id, content):
    """
    通过 LanguageServerService/SendUserCascadeMessage 发送原生真实用户消息！
    彻底消除 IDE 界面上难看且突兀的【来自 self 的消息 ∨】浅蓝色胶囊，
    直接以原生 USER_REQUEST 呈现，与在 IDE 输入框亲手敲击回车完全一致！
    """
    try:
        daemon_pattern = os.path.join(os.path.expanduser(r"~\.gemini\antigravity\daemon"), "hub_*.json")
        files = glob.glob(daemon_pattern)
        if not files:
            return False, "未找到 daemon 配置文件"
        files.sort(key=lambda x: os.path.getmtime(x), reverse=True)
        latest_hub = files[0]

        with open(latest_hub, "r", encoding="utf-8") as f:
            hub = json.load(f)
        port = hub.get("httpPort")
        csrf_token = hub.get("csrfToken")
        if not port or not csrf_token:
            return False, "daemon 配置缺少端口或 token"

        url = f"http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/SendUserCascadeMessage"
        headers = {
            "x-codeium-csrf-token": csrf_token,
            "Content-Type": "application/json"
        }
        payload = {
            "cascadeId": target_id,
            "messageText": content,
            "items": [
                {"text": content}
            ]
        }
        req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status == 200:
                print(f"[+] SendUserCascadeMessage 成功发送原生用户消息: {target_id}")
                return True, "ok"
            else:
                return False, f"status {resp.status}"
    except Exception as e:
        print(f"[-] SendUserCascadeMessage 异常: {e}，准备降级为 agentapi")
        return False, str(e)

def get_user_quota_summary():
    """
    通过底层 Connect-RPC LanguageServerService/RetrieveUserQuotaSummary
    获取官方模型真实配额信息（Gemini 及 3P 模型的周额度和 5 小时滑动额度）
    """
    try:
        daemon_pattern = os.path.join(os.path.expanduser(r"~\.gemini\antigravity\daemon"), "hub_*.json")
        hub_files = glob.glob(daemon_pattern)
        if not hub_files:
            return None, "未找到 hub 配置文件"
        hub_files.sort(key=lambda x: os.path.getmtime(x), reverse=True)
        with open(hub_files[0], "r", encoding="utf-8") as f:
            hub = json.load(f)
        port = hub.get("httpPort")
        csrf_token = hub.get("csrfToken")
        if not port or not csrf_token:
            return None, "daemon 配置缺少端口或 token"

        url = f"http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
        headers = {
            "x-codeium-csrf-token": csrf_token,
            "Content-Type": "application/json"
        }
        req = urllib.request.Request(url, data=b"{}", headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=4) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8"))
                return data.get("response") or data, None
            else:
                return None, f"HTTP status {resp.status}"
    except Exception as e:
        return None, str(e)

def dispatch_agent_message(session_id, content):
    global current_active_session_id
    target_id = session_id or current_active_session_id
    if not target_id:
        latest = get_latest_transcript_path()
        if latest:
            target_id = latest.split(os.sep)[-4]
            current_active_session_id = target_id
    if not target_id:
        return False, "未找到目标会话 ID"

    # 1. 优先调用底层 RPC 注入 100% 原生用户消息（绝无“来自 self 的消息 ∨”丑陋胶囊）
    ok, err = send_native_user_message(target_id, content)
    if ok:
        return True, "ok"

    # 2. 降级方案：调用官方 agentapi
    print(f"[*] 降级使用 agentapi send-message: {err}")
    title_arg = "--title=AGY Remote 网页端"
    cmd = []
    if os.path.exists(LANGUAGE_SERVER_EXE):
        cmd = [LANGUAGE_SERVER_EXE, "agentapi", "send-message", title_arg, target_id, content]
    elif os.path.exists(AGENT_API_PATH):
        cmd = [AGENT_API_PATH, "send-message", title_arg, target_id, content]
    else:
        return False, "未找到 agentapi 可执行程序"

    try:
        res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=8)
        if res.returncode == 0:
            return True, "ok"
        else:
            err = res.stderr.strip() or res.stdout.strip() or f"exit code {res.returncode}"
            return False, err
    except Exception as e:
        return False, str(e)
async def broadcast_message(message_dict):
    if not connected_ws_clients:
        return
    payload = json.dumps(message_dict, ensure_ascii=False)
    for ws in list(connected_ws_clients):
        try:
            if not ws.closed:
                await ws.send_str(payload)
        except Exception:
            pass

def load_session_history(session_file, max_lines=300):
    if not os.path.exists(session_file):
        return []
    history = []
    try:
        with open(session_file, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
            scan_lines = lines[-max_lines:] if len(lines) > max_lines else lines
            for line in scan_lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                    msg_type = record.get("type", "")
                    if msg_type in IGNORED_MSG_TYPES:
                        continue
                    
                    raw_content = record.get("content", "")
                    clean_content = clean_display_content(raw_content)
                    thinking = record.get("thinking", "")
                    tool_calls = record.get("tool_calls", [])

                    if not clean_content and not thinking and not tool_calls:
                        continue

                    history.append({
                        "step_index": record.get("step_index", 0),
                        "source": record.get("source", "AGENT"),
                        "msg_type": msg_type,
                        "status": record.get("status", ""),
                        "content": clean_content,
                        "thinking": thinking,
                        "tool_calls": tool_calls,
                        "timestamp": record.get("created_at", "")
                    })
                except Exception:
                    pass
    except Exception as e:
        print(f"[-] 加载历史失败: {e}")
    return history[-60:]

async def tail_transcript():
    global current_active_file, file_handle, current_active_session_id, is_current_session_running, last_log_active_time

    print("[*] 日志监听常驻协程已就绪...")
    while True:
        try:
            if not current_active_file:
                latest = get_latest_transcript_path()
                if latest:
                    current_active_file = latest
                    current_active_session_id = latest.split(os.sep)[-4]
                    print(f"[+] 锁定活跃会话: {current_active_session_id}")
                    file_handle = open(current_active_file, "r", encoding="utf-8", errors="replace")
                    file_handle.seek(0, os.SEEK_END)
                    is_current_session_running = False
                    last_log_active_time = time.time()

            if file_handle:
                line = file_handle.readline()
                if line:
                    line = line.strip()
                    if line:
                        last_log_active_time = time.time()
                        try:
                            record = json.loads(line)
                            msg_type = record.get("type", "UNKNOWN")
                            if msg_type in IGNORED_MSG_TYPES:
                                continue

                            raw_content = record.get("content", "")
                            clean_content = clean_display_content(raw_content)
                            thinking = record.get("thinking", "")
                            tool_calls = record.get("tool_calls", [])

                            if not clean_content and not thinking and not tool_calls:
                                continue

                            src = record.get("source", "")
                            st = record.get("status", "")
                            is_user = (src == "USER_EXPLICIT" or msg_type == "USER_INPUT")
                            # 判定状态：用户发问或未完成态标记为运行中；DONE 或 ERROR 标记为空闲
                            is_running = is_user or (st != "DONE" and st != "ERROR")
                            is_current_session_running = is_running

                            event = {
                                "type": "agent_update",
                                "session_id": current_active_session_id,
                                "step_index": record.get("step_index"),
                                "source": src,
                                "msg_type": msg_type,
                                "status": st,
                                "content": clean_content,
                                "thinking": thinking,
                                "tool_calls": tool_calls,
                                "timestamp": record.get("created_at"),
                                "is_running": is_running
                            }
                            await broadcast_message(event)
                            await broadcast_message({
                                "type": "status_change",
                                "session_id": current_active_session_id,
                                "is_running": is_running
                            })
                            print(f"[Push] step={event['step_index']} type={event['msg_type']} is_running={is_running}")
                        except Exception as e:
                            print(f"[-] JSON 解析异常: {e}")
                else:
                    # 静默超时自动复位：若超过 2.5 秒没有新的日志产生，自动归位为空闲
                    if is_current_session_running and (time.time() - last_log_active_time > 2.5):
                        is_current_session_running = False
                        await broadcast_message({
                            "type": "status_change",
                            "session_id": current_active_session_id,
                            "is_running": False
                        })
                        print(f"[*] 会话 {current_active_session_id} 静默超时 2.5s，自动归位为空闲")
                    await asyncio.sleep(0.3)
            else:
                await asyncio.sleep(1)

        except Exception as e:
            await asyncio.sleep(1)

async def websocket_handler(request):
    global current_active_file, file_handle, current_active_session_id, current_workspace_dir, is_current_session_running, last_log_active_time

    # 访问口令（Token）安全校验
    client_token = request.query.get("token", "").strip()
    if AUTH_TOKEN and client_token != AUTH_TOKEN:
        remote_ip = request.remote or "unknown"
        print(f"[-] 阻断未授权连接: IP={remote_ip}, token='{client_token}'")
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        await ws.send_json({"type": "auth_error", "msg": "未授权：访问口令 (Token) 错误或缺失"})
        await ws.close(code=4401, message=b"Unauthorized")
        return ws

    ws = web.WebSocketResponse(heartbeat=25)
    await ws.prepare(request)
    connected_ws_clients.add(ws)
    remote = request.remote or "unknown"
    print(f"\n[+] 客户端接入 WebSocket: {remote}")

    try:
        # 0. 保证立即锁定最新会话，避免初次连接时出现空白
        try:
            if not current_active_file or not os.path.exists(current_active_file):
                latest = get_latest_transcript_path()
                if latest:
                    current_active_file = latest
                    current_active_session_id = latest.split(os.sep)[-4]
                    if file_handle:
                        try:
                            file_handle.close()
                        except Exception:
                            pass
                    file_handle = open(current_active_file, "r", encoding="utf-8", errors="replace")
                    file_handle.seek(0, os.SEEK_END)
        except Exception as e:
            print(f"[-] 初始化活跃会话失败: {e}")

        # 1. 握手确认
        try:
            await ws.send_json({
                "type": "connected",
                "active_session": current_active_session_id,
                "msg": "Connected to AGY Remote Single-Port Hub!"
            })
        except Exception as e:
            print(f"[-] 握手推送失败: {e}")

        # 1.5 双机节点在线状态推送
        try:
            await ws.send_json({
                "type": "nodes_status",
                "nodes": [
                    {"id": "deck", "name": "Steam Deck", "online": True},
                    {"id": "windows", "name": "Windows PC", "online": True}
                ]
            })
        except Exception as e:
            print(f"[-] 节点状态推送失败: {e}")

        # 2. 会话树
        try:
            data_tree = get_grouped_sessions()
            await ws.send_json({
                "type": "session_tree",
                "projects": data_tree.get("projects", {}),
                "general_sessions": data_tree.get("general_sessions", []),
                "current": current_active_session_id
            })

            for list_s in data_tree.get("projects", {}).values():
                for s in list_s:
                    if s.get("id") == current_active_session_id and s.get("workspace_path"):
                        current_workspace_dir = s["workspace_path"]
                        break
        except Exception as e:
            print(f"[-] 会话树推送失败: {e}")

        # 3. 历史消息（必定立即推送）
        try:
            if current_active_file and os.path.exists(current_active_file):
                history = load_session_history(current_active_file, max_lines=40)
                file_mtime = os.path.getmtime(current_active_file)
                real_running = bool(is_current_session_running and (time.time() - file_mtime < 2.5))
                await ws.send_json({
                    "type": "session_history",
                    "session_id": current_active_session_id,
                    "history": history,
                    "is_running": real_running
                })
        except Exception as e:
            print(f"[-] 历史记录推送失败: {e}")

        # 4. 实时额度初始推送
        try:
            init_quota, _ = await asyncio.to_thread(get_user_quota_summary)
            if init_quota:
                await ws.send_json({
                    "type": "quota_update",
                    "quota": init_quota
                })
        except Exception as e:
            pass

        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                try:
                    data = json.loads(msg.data)
                    action = data.get("action")

                    # 心跳响应
                    if action == "ping":
                        await ws.send_json({"type": "pong"})

                    elif action == "get_nodes":
                        await ws.send_json({
                            "type": "nodes_status",
                            "nodes": [
                                {"id": "deck", "name": "Steam Deck", "online": True},
                                {"id": "windows", "name": "Windows PC", "online": True}
                            ]
                        })

                    elif action == "get_quota":
                        quota_data, err = await asyncio.to_thread(get_user_quota_summary)
                        await ws.send_json({
                            "type": "quota_update",
                            "quota": quota_data,
                            "error": err
                        })

                    elif action == "prompt":
                        content = data.get("content", "").strip()
                        target_id = data.get("session_id") or current_active_session_id
                        if content:
                            print(f"[Mobile Send] 向会话 {target_id} 投递指令: {content}")
                            user_event = {
                                "type": "agent_update",
                                "session_id": target_id or "current",
                                "step_index": -1,
                                "source": "USER_EXPLICIT",
                                "msg_type": "USER_INPUT",
                                "status": "SENT",
                                "content": content,
                                "thinking": "",
                                "tool_calls": [],
                                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S")
                            }
                            await broadcast_message(user_event)
                            success, err = await asyncio.to_thread(dispatch_agent_message, target_id, content)
                            await ws.send_json({
                                "type": "prompt_ack",
                                "status": "ok" if success else "error",
                                "content": content,
                                "error": err if not success else ""
                            })

                    elif action == "stop":
                        target_id = data.get("session_id") or current_active_session_id
                        print(f"[*] 收到真实停止指令: 会话 {target_id}")
                        stop_ok, stop_err = await asyncio.to_thread(stop_cascade_invocation, target_id)
                        await broadcast_message({
                            "type": "stopped",
                            "session_id": target_id
                        })
                        await ws.send_json({
                            "type": "stop_ack",
                            "status": "ok" if stop_ok else "error",
                            "session_id": target_id,
                            "error": stop_err if not stop_ok else ""
                        })

                    elif action == "delete_session":
                        del_cid = data.get("session_id")
                        if del_cid:
                            print(f"[*] 收到删除会话请求: {del_cid}")
                            # 1. 数据库删除
                            if os.path.exists(DB_PATH):
                                try:
                                    conn = sqlite3.connect(DB_PATH)
                                    cur = conn.cursor()
                                    cur.execute("DELETE FROM conversation_summaries WHERE conversation_id = ?", (del_cid,))
                                    conn.commit()
                                    conn.close()
                                except Exception as e:
                                    print(f"[-] 数据库删除记录失败: {e}")

                            # 2. 文件系统删除
                            brain_sub = os.path.join(BRAIN_DIR, del_cid)
                            if os.path.exists(brain_sub):
                                try:
                                    import shutil
                                    shutil.rmtree(brain_sub, ignore_errors=True)
                                except Exception:
                                    pass

                            conv_db = os.path.join(os.path.dirname(BRAIN_DIR), "conversations", f"{del_cid}.db")
                            if os.path.exists(conv_db):
                                try:
                                    os.remove(conv_db)
                                except Exception:
                                    pass

                            # 3. 广播最新会话树
                            data_tree = get_grouped_sessions()
                            await broadcast_message({
                                "type": "session_tree",
                                "projects": data_tree["projects"],
                                "general_sessions": data_tree["general_sessions"],
                                "current": current_active_session_id if current_active_session_id != del_cid else ""
                            })

                            await ws.send_json({
                                "type": "delete_ack",
                                "session_id": del_cid,
                                "status": "ok"
                            })

                    elif action == "new_session":
                        content = data.get("content", "你好，请开始新会话").strip()
                        raw_model = data.get("model", "gemini-3.8-flash-high").strip().lower()
                        workspace_path = data.get("workspace_path", "").strip()
                        target_cwd = None
                        if workspace_path and os.path.exists(workspace_path) and os.path.isdir(workspace_path):
                            target_cwd = workspace_path
                            print(f"[*] 开启新会话绑定工作区目录: {target_cwd}")
                        valid_models = {
                            "gemini-3.8-flash-high", "gemini-3.8-flash-medium", "gemini-3.8-flash-low",
                            "claude-sonnet-4-6", "claude-opus-4-6-thinking", "claude-3-7-sonnet", "claude-3-7-opus",
                            "gpt-oss-120b-medium", "gpt-oss-120b", "gemini-2.5-pro", "gemini-3.5-flash-lite",
                            "flash", "pro", "flash_lite", "sonnet"
                        }
                        # 映射兼容旧缩写
                        if raw_model == "sonnet":
                            model = "claude-sonnet-4-6"
                        elif raw_model == "pro":
                            model = "gemini-2.5-pro"
                        elif raw_model == "flash":
                            model = "gemini-3.8-flash-high"
                        elif raw_model in valid_models:
                            model = raw_model
                        else:
                            model = "gemini-3.8-flash-high"
                        print(f"[*] 请求开启新会话: prompt='{content}', model='{model}'")
                        cmd = []
                        if os.path.exists(LANGUAGE_SERVER_EXE):
                            cmd = [LANGUAGE_SERVER_EXE, "agentapi", "new-conversation", f"--model={model}", content]
                        elif os.path.exists(AGENT_API_PATH):
                            cmd = [AGENT_API_PATH, "new-conversation", f"--model={model}", content]
                        if cmd:
                            try:
                                res = subprocess.run(
                                    cmd,
                                    cwd=target_cwd,
                                    capture_output=True,
                                    text=True,
                                    encoding="utf-8",
                                    errors="replace",
                                    timeout=12
                                )
                                out_text = res.stdout.strip()
                                new_cid = ""
                                if res.returncode == 0:
                                    try:
                                        parsed = json.loads(out_text)
                                        new_cid = parsed.get("response", {}).get("newConversation", {}).get("conversationId", "")
                                    except Exception:
                                        pass
                                await ws.send_json({
                                    "type": "new_session_ack",
                                    "status": "ok" if res.returncode == 0 else "error",
                                    "session_id": new_cid,
                                    "error": res.stderr.strip() if res.returncode != 0 else ""
                                })
                                if new_cid:
                                    data_tree = get_grouped_sessions()
                                    await broadcast_message({
                                        "type": "session_tree",
                                        "projects": data_tree["projects"],
                                        "general_sessions": data_tree["general_sessions"],
                                        "current": new_cid
                                    })
                            except Exception as e:
                                await ws.send_json({"type": "new_session_ack", "status": "error", "error": str(e)})

                    elif action == "get_sessions":
                        data_tree = get_grouped_sessions()
                        await ws.send_json({
                            "type": "session_tree",
                            "projects": data_tree["projects"],
                            "general_sessions": data_tree["general_sessions"],
                            "current": current_active_session_id
                        })

                    elif action == "switch_session":
                        target_id = data.get("session_id")
                        target_file = os.path.join(BRAIN_DIR, target_id, ".system_generated", "logs", "transcript.jsonl")
                        if os.path.exists(target_file):
                            if file_handle:
                                file_handle.close()
                            current_active_file = target_file
                            current_active_session_id = target_id
                            is_current_session_running = False
                            last_log_active_time = time.time()
                            print(f"[+] 切换会话: {target_id}")
                            file_handle = open(current_active_file, "r", encoding="utf-8", errors="replace")
                            file_handle.seek(0, os.SEEK_END)
                            history = load_session_history(current_active_file, max_lines=40)
                            file_mtime = os.path.getmtime(current_active_file)
                            real_running = (time.time() - file_mtime < 2.5)
                            await ws.send_json({
                                "type": "session_history",
                                "session_id": current_active_session_id,
                                "history": history,
                                "is_running": real_running
                            })

                    elif action == "browse_files":
                        sub_path = data.get("sub_path", "")
                        base = current_workspace_dir if (current_workspace_dir and os.path.exists(current_workspace_dir)) else os.path.expanduser("~")
                        result = list_workspace_files(base, sub_path)
                        await ws.send_json({
                            "type": "file_browser_result",
                            "base_dir_name": os.path.basename(base),
                            "current_path": result["current_path"],
                            "items": result["items"]
                        })

                    elif action == "read_file":
                        rel_or_abs = data.get("path", "")
                        base = current_workspace_dir if (current_workspace_dir and os.path.exists(current_workspace_dir)) else None
                        target = rel_or_abs if os.path.isabs(rel_or_abs) else (os.path.join(base, rel_or_abs) if base else rel_or_abs)
                        safe, result = is_path_safe(target, current_workspace_dir)
                        if not safe:
                            await ws.send_json({"type": "file_content_error", "path": rel_or_abs, "error": f"安全拦截: {result}"})
                            continue
                        target = result
                        if os.path.exists(target) and os.path.isfile(target):
                            try:
                                size = os.path.getsize(target)
                                # 🛡️ 二进制文件安全防御：拦截 zip/exe/pdf/png 等二进制，防止前端排版卡死
                                binary_exts = {'.zip', '.tar', '.gz', '.tgz', '.7z', '.rar', '.png', '.jpg', '.jpeg', '.webp', '.gif', '.pdf', '.exe', '.bin', '.dll', '.so', '.pyc', '.db', '.sqlite'}
                                is_binary = os.path.splitext(target)[1].lower() in binary_exts
                                if not is_binary:
                                    try:
                                        with open(target, 'rb') as check_f:
                                            chunk = check_f.read(1024)
                                            if b'\x00' in chunk:
                                                is_binary = True
                                    except Exception:
                                        pass

                                if is_binary:
                                    await ws.send_json({
                                        "type": "file_content_error",
                                        "path": target,
                                        "error": "该文件为二进制文件（如压缩包、媒体或程序），不支持作为文本查看。请直接点击下载按钮下载该文件。"
                                    })
                                else:
                                    with open(target, "r", encoding="utf-8", errors="replace") as f:
                                        lines = f.readlines()
                                    truncated = len(lines) > 2000
                                    await ws.send_json({
                                        "type": "file_content",
                                        "path": target,
                                        "name": os.path.basename(target),
                                        "content": "".join(lines[:2000]),
                                        "total_lines": len(lines),
                                        "truncated": truncated,
                                        "size": size
                                    })
                            except Exception as e:
                                await ws.send_json({"type": "file_content_error", "path": target, "error": str(e)})
                        else:
                            await ws.send_json({"type": "file_content_error", "path": target, "error": "文件不存在或不可读取"})

                    elif action == "get_git_diff":
                        base = current_workspace_dir if (current_workspace_dir and os.path.exists(current_workspace_dir)) else None
                        if not base:
                            await ws.send_json({
                                "type": "git_diff_result",
                                "workspace": "",
                                "status": "",
                                "diff": "未指定有效的工作区目录"
                            })
                            continue
                        safe, _ = is_path_safe(base, base)
                        if not safe:
                            await ws.send_json({
                                "type": "git_diff_result",
                                "workspace": base,
                                "status": "",
                                "diff": "工作区不在允许的安全目录白名单内"
                            })
                            continue
                        diff_output = ""
                        status_output = ""
                        try:
                            s_proc = subprocess.run(["git", "status", "--short"], cwd=base, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=5)
                            status_output = s_proc.stdout.strip()
                            d_proc = subprocess.run(["git", "diff"], cwd=base, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=5)
                            diff_output = d_proc.stdout
                        except Exception as e:
                            diff_output = f"Git 执行异常: {e}"
                        await ws.send_json({
                            "type": "git_diff_result",
                            "workspace": base,
                            "status": status_output,
                            "diff": diff_output
                        })

                    elif action == "upload_file":
                        target_id = data.get("session_id") or current_active_session_id
                        if not target_id:
                            latest = get_latest_transcript_path()
                            if latest:
                                target_id = latest.split(os.sep)[-4]
                        
                        target_dir = os.path.join(BRAIN_DIR, target_id, ".user_uploaded") if target_id else os.path.join(BRAIN_DIR, ".user_uploaded")
                        os.makedirs(target_dir, exist_ok=True)

                        raw_name = data.get("filename", "upload.png")
                        safe_name = os.path.basename(raw_name).replace(" ", "_")
                        timestamp = int(time.time() * 1000)
                        saved_name = f"media_{timestamp}_{safe_name}"
                        saved_path = os.path.join(target_dir, saved_name)

                        raw_data = data.get("data", "")
                        if "," in raw_data:
                            raw_data = raw_data.split(",", 1)[1]
                        
                        try:
                            decoded = base64.b64decode(raw_data)
                            with open(saved_path, "wb") as f:
                                f.write(decoded)
                            
                            is_img = any(saved_name.lower().endswith(ext) for ext in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"])
                            norm_path = saved_path.replace("\\", "/")
                            print(f"[+] 文件上传成功: {norm_path} ({len(decoded)} 字节)")
                            await ws.send_json({
                                "type": "file_uploaded",
                                "filename": safe_name,
                                "path": norm_path,
                                "is_image": is_img,
                                "size": len(decoded)
                            })
                        except Exception as e:
                            print(f"[-] 上传保存失败: {e}")
                            await ws.send_json({
                                "type": "file_upload_error",
                                "error": str(e)
                            })

                    elif action == "get_artifacts":
                        target_id = data.get("session_id") or current_active_session_id
                        artifacts = []
                        if target_id:
                            brain_path = os.path.join(BRAIN_DIR, target_id)
                            if os.path.exists(brain_path):
                                for entry in os.scandir(brain_path):
                                    if entry.is_file() and entry.name.endswith(".md"):
                                        stat = entry.stat()
                                        artifacts.append({
                                            "name": entry.name,
                                            "path": entry.path.replace("\\", "/"),
                                            "size": stat.st_size,
                                            "modified": time.strftime("%Y-%m-%d %H:%M", time.localtime(stat.st_mtime))
                                        })
                                artifacts.sort(key=lambda x: x["name"])
                        await ws.send_json({
                            "type": "artifacts_result",
                            "session_id": target_id,
                            "artifacts": artifacts
                        })

                    elif action == "get_tasks":
                        target_id = data.get("session_id") or current_active_session_id
                        tasks = []
                        if target_id:
                            tasks_dir = os.path.join(BRAIN_DIR, target_id, ".system_generated", "tasks")
                            if os.path.exists(tasks_dir):
                                for entry in os.scandir(tasks_dir):
                                    if entry.is_file() and entry.name.endswith(".log"):
                                        stat = entry.stat()
                                        task_id = entry.name.replace(".log", "")
                                        recent_log = ""
                                        try:
                                            with open(entry.path, "r", encoding="utf-8", errors="replace") as f:
                                                lines = f.readlines()
                                                recent_log = "".join(lines[-15:])
                                        except Exception:
                                            pass
                                        tasks.append({
                                            "task_id": task_id,
                                            "log_path": entry.path.replace("\\", "/"),
                                            "size": stat.st_size,
                                            "recent_log": recent_log,
                                            "modified": time.strftime("%H:%M:%S", time.localtime(stat.st_mtime))
                                        })
                                tasks.sort(key=lambda x: x["modified"], reverse=True)
                        await ws.send_json({
                            "type": "tasks_result",
                            "session_id": target_id,
                            "tasks": tasks
                        })

                except Exception as e:
                    print(f"[-] 消息处理异常: {e}")

            elif msg.type == WSMsgType.ERROR:
                print(f"[-] WS 错误: {ws.exception()}")

    finally:
        connected_ws_clients.discard(ws)
        print(f"[-] 客户端断开连接: {remote}")

    return ws

@web.middleware
async def spa_middleware(request, handler):
    if request.path == "/ws":
        return await handler(request)
    try:
        response = await handler(request)
        if response.status == 404:
            index_path = os.path.join(FLUTTER_WEB_DIR, "index.html")
            if os.path.exists(index_path):
                resp = web.FileResponse(index_path)
                resp.headers["Cache-Control"] = "no-cache, no-store, must-revalidate, max-age=0"
                resp.headers["Pragma"] = "no-cache"
                resp.headers["Expires"] = "0"
                resp.headers["CDN-Cache-Control"] = "no-cache, no-store, max-age=0"
                resp.headers["Cloudflare-CDN-Cache-Control"] = "no-cache, no-store, max-age=0"
                return resp
        if hasattr(response, "headers"):
            response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate, max-age=0"
            response.headers["Pragma"] = "no-cache"
            response.headers["Expires"] = "0"
            response.headers["CDN-Cache-Control"] = "no-cache, no-store, max-age=0"
            response.headers["Cloudflare-CDN-Cache-Control"] = "no-cache, no-store, max-age=0"
        return response
    except web.HTTPNotFound:
        index_path = os.path.join(FLUTTER_WEB_DIR, "index.html")
        if os.path.exists(index_path):
            resp = web.FileResponse(index_path)
            resp.headers["Cache-Control"] = "no-cache, no-store, must-revalidate, max-age=0"
            resp.headers["Pragma"] = "no-cache"
            resp.headers["Expires"] = "0"
            resp.headers["CDN-Cache-Control"] = "no-cache, no-store, max-age=0"
            resp.headers["Cloudflare-CDN-Cache-Control"] = "no-cache, no-store, max-age=0"
            return resp
        raise

async def background_tail(app):
    task = asyncio.create_task(tail_transcript())
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass

async def test_page_handler(request):
    p = os.path.join(os.path.dirname(__file__), "test_client.html")
    if os.path.exists(p):
        return web.FileResponse(p)
    return web.Response(text="test_client.html not found", status=404)

async def media_handler(request):
    token = request.query.get("token") or request.headers.get("X-Auth-Token")
    if AUTH_TOKEN and token != AUTH_TOKEN:
        return web.Response(text="Unauthorized", status=401)
    
    file_path = request.query.get("path", "")
    if not file_path:
        return web.Response(text="Missing path", status=400)
    
    clean_path = urllib.parse.unquote(file_path)
    if clean_path.startswith("file:///"):
        clean_path = clean_path[8:]
    elif clean_path.startswith("file://"):
        clean_path = clean_path[7:]
    if clean_path.startswith("/") and len(clean_path) > 2 and clean_path[2] == ":":
        clean_path = clean_path[1:]
    clean_path = clean_path.replace("/", "\\")
    safe, result = is_path_safe(clean_path, current_workspace_dir)
    if not safe:
        return web.Response(text=f"Forbidden: {result}", status=403)
    
    norm_path = result
    if not os.path.exists(norm_path) or not os.path.isfile(norm_path):
        return web.Response(text="File not found", status=404)
    
    headers = build_cors_headers(request)
    return web.FileResponse(norm_path, headers=headers)

async def download_handler(request):
    token = request.query.get("token") or request.headers.get("X-Auth-Token")
    if AUTH_TOKEN and token != AUTH_TOKEN:
        return web.Response(text="Unauthorized", status=401)
    
    file_path = request.query.get("path", "")
    if not file_path:
        return web.Response(text="Missing path", status=400)
    
    clean_path = urllib.parse.unquote(file_path)
    if clean_path.startswith("file:///"):
        clean_path = clean_path[8:]
    elif clean_path.startswith("file://"):
        clean_path = clean_path[7:]
    if clean_path.startswith("/") and len(clean_path) > 2 and clean_path[2] == ":":
        clean_path = clean_path[1:]
    clean_path = clean_path.replace("/", "\\")
    safe, result = is_path_safe(clean_path, current_workspace_dir)
    if not safe:
        return web.Response(text=f"Forbidden: {result}", status=403)
    
    norm_path = result
    if not os.path.exists(norm_path) or not os.path.isfile(norm_path):
        return web.Response(text="File not found", status=404)
    
    filename = os.path.basename(norm_path)
    quoted_name = urllib.parse.quote(filename)
    headers = {
        "Content-Disposition": f'attachment; filename="{quoted_name}"; filename*=UTF-8\'\'{quoted_name}',
        "Cache-Control": "no-cache"
    }
    headers = build_cors_headers(request, headers)
    return web.FileResponse(norm_path, headers=headers)

async def index_handler(request):
    token = request.query.get("token")
    if AUTH_TOKEN and token != AUTH_TOKEN:
        return web.Response(text="<h1>401 Unauthorized</h1><p>请提供正确的访问令牌 (token)</p>", content_type="text/html", status=401)
    index_path = os.path.join(FLUTTER_WEB_DIR, "index.html")
    if os.path.exists(index_path):
        return web.FileResponse(index_path)
    return web.Response(text="index.html not found", status=404)

async def health_handler(request):
    headers = build_cors_headers(request, {"Cache-Control": "no-cache"})
    return web.json_response({
        "status": "ok",
        "service": "agy_windows",
        "active_session": current_active_session_id,
        "timestamp": int(time.time())
    }, headers=headers)

async def api_nodes_handler(request):
    headers = build_cors_headers(request, {"Cache-Control": "no-cache"})
    return web.json_response({
        "current": "windows",
        "nodes": [
            {"id": "windows", "name": "Windows PC", "desc": "主力开发机", "online": True}
        ]
    }, headers=headers)

def init_app():
    app = web.Application(middlewares=[spa_middleware])
    app.router.add_get('/', index_handler)
    app.router.add_get('/ws', websocket_handler)
    app.router.add_get('/test', test_page_handler)
    app.router.add_get('/api/health', health_handler)
    app.router.add_get('/api/nodes', api_nodes_handler)
    app.router.add_get('/api/media', media_handler)
    app.router.add_get('/api/download', download_handler)
    if os.path.exists(FLUTTER_WEB_DIR):
        app.router.add_static('/', path=FLUTTER_WEB_DIR, show_index=False, follow_symlinks=True)
    app.cleanup_ctx.append(background_tail)
    return app

if __name__ == "__main__":
    print("=" * 60)
    print("  AGY Remote 一体化单端口服务 (aiohttp)")
    print(f"  👉 统一访问入口: http://0.0.0.0:{PORT}")
    print(f"  👉 静态资源目录: {FLUTTER_WEB_DIR}")
    print(f"  👉 实时通信通道: ws://0.0.0.0:{PORT}/ws")
    print("=" * 60)
    app = init_app()
    web.run_app(app, host="0.0.0.0", port=PORT, shutdown_timeout=1.0, access_log=None)
