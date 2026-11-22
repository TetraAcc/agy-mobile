import os
import sys
import json
import time
import glob
import re
import asyncio
import subprocess
import sqlite3
import logging
import urllib.parse
import urllib.request
from aiohttp import web, WSMsgType
import aiohttp
from server_common import (
    IGNORED_MSG_TYPES,
    SENSITIVE_PATTERNS,
    is_path_safe as common_is_path_safe,
    build_cors_headers as common_build_cors_headers,
    clean_display_content,
    parse_project_name_and_path,
    list_workspace_files
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

# 基础目录与配置
BRAIN_DIR = os.path.expanduser("~/.gemini/antigravity-cli/brain")
DB_PATH = os.path.expanduser("~/.gemini/antigravity-cli/conversation_summaries.db")
AGENT_API_PATH = os.path.expanduser("~/.gemini/antigravity-cli/bin/agentapi")
FLUTTER_WEB_DIR = os.path.expanduser("~/agy_remote/web")

# ==========================================
# 🛡️ 外部配置文件加载与多租户白名单
# ==========================================
CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "server_config.json")
def load_deck_config():
    cfg = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
                cfg = data.get("deck", data)
        except Exception as e:
            logging.error(f"加载 server_config.json 异常: {e}")
    return cfg

DECK_CONFIG = load_deck_config()
PORT = int(DECK_CONFIG.get("port") or os.environ.get("AGY_PORT", 8768))
ALLOWED_ORIGINS = DECK_CONFIG.get("allowed_origins", ["*"])

USER_PROFILES = DECK_CONFIG.get("user_profiles", {
    "sample_token": {
        "user": "DefaultUser",
        "allowed_nodes": ["deck"],
        "default_node": "deck"
    }
})

NODE_REGISTRY = DECK_CONFIG.get("node_registry", {
    "deck": {
        "name": "Steam Deck",
        "host": "127.0.0.1:8768",
        "is_local": True
    }
})

raw_roots = DECK_CONFIG.get("allowed_roots", [
    "~/.gemini/antigravity-cli/brain",
    "~/agy_remote"
])
ALLOWED_ROOTS = [os.path.realpath(os.path.expanduser(r)) for r in raw_roots]

def is_path_safe(target_path):
    return common_is_path_safe(
        target_path,
        allowed_roots=ALLOWED_ROOTS,
        extra_dirs=[FLUTTER_WEB_DIR]
    )

def build_cors_headers(request, base_headers=None):
    return common_build_cors_headers(request, allowed_origins=ALLOWED_ORIGINS, base_headers=base_headers)

connected_ws_clients = {}  # ws -> token
current_active_session_id = None
current_active_file = None
current_workspace_dir = None
file_handle = None
is_deck_session_running = False
last_log_active_time = time.time()

async def is_node_alive(node_id):
    cfg = NODE_REGISTRY.get(node_id)
    if not cfg:
        return False
    if cfg.get("is_local"):
        return True
    host = cfg["host"]
    try:
        timeout = aiohttp.ClientTimeout(total=1.2)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(f"http://{host}/?token=probe") as resp:
                return resp.status in (200, 401)
    except Exception as e:
        logging.debug(f"节点 {node_id} ({host}) 探活失败: {e}")
        return False

async def get_user_nodes_status(user_token):
    profile = USER_PROFILES.get(user_token)
    if not profile:
        return []
    nodes = []
    for nid in profile["allowed_nodes"]:
        cfg = NODE_REGISTRY.get(nid)
        if not cfg:
            continue
        online = await is_node_alive(nid)
        nodes.append({
            "id": nid,
            "name": cfg["name"],
            "online": online
        })
    return nodes

def get_grouped_sessions():
    if not os.path.exists(DB_PATH):
        return {"projects": {}, "general_sessions": []}
    try:
        conn = sqlite3.connect(DB_PATH)
        cur = conn.cursor()
        cur.execute("SELECT conversation_id, title, workspace_uris, updated_at FROM conversation_summaries ORDER BY updated_at DESC")
        rows = cur.fetchall()
        conn.close()

        projects = {}
        general_sessions = []

        for cid, title, ws_uris, updated_at in rows:
            clean_title = title if (title and title.strip()) else "新任务"
            time_str = ""
            if updated_at:
                try:
                    ts = int(updated_at)
                    time_str = time.strftime("%Y-%m-%d", time.localtime(ts))
                except Exception:
                    time_str = str(updated_at)[:10]

            proj_name, proj_path = parse_project_name_and_path(ws_uris)
            item = {
                "id": cid,
                "title": clean_title,
                "time": time_str,
                "workspace_path": proj_path
            }

            if proj_name:
                if proj_name not in projects:
                    projects[proj_name] = []
                projects[proj_name].append(item)
            else:
                general_sessions.append(item)

        return {"projects": projects, "general_sessions": general_sessions}
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

def parse_transcript_line(line_str):
    if not line_str.strip():
        return None
    try:
        data = json.loads(line_str)
        source = data.get("source", "")
        step_type = data.get("type", "")
        status = data.get("status", "")
        thinking = data.get("thinking", "")
        content = data.get("content", "")
        timestamp = data.get("created_at", "")
        step_index = data.get("step_index", 0)
        tool_calls = data.get("tool_calls", [])

        if not content and not thinking and not tool_calls and step_type != "USER_INPUT":
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
            "type": "agent_update",
            "step_index": step_index,
            "source": source,
            "msg_type": step_type,
            "status": status,
            "content": content,
            "thinking": thinking,
            "tool_calls": clean_calls,
            "timestamp": timestamp
        }
    except Exception:
        return None

def load_session_history(file_path, max_lines=300):
    if not file_path or not os.path.exists(file_path):
        return []
    history = []
    try:
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
            scan_lines = lines[-max_lines:] if len(lines) > max_lines else lines
            for line in scan_lines:
                evt = parse_transcript_line(line)
                if evt:
                    history.append(evt)
    except Exception as e:
        print(f"[-] 读取历史异常: {e}")
    return history[-60:]

def dispatch_agent_message(session_id, content):
    cmd = [AGENT_API_PATH, "send-message", "--title=AGY Remote", session_id, content]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=8)
        if res.returncode == 0:
            return True, "ok"
        else:
            return False, res.stderr.strip() or f"exit code {res.returncode}"
    except Exception as e:
        return False, str(e)

async def broadcast_message(message_dict):
    if not connected_ws_clients:
        return
    payload = json.dumps(message_dict, ensure_ascii=False)
    for ws in list(connected_ws_clients.keys()):
        try:
            await ws.send_str(payload)
        except Exception:
            pass

async def tail_transcript():
    global current_active_file, file_handle, current_active_session_id, is_deck_session_running, last_log_active_time
    print("[*] Steam Deck 本地日志监控协程已启动...")
    while True:
        try:
            latest = get_latest_transcript_path()
            if latest and latest != current_active_file:
                print(f"[*] 检测到新活跃会话: {latest}")
                current_active_file = latest
                parts = current_active_file.split(os.sep)
                current_active_session_id = parts[-4] if len(parts) >= 4 else "unknown"
                if file_handle:
                    file_handle.close()
                file_handle = open(current_active_file, "r", encoding="utf-8", errors="replace")
                file_handle.seek(0, os.SEEK_END)

            if file_handle:
                line = file_handle.readline()
                if line:
                    last_log_active_time = time.time()
                    event = parse_transcript_line(line)
                    if event:
                        event["session_id"] = current_active_session_id
                        event["is_running"] = True
                        is_deck_session_running = True
                        await broadcast_message(event)
                else:
                    # 静默超时自动复位：若超过 2.5 秒没有新的日志产生，自动归位为空闲
                    if is_deck_session_running and (time.time() - last_log_active_time > 2.5):
                        is_deck_session_running = False
                        await broadcast_message({
                            "type": "status_change",
                            "session_id": current_active_session_id,
                            "is_running": False
                        })
                    await asyncio.sleep(0.3)
            else:
                await asyncio.sleep(1.0)
        except Exception as e:
            await asyncio.sleep(1.0)

# ==========================================
# 🛡️ 远程主机专属代理隧道（带租户安全隔离）
# ==========================================
async def proxy_remote_ws(request, ws_client, target_node, user_token):
    remote = request.remote
    cfg = NODE_REGISTRY.get(target_node)
    if not cfg:
        await ws_client.close()
        return ws_client

    host = cfg["host"]
    node_name = cfg["name"]
    print(f"[Proxy] 用户 '{user_token}' ({remote}) 请求接入远程节点 [{node_name}]: {host}")
    remote_ws_url = f"ws://{host}/ws?token={user_token}"

    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(remote_ws_url) as remote_ws:
                print(f"[Proxy] 成功与 [{node_name}] ({host}) 建立全双工隧道！")
                
                # 握手时立即向客户端推送【仅限该用户可见的节点列表】
                try:
                    user_nodes = await get_user_nodes_status(user_token)
                    await ws_client.send_json({
                        "type": "nodes_status",
                        "nodes": user_nodes
                    })
                except Exception:
                    pass

                async def client_to_remote():
                    async for msg in ws_client:
                        if msg.type == WSMsgType.TEXT:
                            await remote_ws.send_str(msg.data)
                        elif msg.type == WSMsgType.BINARY:
                            await remote_ws.send_bytes(msg.data)
                        elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                            break

                async def remote_to_client():
                    async for msg in remote_ws:
                        if msg.type == WSMsgType.TEXT:
                            try:
                                # 拦截并过滤 nodes_status 消息，确保永远只呈现该租户授权节点
                                parsed = json.loads(msg.data)
                                if parsed.get("type") == "nodes_status":
                                    filtered_nodes = await get_user_nodes_status(user_token)
                                    parsed["nodes"] = filtered_nodes
                                    await ws_client.send_json(parsed)
                                    continue
                            except Exception:
                                pass
                            await ws_client.send_str(msg.data)
                        elif msg.type == WSMsgType.BINARY:
                            await ws_client.send_bytes(msg.data)
                        elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                            break

                t_c2r = asyncio.create_task(client_to_remote())
                t_r2c = asyncio.create_task(remote_to_client())
                done, pending = await asyncio.wait([t_c2r, t_r2c], return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()

    except Exception as e:
        print(f"[-] 代理至 [{node_name}] 失败: {e}")
        try:
            user_nodes = await get_user_nodes_status(user_token)
            await ws_client.send_json({
                "type": "nodes_status",
                "nodes": user_nodes
            })
            await ws_client.send_json({
                "type": "node_offline",
                "msg": f"无法连接到目标电脑 [{node_name}] ({host}): {e}\n请确认该电脑已开机且已运行 AGY 远程控制服务。"
            })
        except Exception:
            pass
    finally:
        print(f"[Proxy] 远程会话通道已关闭: {remote}")
    return ws_client

async def websocket_handler(request):
    token = request.query.get("token") or request.headers.get("X-Auth-Token")
    if token not in USER_PROFILES:
        return web.Response(text="Unauthorized", status=401)

    profile = USER_PROFILES[token]
    requested_node = request.query.get("node", profile["default_node"]).lower()

    # 🛡️ 严格防越权拦截：如果请求的节点不在授权列表中，强制修正为默认节点
    if requested_node not in profile["allowed_nodes"]:
        target_node = profile["default_node"]
    else:
        target_node = requested_node

    ws = web.WebSocketResponse(heartbeat=20.0, max_msg_size=32 * 1024 * 1024)
    await ws.prepare(request)

    # 如果是远程节点（如 Windows 或女友电脑 li），直接转入安全代理管道
    if target_node != "deck":
        return await proxy_remote_ws(request, ws, target_node, token)

    # 如果是 Deck 本地节点
    remote = request.remote
    print(f"[+] 客户端接入 Steam Deck 本机 WebSocket: {remote} (User: {profile['user']})")
    connected_ws_clients[ws] = token

    global current_active_file, current_active_session_id, current_workspace_dir, file_handle

    if not current_active_file:
        latest = get_latest_transcript_path()
        if latest:
            current_active_file = latest
            parts = current_active_file.split(os.sep)
            current_active_session_id = parts[-4] if len(parts) >= 4 else "unknown"
            if file_handle:
                file_handle.close()
            file_handle = open(current_active_file, "r", encoding="utf-8", errors="replace")
            file_handle.seek(0, os.SEEK_END)

    history = load_session_history(current_active_file, max_lines=300) if current_active_file else []
    data_tree = get_grouped_sessions()
    user_nodes = await get_user_nodes_status(token)

    # 1. 握手与连接成功确认
    await ws.send_json({
        "type": "connected",
        "active_session": current_active_session_id or "unknown",
        "node": "deck",
        "msg": "Connected to Steam Deck Hub!"
    })

    # 2. 租户隔离的节点列表推送
    await ws.send_json({
        "type": "nodes_status",
        "nodes": user_nodes
    })

    # 3. 会话树
    await ws.send_json({
        "type": "session_tree",
        "projects": data_tree["projects"],
        "general_sessions": data_tree["general_sessions"],
        "current": current_active_session_id or ""
    })

    # 4. 历史消息
    if history:
        await ws.send_json({
            "type": "session_history",
            "session_id": current_active_session_id,
            "history": history,
            "is_running": bool(is_deck_session_running)
        })

    try:
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                try:
                    data = json.loads(msg.data)
                    action = data.get("action")

                    if action == "ping":
                        await ws.send_json({"type": "pong", "time": time.time()})

                    elif action == "get_nodes":
                        nodes = await get_user_nodes_status(token)
                        await ws.send_json({
                            "type": "nodes_status",
                            "nodes": nodes
                        })

                    elif action == "get_quota":
                        await ws.send_json({
                            "type": "quota_update",
                            "quota": {"groups": [], "models": []}
                        })

                    elif action == "prompt":
                        content = data.get("content", "").strip()
                        session_id = data.get("session_id") or current_active_session_id
                        if content:
                            ok, err_msg = dispatch_agent_message(session_id, content)
                            await ws.send_json({
                                "type": "prompt_ack",
                                "status": "ok" if ok else "error",
                                "error": err_msg if not ok else ""
                            })

                    elif action == "stop":
                        target_id = data.get("session_id") or current_active_session_id
                        await broadcast_message({
                            "type": "stopped",
                            "session_id": target_id
                        })
                        await ws.send_json({
                            "type": "stop_ack",
                            "status": "ok",
                            "session_id": target_id
                        })

                    elif action == "get_sessions":
                        data_tree = get_grouped_sessions()
                        await ws.send_json({
                            "type": "session_tree",
                            "projects": data_tree.get("projects", {}),
                            "general_sessions": data_tree.get("general_sessions", []),
                            "current": current_active_session_id or ""
                        })

                    elif action == "switch_session":
                        target_id = data.get("session_id")
                        if target_id:
                            target_file = os.path.join(BRAIN_DIR, target_id, ".system_generated", "logs", "transcript.jsonl")
                            if os.path.exists(target_file):
                                current_active_file = target_file
                                current_active_session_id = target_id
                                if file_handle:
                                    try:
                                        file_handle.close()
                                    except Exception:
                                        pass
                                file_handle = open(current_active_file, "r", encoding="utf-8", errors="replace")
                                file_handle.seek(0, os.SEEK_END)
                                s_history = load_session_history(current_active_file, max_lines=300)
                                await ws.send_json({
                                    "type": "session_history",
                                    "session_id": target_id,
                                    "history": s_history,
                                    "is_running": False
                                })

                    elif action == "new_session":
                        content = data.get("content", "").strip() or "你好，开启新会话"
                        ok, err_msg = dispatch_agent_message(None, content)
                        await ws.send_json({
                            "type": "new_session_ack",
                            "status": "ok" if ok else "error",
                            "error": err_msg if not ok else ""
                        })
                except Exception as e:
                    print(f"[-] 处理消息异常: {e}")
            elif msg.type == WSMsgType.ERROR:
                print(f"[-] WS 错误: {ws.exception()}")

    finally:
        connected_ws_clients.pop(ws, None)
        print(f"[-] 客户端断开连接: {remote}")

    return ws

async def media_handler(request):
    token = request.query.get("token") or request.headers.get("X-Auth-Token")
    if token not in USER_PROFILES:
        return web.Response(text="Unauthorized", status=401)
    
    file_path = request.query.get("path", "")
    if not file_path:
        return web.Response(text="Missing path", status=400)
    
    # 清洗 file:/// 前缀与 url 解码
    clean_path = urllib.parse.unquote(file_path)
    if clean_path.startswith("file:///"):
        clean_path = clean_path[8:]
    elif clean_path.startswith("file://"):
        clean_path = clean_path[7:]
    if clean_path.startswith("/") and len(clean_path) > 2 and clean_path[2] == ":":
        clean_path = clean_path[1:]

    profile = USER_PROFILES[token]
    req_node = request.query.get("node")
    target_node = req_node if (req_node and req_node in profile.get("allowed_nodes", [])) else profile["default_node"]
    cfg = NODE_REGISTRY.get(target_node)

    # 判断是否为 Windows 路径或目标节点为 Windows 设备
    is_win_path = clean_path.startswith("C:") or clean_path.startswith("c:") or "\\" in clean_path
    if cfg and not cfg["is_local"] and (is_win_path or target_node in ["windows", "simeng_pc"]):
        target_host = cfg["host"]
        win_url = f"http://{target_host}/api/media?path={urllib.parse.quote(clean_path)}&token={token}"
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(win_url, timeout=10) as resp:
                    if resp.status == 200:
                        content = await resp.read()
                        ct = resp.headers.get("Content-Type", "image/png")
                        headers = build_cors_headers(request, {"Content-Type": ct, "Cache-Control": "public, max-age=86400"})
                        return web.Response(body=content, headers=headers)
                    return web.Response(text="Remote host returned error", status=resp.status)
        except Exception as e:
            return web.Response(text=f"Failed to fetch from remote: {e}", status=502)

    # 本地路径读取 — 严格白名单与敏感文件阻断
    safe, result = is_path_safe(clean_path)
    if not safe:
        return web.Response(text=f"Forbidden: {result}", status=403)
        
    norm_path = result
    if not os.path.exists(norm_path) or not os.path.isfile(norm_path):
        return web.Response(text="File not found", status=404)
    
    headers = build_cors_headers(request)
    return web.FileResponse(norm_path, headers=headers)

async def download_handler(request):
    token = request.query.get("token") or request.headers.get("X-Auth-Token")
    if token not in USER_PROFILES:
        return web.Response(text="Unauthorized", status=401)
    
    file_path = request.query.get("path", "")
    if not file_path:
        return web.Response(text="Missing path", status=400)
    
    if file_path.startswith("file:///"):
        file_path = file_path.replace("file:///", "")
    elif file_path.startswith("file://"):
        file_path = file_path.replace("file://", "")
    file_path = urllib.parse.unquote(file_path)

    profile = USER_PROFILES[token]
    target_node = request.query.get("node") or profile["default_node"]
    if target_node not in profile["allowed_nodes"]:
        target_node = profile["default_node"]

    cfg = NODE_REGISTRY.get(target_node)
    is_win_path = file_path.startswith("C:") or file_path.startswith("c:") or "\\" in file_path or ":\\" in file_path

    if (cfg and not cfg["is_local"]) or is_win_path:
        target_host = cfg["host"] if (cfg and not cfg["is_local"]) else NODE_REGISTRY["windows"]["host"]
        win_url = f"http://{target_host}/api/download?path={urllib.parse.quote(file_path)}&token={token}"
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(win_url, timeout=60) as resp:
                    if resp.status == 200:
                        content = await resp.read()
                        disposition = resp.headers.get("Content-Disposition", f'attachment; filename="{os.path.basename(file_path)}"')
                        ct = resp.headers.get("Content-Type", "application/octet-stream")
                        headers = {
                            "Content-Disposition": disposition,
                            "Cache-Control": "no-cache"
                        }
                        headers = build_cors_headers(request, headers)
                        return web.Response(body=content, content_type=ct, headers=headers)
                    return web.Response(text=f"Remote host error: {resp.status}", status=resp.status)
        except Exception as e:
            return web.Response(text=f"Failed to fetch from remote: {e}", status=502)

    # 本地路径下载 — 严格白名单与敏感文件阻断
    safe, result = is_path_safe(file_path)
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
    if token not in USER_PROFILES:
        return web.Response(text="<h1>401 Unauthorized</h1><p>请提供正确的访问令牌 (token)</p>", content_type="text/html", status=401)
    index_path = os.path.join(FLUTTER_WEB_DIR, "index.html")
    if os.path.exists(index_path):
        return web.FileResponse(index_path)
    return web.Response(text="index.html not found", status=404)

async def api_nodes_handler(request):
    token = request.query.get("token") or request.headers.get("X-Auth-Token")
    if token not in USER_PROFILES:
        return web.json_response({"error": "unauthorized"}, status=401)
    nodes = await get_user_nodes_status(token)
    profile = USER_PROFILES[token]
    return web.json_response({
        "current": profile["default_node"],
        "nodes": nodes
    })

@web.middleware
async def spa_middleware(request, handler):
    if request.path.startswith("/ws") or request.path.startswith("/api"):
        return await handler(request)
    try:
        response = await handler(request)
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate, max-age=0"
        response.headers["CDN-Cache-Control"] = "no-cache, no-store, max-age=0"
        response.headers["Cloudflare-CDN-Cache-Control"] = "no-cache, no-store, max-age=0"
        if response.status == 404:
            index_path = os.path.join(FLUTTER_WEB_DIR, "index.html")
            if os.path.exists(index_path):
                return web.FileResponse(index_path)
        return response
    except web.HTTPNotFound:
        index_path = os.path.join(FLUTTER_WEB_DIR, "index.html")
        if os.path.exists(index_path):
            return web.FileResponse(index_path)
        raise

async def check_and_broadcast_nodes():
    while True:
        try:
            if connected_ws_clients:
                for ws, token in list(connected_ws_clients.items()):
                    try:
                        nodes = await get_user_nodes_status(token)
                        await ws.send_json({
                            "type": "nodes_status",
                            "nodes": nodes
                        })
                    except Exception as e:
                        logging.debug(f"向客户端广播节点状态失败: {e}")
        except Exception as e:
            logging.debug(f"节点状态巡检循环异常: {e}")
        await asyncio.sleep(8)

async def background_workers(app):
    t1 = asyncio.create_task(tail_transcript())
    t2 = asyncio.create_task(check_and_broadcast_nodes())
    yield
    t1.cancel()
    t2.cancel()
    try:
        await asyncio.gather(t1, t2, return_exceptions=True)
    except Exception:
        pass

def init_app():
    app = web.Application(middlewares=[spa_middleware])
    app.router.add_get('/', index_handler)
    app.router.add_get('/ws', websocket_handler)
    app.router.add_get('/api/nodes', api_nodes_handler)
    app.router.add_get('/api/media', media_handler)
    app.router.add_get('/api/download', download_handler)
    if os.path.exists(FLUTTER_WEB_DIR):
        app.router.add_static('/', path=FLUTTER_WEB_DIR, show_index=False, follow_symlinks=True)
    app.cleanup_ctx.append(background_workers)
    return app

if __name__ == "__main__":
    print("=" * 60)
    print("  AGY Remote 多租户边缘网关服务 (Steam Deck 网关)")
    print(f"  👉 统一访问入口: http://0.0.0.0:{PORT}")
    print(f"  👉 静态资源目录: {FLUTTER_WEB_DIR}")
    print(f"  👉 已配置租户: {list(USER_PROFILES.keys())}")
    print("=" * 60)
    app = init_app()
    web.run_app(app, host="0.0.0.0", port=PORT, shutdown_timeout=1.0, access_log=None)
