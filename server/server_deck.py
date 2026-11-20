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
import aiohttp
from aiohttp import web, WSMsgType

BRAIN_DIR = os.path.expanduser("~/.gemini/antigravity-cli/brain")
DB_PATH = os.path.expanduser("~/.gemini/antigravity-cli/conversation_summaries.db")
AGENT_API_PATH = os.path.expanduser("~/.gemini/antigravity-cli/bin/agentapi")
FLUTTER_WEB_DIR = os.path.expanduser("~/agy_remote/web")
PORT = int(os.environ.get("AGY_PORT", 8768))
AUTH_TOKEN = os.environ.get("AGY_AUTH_TOKEN", "tetra2026")
WINDOWS_HOST = os.environ.get("AGY_WINDOWS_HOST", "192.168.0.22:8765")

connected_ws_clients = set()
current_active_session_id = None
current_active_file = None
current_workspace_dir = None
file_handle = None

async def is_windows_alive():
    try:
        timeout = aiohttp.ClientTimeout(total=1.2)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(f"http://{WINDOWS_HOST}/?token={AUTH_TOKEN}") as resp:
                return resp.status in (200, 401)
    except Exception:
        return False

def parse_project_name_and_path(ws_uris):
    if not ws_uris or ws_uris.strip() in ("", "[]"):
        return None, None
    try:
        uris = json.loads(ws_uris)
        if isinstance(uris, list) and uris:
            raw_uri = uris[0]
            decoded = urllib.parse.unquote(raw_uri)
            if decoded.startswith("file://"):
                local_path = decoded.replace("file://", "")
                folder_name = os.path.basename(local_path.rstrip("/"))
                if not folder_name:
                    folder_name = local_path.rstrip("/")
                return folder_name, local_path
    except Exception:
        pass
    return None, None

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

def list_workspace_files(base_dir, sub_path=""):
    target_dir = os.path.join(base_dir, sub_path) if sub_path else base_dir
    target_dir = os.path.abspath(target_dir)

    if not os.path.exists(target_dir) or not os.path.isdir(target_dir):
        return {"current_path": sub_path, "items": []}

    items = []
    try:
        ignored_names = {".git", ".idea", "node_modules", "build", ".dart_tool", "__pycache__", ".venv"}
        for entry in os.scandir(target_dir):
            if entry.name in ignored_names or entry.name.startswith("."):
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

IGNORED_MSG_TYPES = {"GENERIC", "SYSTEM_MESSAGE", "CHECKPOINT", "STATUS_UPDATE", "TASK_NOTIFICATION", "USER_APPROVAL_RESPONSE"}

def clean_display_content(raw_text):
    if not raw_text:
        return ""
    user_match = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", raw_text, re.DOTALL)
    if user_match:
        return user_match.group(1).strip()
    cleaned = re.sub(r"<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>", "", raw_text, flags=re.DOTALL)
    cleaned = re.sub(r"<SYSTEM_MESSAGE>.*?</SYSTEM_MESSAGE>", "", cleaned, flags=re.DOTALL)
    cleaned = re.sub(r"<INSTRUCTIONS>.*?</INSTRUCTIONS>", "", cleaned, flags=re.DOTALL)

    # 彻底拦截系统注入与控制台爆日志
    if "The following is a" in cleaned or "<SYSTEM_MESSAGE>" in cleaned or "YOU MUST TAKE ONE OF THE FOLLOWING TWO ACTIONS" in cleaned:
        return ""

    stripped = cleaned.strip()
    if stripped.startswith("Created At: 202") and ("Command output:" in stripped or "Command exited with code" in stripped or "Tool is running as a background task" in stripped or "cancelled" in stripped or "Task Description:" in stripped or "Log output:" in stripped):
        return ""

    return stripped

def get_latest_transcript_path():
    pattern = os.path.join(BRAIN_DIR, "*", ".system_generated", "logs", "transcript.jsonl")
    files = glob.glob(pattern)
    if not files:
        return None
    files.sort(key=lambda x: os.path.getmtime(x), reverse=True)
    return files[0]

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

    cmd = [AGENT_API_PATH, "send-message", target_id, content]
    if not os.path.exists(AGENT_API_PATH):
        cmd = ["agy", "agentapi", "send-message", target_id, content]

    try:
        res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=12)
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

def load_session_history(session_file, max_lines=40):
    if not os.path.exists(session_file):
        return []
    history = []
    try:
        with open(session_file, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
            for line in lines[-max_lines:]:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                    msg_type = record.get("type", "")
                    if msg_type in IGNORED_MSG_TYPES:
                        continue

                    raw_content = record.get("content", "")
                    content = clean_display_content(raw_content)
                    thinking = record.get("thinking", "")
                    tool_calls = record.get("tool_calls", [])

                    if not content and not thinking and not tool_calls:
                        continue

                    history.append({
                        "step_index": record.get("step_index", 0),
                        "source": record.get("source", "AGENT"),
                        "msg_type": msg_type,
                        "type": msg_type,
                        "status": record.get("status", ""),
                        "content": content,
                        "thinking": thinking,
                        "tool_calls": tool_calls,
                        "timestamp": record.get("created_at", "")
                    })
                except Exception:
                    pass
    except Exception as e:
        print(f"[-] 读取历史记录失败: {e}")
    return history

async def tail_transcript():
    global current_active_file, current_active_session_id, current_workspace_dir, file_handle
    print("[*] Deck 日志监听常驻协程已就绪...")
    while True:
        try:
            latest = get_latest_transcript_path()
            if latest and latest != current_active_file:
                current_active_file = latest
                parts = current_active_file.split(os.sep)
                current_active_session_id = parts[-4] if len(parts) >= 4 else "unknown"
                print(f"[+] 锁定活跃会话: {current_active_session_id}")

                if os.path.exists(DB_PATH):
                    try:
                        conn = sqlite3.connect(DB_PATH)
                        cur = conn.cursor()
                        row = cur.execute("SELECT workspace_uris FROM conversation_summaries WHERE conversation_id = ?", (current_active_session_id,)).fetchone()
                        conn.close()
                        if row and row[0]:
                            _, ws_path = parse_project_name_and_path(row[0])
                            current_workspace_dir = ws_path
                    except Exception:
                        pass

                if file_handle:
                    file_handle.close()
                file_handle = open(current_active_file, "r", encoding="utf-8", errors="replace")
                file_handle.seek(0, os.SEEK_END)

                history = load_session_history(current_active_file, max_lines=30)
                await broadcast_message({
                    "type": "session_switched",
                    "session_id": current_active_session_id,
                    "workspace": current_workspace_dir or "",
                    "history": history
                })

            if file_handle:
                line = file_handle.readline()
                if line:
                    line = line.strip()
                    if line:
                        try:
                            record = json.loads(line)
                            msg_type = record.get("type", "UNKNOWN")
                            if msg_type in IGNORED_MSG_TYPES:
                                continue

                            raw_content = record.get("content", "")
                            content = clean_display_content(raw_content)
                            thinking = record.get("thinking", "")
                            tool_calls = record.get("tool_calls", [])

                            if not content and not thinking and not tool_calls:
                                continue

                            await broadcast_message({
                                "type": "agent_update",
                                "session_id": current_active_session_id,
                                "step_index": record.get("step_index", 0),
                                "source": record.get("source", "AGENT"),
                                "msg_type": msg_type,
                                "type": msg_type,
                                "status": record.get("status", ""),
                                "content": content,
                                "thinking": thinking,
                                "tool_calls": tool_calls,
                                "timestamp": record.get("created_at", "")
                            })
                        except Exception:
                            pass
                else:
                    await asyncio.sleep(0.3)
            else:
                await asyncio.sleep(1.0)
        except Exception as e:
            await asyncio.sleep(1.0)

async def proxy_windows_ws(request, ws_client):
    remote = request.remote
    print(f"[Proxy] 客户端接入并请求路由至 Windows PC: {remote}")
    win_ws_url = f"ws://{WINDOWS_HOST}/ws?token={AUTH_TOKEN}"

    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(win_ws_url) as win_ws:
                print(f"[Proxy] 成功与 Windows WS ({WINDOWS_HOST}) 建立隧道连接！")
                try:
                    await ws_client.send_json({
                        "type": "nodes_status",
                        "nodes": [
                            {"id": "deck", "name": "Steam Deck", "online": True},
                            {"id": "windows", "name": "Windows PC", "online": True}
                        ]
                    })
                except Exception:
                    pass
                
                async def client_to_win():
                    async for msg in ws_client:
                        if msg.type == WSMsgType.TEXT:
                            await win_ws.send_str(msg.data)
                        elif msg.type == WSMsgType.BINARY:
                            await win_ws.send_bytes(msg.data)
                        elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                            break

                async def win_to_client():
                    async for msg in win_ws:
                        if msg.type == WSMsgType.TEXT:
                            await ws_client.send_str(msg.data)
                        elif msg.type == WSMsgType.BINARY:
                            await ws_client.send_bytes(msg.data)
                        elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                            break

                await asyncio.gather(client_to_win(), win_to_client(), return_exceptions=True)

    except Exception as e:
        print(f"[-] 代理至 Windows PC 失败: {e}")
        try:
            await ws_client.send_json({
                "type": "nodes_status",
                "nodes": [
                    {"id": "deck", "name": "Steam Deck", "online": True},
                    {"id": "windows", "name": "Windows PC", "online": False}
                ]
            })
            await ws_client.send_json({
                "type": "node_offline",
                "msg": f"无法连接到 Windows 主力机 ({WINDOWS_HOST}): {e}"
            })
        except Exception:
            pass
    finally:
        print(f"[Proxy] Windows 代理会话结束: {remote}")
    return ws_client

async def websocket_handler(request):
    token = request.query.get("token") or request.headers.get("X-Auth-Token")
    if AUTH_TOKEN and token != AUTH_TOKEN:
        return web.Response(text="Unauthorized", status=401)

    node = request.query.get("node", "deck").lower()

    ws = web.WebSocketResponse(heartbeat=20.0, max_msg_size=32 * 1024 * 1024)
    await ws.prepare(request)

    if node == "windows":
        return await proxy_windows_ws(request, ws)

    remote = request.remote
    print(f"[+] 客户端接入 Steam Deck 本机 WebSocket: {remote}")
    connected_ws_clients.add(ws)

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

    history = load_session_history(current_active_file, max_lines=40) if current_active_file else []
    data_tree = get_grouped_sessions()
    win_online = await is_windows_alive()

    # 1. 握手与连接成功确认
    await ws.send_json({
        "type": "connected",
        "active_session": current_active_session_id or "unknown",
        "node": "deck",
        "msg": "Connected to Steam Deck Hub!"
    })

    # 2. 双机节点在线状态推送
    await ws.send_json({
        "type": "nodes_status",
        "nodes": [
            {"id": "deck", "name": "Steam Deck", "online": True},
            {"id": "windows", "name": "Windows PC", "online": win_online}
        ]
    })

    # 3. 会话树
    await ws.send_json({
        "type": "session_tree",
        "projects": data_tree["projects"],
        "general_sessions": data_tree["general_sessions"],
        "current": current_active_session_id
    })

    # 4. 兼容老版本 init
    await ws.send_json({
        "type": "init",
        "session_id": current_active_session_id or "unknown",
        "workspace": current_workspace_dir or "",
        "projects": data_tree["projects"],
        "general_sessions": data_tree["general_sessions"]
    })

    if history:
        await ws.send_json({
            "type": "session_history",
            "session_id": current_active_session_id,
            "history": history
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
                        win_online = await is_windows_alive()
                        await ws.send_json({
                            "type": "nodes_status",
                            "nodes": [
                                {"id": "deck", "name": "Steam Deck", "online": True},
                                {"id": "windows", "name": "Windows PC", "online": win_online}
                            ]
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
                        print(f"[*] Deck 收到停止指令: 会话 {target_id}")
                        await broadcast_message({
                            "type": "stopped",
                            "session_id": target_id
                        })
                        await ws.send_json({
                            "type": "stop_ack",
                            "status": "ok",
                            "session_id": target_id
                        })

                    elif action == "delete_session":
                        del_id = data.get("session_id")
                        if del_id:
                            try:
                                if os.path.exists(DB_PATH):
                                    conn = sqlite3.connect(DB_PATH)
                                    cur = conn.cursor()
                                    cur.execute("DELETE FROM conversation_summaries WHERE conversation_id = ?", (del_id,))
                                    conn.commit()
                                    conn.close()

                                target_brain_path = os.path.join(BRAIN_DIR, del_id)
                                if os.path.exists(target_brain_path):
                                    import shutil
                                    shutil.rmtree(target_brain_path, ignore_errors=True)

                                print(f"[+] 成功删除 Deck 会话: {del_id}")
                                await ws.send_json({
                                    "type": "session_deleted",
                                    "session_id": del_id,
                                    "status": "ok"
                                })
                            except Exception as e:
                                print(f"[-] 删除会话失败: {e}")
                                await ws.send_json({
                                    "type": "session_deleted",
                                    "session_id": del_id,
                                    "status": "error",
                                    "error": str(e)
                                })

                    elif action == "new_session":
                        content = data.get("content", "你好，开始新任务").strip()
                        raw_model = data.get("model", "gemini-3.8-flash-high").strip().lower()
                        valid_models = {
                            "gemini-3.8-flash-high", "claude-3-7-sonnet", "claude-3-7-opus",
                            "gpt-oss-120b", "flash", "pro", "flash_lite"
                        }
                        model = raw_model if raw_model in valid_models else "gemini-3.8-flash-high"

                        cmd = [AGENT_API_PATH, "new-conversation", f"--model={model}", content]
                        if not os.path.exists(AGENT_API_PATH):
                            cmd = ["agy", "agentapi", "new-conversation", f"--model={model}", content]

                        try:
                            res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=12)
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
                            print(f"[+] 切换会话: {target_id}")
                            file_handle = open(current_active_file, "r", encoding="utf-8", errors="replace")
                            file_handle.seek(0, os.SEEK_END)
                            history = load_session_history(current_active_file, max_lines=40)
                            await ws.send_json({
                                "type": "session_history",
                                "session_id": current_active_session_id,
                                "history": history
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
                        base = current_workspace_dir if (current_workspace_dir and os.path.exists(current_workspace_dir)) else os.path.expanduser("~")
                        target = rel_or_abs if os.path.isabs(rel_or_abs) else os.path.join(base, rel_or_abs)
                        target = os.path.abspath(target)
                        if os.path.exists(target) and os.path.isfile(target):
                            try:
                                size = os.path.getsize(target)
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
                        base = current_workspace_dir if (current_workspace_dir and os.path.exists(current_workspace_dir)) else os.path.expanduser("~")
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
                        
                        import base64
                        try:
                            decoded = base64.b64decode(raw_data)
                            with open(saved_path, "wb") as f:
                                f.write(decoded)
                            
                            is_img = any(saved_name.lower().endswith(ext) for ext in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"])
                            norm_path = saved_path.replace("\\", "/")
                            print(f"[+] Deck 文件上传成功: {norm_path} ({len(decoded)} 字节)")
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

async def media_handler(request):
    token = request.query.get("token") or request.headers.get("X-Auth-Token")
    if AUTH_TOKEN and token != AUTH_TOKEN:
        return web.Response(text="Unauthorized", status=401)
    
    file_path = request.query.get("path", "")
    if not file_path:
        return web.Response(text="Missing path", status=400)
    
    # 如果是 Windows 路径，反代向 Windows 宿主拉取
    if file_path.startswith("C:") or file_path.startswith("c:") or "\\" in file_path:
        win_url = f"http://{WINDOWS_HOST}/api/media?path={urllib.parse.quote(file_path)}&token={AUTH_TOKEN}"
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(win_url, timeout=5) as resp:
                    if resp.status == 200:
                        content = await resp.read()
                        ct = resp.headers.get("Content-Type", "image/png")
                        return web.Response(body=content, content_type=ct)
                    return web.Response(text="Windows host returned error", status=resp.status)
        except Exception as e:
            return web.Response(text=f"Failed to fetch from Windows: {e}", status=502)

    norm_path = os.path.abspath(file_path)
    if not os.path.exists(norm_path) or not os.path.isfile(norm_path):
        return web.Response(text="File not found", status=404)
    
    return web.FileResponse(norm_path)

async def index_handler(request):
    token = request.query.get("token")
    if AUTH_TOKEN and token != AUTH_TOKEN:
        return web.Response(text="<h1>401 Unauthorized</h1><p>请提供正确的访问令牌 (token)</p>", content_type="text/html", status=401)
    index_path = os.path.join(FLUTTER_WEB_DIR, "index.html")
    if os.path.exists(index_path):
        return web.FileResponse(index_path)
    return web.Response(text="index.html not found", status=404)

async def api_nodes_handler(request):
    win_online = await is_windows_alive()
    return web.json_response({
        "current": "deck",
        "nodes": [
            {"id": "deck", "name": "Steam Deck", "online": True},
            {"id": "windows", "name": "Windows PC", "online": win_online}
        ]
    })

@web.middleware
async def spa_middleware(request, handler):
    if request.path.startswith("/ws") or request.path.startswith("/api"):
        return await handler(request)
    try:
        response = await handler(request)
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
    print("[*] 双机节点状态定时巡检与广播协程已启动...")
    while True:
        try:
            if connected_ws_clients:
                win_online = await is_windows_alive()
                payload = {
                    "type": "nodes_status",
                    "nodes": [
                        {"id": "deck", "name": "Steam Deck", "online": True},
                        {"id": "windows", "name": "Windows PC", "online": win_online}
                    ]
                }
                for ws in list(connected_ws_clients):
                    try:
                        await ws.send_json(payload)
                    except Exception:
                        pass
        except Exception:
            pass
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
    if os.path.exists(FLUTTER_WEB_DIR):
        app.router.add_static('/', path=FLUTTER_WEB_DIR, show_index=False, follow_symlinks=True)
    app.cleanup_ctx.append(background_workers)
    return app

if __name__ == "__main__":
    print("=" * 60)
    print("  AGY Remote 一体化双机网关服务 (Steam Deck 网关)")
    print(f"  👉 统一访问入口: http://0.0.0.0:{PORT}")
    print(f"  👉 静态资源目录: {FLUTTER_WEB_DIR}")
    print(f"  👉 实时通信通道: ws://0.0.0.0:{PORT}/ws")
    print(f"  👉 目标 Windows 宿主: {WINDOWS_HOST}")
    print(f"  👉 授权访问口令: {AUTH_TOKEN}")
    print("=" * 60)
    app = init_app()
    web.run_app(app, host="0.0.0.0", port=PORT, access_log=None)
