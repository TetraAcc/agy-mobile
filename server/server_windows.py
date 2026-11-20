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
from aiohttp import web, WSMsgType

BRAIN_DIR = os.path.expanduser(r"~\.gemini\antigravity\brain")
DB_PATH = os.path.expanduser(r"~\.gemini\antigravity\conversation_summaries.db")
AGENT_API_PATH = os.path.expanduser(r"~\.gemini\antigravity\bin\agentapi.bat")
LANGUAGE_SERVER_EXE = os.path.expanduser(r"~\AppData\Local\Programs\antigravity\resources\bin\language_server.exe")
FLUTTER_WEB_DIR = os.path.expanduser(r"~\.gemini\antigravity\scratch\agy_mobile_app\build\web")
PORT = int(os.environ.get("AGY_PORT", 8765))
AUTH_TOKEN = os.environ.get("AGY_AUTH_TOKEN", "change_me_to_your_token")

connected_ws_clients = set()
current_active_session_id = None
current_active_file = None
current_workspace_dir = None
file_handle = None

def parse_project_name_and_path(ws_uris):
    if not ws_uris or ws_uris.strip() in ("", "[]"):
        return None, None
    try:
        uris = json.loads(ws_uris)
        if isinstance(uris, list) and uris:
            raw_uri = uris[0]
            decoded = urllib.parse.unquote(raw_uri)
            if decoded.startswith("file:///"):
                local_path = decoded.replace("file:///", "").replace("/", "\\")
                if len(local_path) > 1 and local_path[1] == ':':
                    pass
                else:
                    local_path = decoded.replace("file://", "")
                
                folder_name = os.path.basename(local_path.rstrip("\\/"))
                if not folder_name:
                    folder_name = local_path.rstrip("\\/")
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

def clean_display_content(raw_text):
    if not raw_text:
        return ""
    user_match = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", raw_text, re.DOTALL)
    if user_match:
        return user_match.group(1).strip()
    
    cleaned = re.sub(r"<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>", "", raw_text, flags=re.DOTALL)
    cleaned = re.sub(r"<SYSTEM_MESSAGE>.*?</SYSTEM_MESSAGE>", "", cleaned, flags=re.DOTALL)
    return cleaned.strip()

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

    cmd = []
    if os.path.exists(LANGUAGE_SERVER_EXE):
        cmd = [LANGUAGE_SERVER_EXE, "agentapi", "send-message", target_id, content]
    elif os.path.exists(AGENT_API_PATH):
        cmd = [AGENT_API_PATH, "send-message", target_id, content]
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
                    if msg_type == "GENERIC":
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
    return history

async def tail_transcript():
    global current_active_file, file_handle, current_active_session_id

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

            if file_handle:
                line = file_handle.readline()
                if line:
                    line = line.strip()
                    if line:
                        try:
                            record = json.loads(line)
                            msg_type = record.get("type", "UNKNOWN")
                            if msg_type == "GENERIC":
                                continue

                            raw_content = record.get("content", "")
                            clean_content = clean_display_content(raw_content)
                            thinking = record.get("thinking", "")
                            tool_calls = record.get("tool_calls", [])

                            if not clean_content and not thinking and not tool_calls:
                                continue

                            event = {
                                "type": "agent_update",
                                "session_id": current_active_session_id,
                                "step_index": record.get("step_index"),
                                "source": record.get("source"),
                                "msg_type": msg_type,
                                "status": record.get("status", ""),
                                "content": clean_content,
                                "thinking": thinking,
                                "tool_calls": tool_calls,
                                "timestamp": record.get("created_at")
                            }
                            await broadcast_message(event)
                            print(f"[Push] step={event['step_index']} type={event['msg_type']}")
                        except Exception as e:
                            print(f"[-] JSON 解析异常: {e}")
                else:
                    await asyncio.sleep(0.3)
            else:
                await asyncio.sleep(1)

        except Exception as e:
            await asyncio.sleep(1)

async def websocket_handler(request):
    global current_active_file, file_handle, current_active_session_id, current_workspace_dir

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

        # 1. 握手确认
        await ws.send_json({
            "type": "connected",
            "active_session": current_active_session_id,
            "msg": "Connected to AGY Remote Single-Port Hub!"
        })

        # 2. 会话树
        data_tree = get_grouped_sessions()
        await ws.send_json({
            "type": "session_tree",
            "projects": data_tree["projects"],
            "general_sessions": data_tree["general_sessions"],
            "current": current_active_session_id
        })

        for list_s in data_tree["projects"].values():
            for s in list_s:
                if s["id"] == current_active_session_id and s.get("workspace_path"):
                    current_workspace_dir = s["workspace_path"]
                    break

        # 3. 历史消息（必定立即推送）
        if current_active_file and os.path.exists(current_active_file):
            history = load_session_history(current_active_file, max_lines=40)
            await ws.send_json({
                "type": "session_history",
                "session_id": current_active_session_id,
                "history": history
            })

        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                try:
                    data = json.loads(msg.data)
                    action = data.get("action")

                    # 心跳响应
                    if action == "ping":
                        await ws.send_json({"type": "pong"})

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
                        model = data.get("model", "flash")
                        mode = data.get("mode", "auto")
                        print(f"[*] 请求开启新会话: prompt='{content}', model='{model}', mode='{mode}'")
                        cmd = []
                        if os.path.exists(LANGUAGE_SERVER_EXE):
                            cmd = [LANGUAGE_SERVER_EXE, "agentapi", "new-conversation", f"--model={model}", content]
                        elif os.path.exists(AGENT_API_PATH):
                            cmd = [AGENT_API_PATH, "new-conversation", f"--model={model}", content]
                        if cmd:
                            try:
                                res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=12)
                                await ws.send_json({
                                    "type": "new_session_ack",
                                    "status": "ok" if res.returncode == 0 else "error",
                                    "error": res.stderr.strip() if res.returncode != 0 else ""
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
                return web.FileResponse(index_path)
        return response
    except web.HTTPNotFound:
        index_path = os.path.join(FLUTTER_WEB_DIR, "index.html")
        if os.path.exists(index_path):
            return web.FileResponse(index_path)
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

def init_app():
    app = web.Application(middlewares=[spa_middleware])
    app.router.add_get('/', index_handler)
    app.router.add_get('/ws', websocket_handler)
    app.router.add_get('/test', test_page_handler)
    app.router.add_get('/api/media', media_handler)
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
    web.run_app(app, host="0.0.0.0", port=PORT, access_log=None)
