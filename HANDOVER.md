# AGY Remote Hub (v2.0.0+20) 技术架构与交接开发手册

> **版本标识**：`v2.0.0+20`  
> **交接日期**：2026-11-23  
> **适用对象**：接手本项目维护、扩展客户端或新增受控节点的研发人员

---

## 1. 架构总览（v2.0 重构核心变更）

v2.0 彻底废弃了 v1.x 的单文件混合服务端（`server_core.py`）、URL 静态明文 Token、全局单会话单例广播、VBS/Watchdog 脚本及 Flutter 伪跨端桥接，拆分为三层正交架构：

```text
Flutter 三端客户端 (Web / Android / iOS)
   │  HTTPS REST (CRUD / 上传 / 下载 / 文件 / Diff / 配额)
   │  WSS /ws/v2/nodes/{node_id}/events (仅会话级实时增量事件流)
   ▼
Edge Gateway (server/agy_hub/gateway/, 默认端口 8768)
   ├── hub.db (SQLite WAL): scrypt 多用户、Refresh 轮换会话、登录防爆破、节点 RBAC
   ├── NodeRegistryManager: 异步 /internal/health 探活，按租户过滤节点视图
   ├── 统一路由反代器: /api/v2/nodes/{node_id}/* 与 /ws/v2/nodes/{node_id}/events
   │   (校验权限后注入 HMAC-SHA256 签名头转发，剥离客户端 Cookie/Authorization；内置高延迟超时/GET 重试与 Content-Length 透传)
   └── 静态前端托管: 自动定位 ../build/web，HTML/bootstrap/FontManifest 禁缓存，MaterialIcons 路径版本化防陈旧，wasm/js 强缓存
   │
   ├──► Node Agent: Deck 本地 (127.0.0.1:8769)
   └──► Node Agent: Windows / 远程主机 (内网 / Tailscale, 默认 8765)
            ├── SessionEventHub: Per-Connection 订阅制 + 无持久化句柄字节偏移追踪
            ├── RootRegistry: 受控 root_id 路径沙箱 + 敏感黑名单 + 二进制 415 嗅探
            └── EngineProvider:
                  • 官方 conversation_summaries.db 严格只读 (?mode=ro)
                  • WindowsEngineProvider: 异步 Connect-RPC 发消息/打断/配额
                  • DeckEngineProvider: 托管子进程组 (PGID) + systemd-run Keyring 配额
```

---

## 2. 关键安全与数据机制

### 2.1 多用户认证与双通道鉴权
- **密码存储**：`server/agy_hub/common/security.py` 使用 Python 标准库 `hashlib.scrypt`（每用户 16B 随机盐）和 `hmac.compare_digest` 校验；拒绝明文或无盐 SHA256。
- **防爆破限流**：`hub.db` 表 `login_attempts` 按 `ip:username` 记录失败次数，连续失败达到阈值（默认 5 次）返回 HTTP 429 并锁定（默认 900 秒）。
- **令牌双通道**：
  - **Web 端**：网关签发 `HttpOnly; SameSite=Lax` Cookie（`agy_access` 作用域 `/`；`agy_refresh` 作用域 `/api/v2/auth`），前端使用 `BrowserHttpClientAdapter(withCredentials: true)` 自动携 Cookie，前端 JS 与存储零接触凭证。
  - **Android / iOS 原生端**：`Refresh Token` 存入系统安全存储（`FlutterSecureStorage`），请求通过 `Authorization: Bearer <access_token>` 鉴权，遇到 401 时由 `ApiClient` 互斥拦截器自动调用 `/api/v2/auth/refresh` 轮换并重放原请求。
  - **复用检测**：已撤销的 `Refresh Token` 若再次被提交刷新，网关立即撤销该用户全部活跃会话。
- **内部通信与文件下载**：
  - 网关向节点发出的全部 HTTP/WS 请求附带 `X-Hub-Timestamp`、`X-Hub-Nonce`、`X-Hub-User`、`X-Hub-Permissions`、`X-Hub-Signature`（允许 60s 时间窗防重放）。
  - 外部浏览器下载或打开原图使用 `POST /api/v2/nodes/{node_id}/files/ticket` 签发 **60 秒有效、绑定单节点与单文件** 的签名 Ticket。
- **配置强制校验**：`GatewayConfig` 与 `AgentConfig` 在加载时校验 `signing_secret` / `internal_secret` 长度至少 24 字符且不含占位符，`allowed_origins` 严禁配置通配符 `*`。

### 2.2 官方数据库与进程边界
- **只读约定**：`BaseEngineProvider._connect_ro()` 以 `?mode=ro` 只读打开 `conversation_summaries.db`；磁盘已删的孤儿会话仅在内存中过滤。归档删除（`DELETE /agent/sessions/{sid}`）写入独立 `archive_file` 清单，不会向官方 SQLite 主库写 `DELETE`。
- **子代理与工程分组**：过滤 `parent_conversation_id`、`nesting_depth`、`agent_name`，结合 `conversations_fts`、`project_id` 与 `workspace_uris`（兼容 `Z:\` 等 Windows 盘符根）对齐桌面端分组与排序。
- **真实打断**：
  - Windows：`WindowsEngineProvider.stop_session()` 异步调用 `CancelCascadeInvocation(killBackgroundTasks=true)` 与 `ForceStopCascadeTree`。
  - Deck：`DeckEngineProvider.stop_session()` 对托管子进程组发送 `SIGTERM`（3 秒超时升 `SIGKILL`）。

### 2.3 WebSocket 实时事件契约
- 连接端点：`WSS /ws/v2/nodes/{node_id}/events`
- 客户端控制帧：`subscribe(session_id, since_step?)`、`unsubscribe(session_id)`、`ping`
- 服务端推送帧：`step_upsert`、`session_status`、`session_tree_changed`、`node_status`、`pong`、`error`
- `SessionEventHub` 每次轮询仅打开检查字节偏移并立即关闭句柄，且仅读取完整 `\n` 结尾的行，消除跨会话串屏、半行 JSON 报错与 `NoneType.readline` 崩溃。

### 2.4 新增桌面级对等接口与高延迟反代加固
- **代码审查、产物与轻量编辑**：新增 `/agent/sessions/{sid}/changes`、`/agent/sessions/{sid}/artifacts`、`/agent/sessions/{sid}/steps/{step_index}/tool-output`、`/agent/git/repos` 及 `PUT /agent/files/content`（校验受控沙箱与文件 `mtime`，冲突返回 409）。
- **持久化消息队列**：新增 `/agent/sessions/{sid}/queue*`（支持 `GET`/`POST`/`PUT`/`DELETE` 与 `send-now` 插队发送），支持每会话 `queue`（排队入列）与 `immediate`（立即发送）双模式。
- **跨区高延迟代理与缓存控制**：Gateway 对 HTTP 代理采用长连接读超时、针对 `RemoteProtocolError`/`ConnectTimeout` 的 GET 单次重试以及非压缩响应 `Content-Length` 透传；静态资源托管对 `FontManifest.json` 禁用缓存并将 `MaterialIcons-Regular.otf` 动态改写为带 SHA-256 摘要的 `assets/fonts/v_<sha256[:12]>/MaterialIcons-Regular.otf` 路径，防止 CDN/浏览器命中旧版树摇字体文件。

---

## 3. 前端关键架构与预置模型

- **核心层 (`lib/core/`)**：`ServerConfig`、`TokenStore`、`ApiClient`、`NodeEventSocket`、`PlatformBridge`（基于 `file_picker`、`url_launcher`、`package:web`）、`AppColors`、`FileUtils`。
- **模型层 (`lib/models/`)**：全部对齐后端 Pydantic snake_case 契约（如 `QuotaBucket.remaining_fraction`、`ToolCallItem.args`、`SessionItem.is_pinned` 与 `root_id`）。
- **预置模型矩阵 (`lib/models/official_model.dart`)**：
  - `gemini-3.8-flash-high` / `gemini-3.8-flash-medium` / `gemini-3.8-flash-low`
  - `claude-sonnet-4-6` / `claude-opus-4-6-thinking`
  - `gpt-oss-120b-medium` / `gemini-2.5-pro`
- **交互简化与桌面级工作流**：已移除基于 `Timer` 模拟的假打字机效果，`MarkdownMessageBody` 直接渲染高亮代码块与带认证头的代理图片；新增 `SessionChangesBar` / `ChangeReviewSheet`（CJK 行内对比与 Comment 审查）、`SessionStepsBar`、`SessionArtifactsSheet`、`ToolDetailSheet`、`SessionQueueBar`、`ComposerPrefs`、通用设置弹窗，以及支持明暗双模式自适应的 Catppuccin / Nord 主题调色板。

---

## 4. 运维与账号管理常用命令

### 4.1 账号与权限治理 (`server/server.py user`)
```bash
# 新增成员（可写但禁止删除会话）
python server.py user add --db hub.db --username alice --password "StrongPassword!1" --nodes deck --default-node deck

# 赋予/收回节点权限
python server.py user grant --db hub.db --username alice --node windows --allow-delete
python server.py user revoke --db hub.db --username alice --node windows

# 踢出用户全部设备会话 / 禁用 / 重置密码 / 查看列表
python server.py user kick --db hub.db --username alice
python server.py user disable --db hub.db --username alice
python server.py user passwd --db hub.db --username alice --password "NewStrongPassword!2"
python server.py user list --db hub.db
```

### 4.2 部署与托管
- **Windows**：先按 `agent_config.example.json` 建好 `server/agent_config.json`，运行 `powershell -ExecutionPolicy Bypass -File server\deploy\install_windows_task.ps1` 注册计划任务（自带崩溃重启与 `PYTHONIOENCODING=utf-8`；脚本默认绑定 `127.0.0.1`，如需向远端 Gateway 暴露请显式传入 `-BindHost <Tailscale_IP>`）。
- **Steam Deck / Linux**：将 `server/deploy/agy-agent-deck.service` 与 `server/deploy/agy-gateway.service` 复制到 `~/.config/systemd/user/` 并启用 `systemctl --user enable --now agy-agent-deck.service agy-gateway.service`。
- **Web 前端更新**：在项目根目录执行 `flutter build web --release` 后，直接把 `build/web/` 同步至网关部署目录或由同机 Gateway 直接加载 `../build/web`。

---

## 5. 接手人员后续演进建议

1. **Android / iOS 正式签名与发布配置**：当前已按真三端插件完成接口适配与单元测试验证，正式打包 APK/IPA 前需在目标构建机配置好 Android SDK / Xcode 及正式应用签名证书（并替换 `android/app/build.gradle.kts` 中的 debug 签名配置）。
2. **线上代理反向 HTTPS 强制校验**：对外网提供服务时务必保持 `gateway_config.json` 中 `cookie_secure: true`，并通过 Cloudflare Tunnel / Caddy / Nginx 终止 TLS。
3. **管理员 Web 控制台**：后端已提供 `/api/v2/admin/users` 全套管理接口，后续如有需要可直接在 Flutter 侧边栏追加管理员用户管理弹窗。
