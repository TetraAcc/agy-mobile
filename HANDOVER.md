# AGY Remote Hub (v2.2.0+5002) 技术架构与交接开发手册

> **版本标识**：`v2.2.0+5002`  
> **更新日期**：2026-11-25  
> **适用对象**：接手本项目维护、扩展客户端或新增受控节点的研发人员

---

## 1. 架构总览

本项目采用三层正交架构，实现手机/平板/浏览器跨网段安全控制多台主机的 Antigravity 会话：

```text
Flutter 三端客户端 (Web / iOS PWA / Android 原生)
   │  HTTPS REST (CRUD / 上传 / 下载 / 文件 / 按轮次 Diff / 配额 / 队列)
   │  WSS /ws/v2/nodes/{node_id}/events (按会话订阅的增量事件流)
   ▼
Edge Gateway (server/agy_hub/gateway/, 默认端口 8768)
   ├── hub.db (SQLite WAL): scrypt 多用户、Refresh 轮换会话、登录防爆破（含回环反代真实 IP 解析）、节点 RBAC
   ├── NodeRegistryManager: 异步 /internal/health 探活，按租户过滤节点视图
   ├── 统一路由反代器: /api/v2/nodes/{node_id}/* 与 /ws/v2/nodes/{node_id}/events
   │   (校验权限后注入 HMAC-SHA256 签名头转发，剥离客户端 Cookie/Authorization；内置高延迟超时/GET 重试与 Content-Length 透传)
   └── 静态前端托管: 自动定位 ../build/web，HTML/bootstrap/manifest/apple-touch-icon/FontManifest 禁缓存，
   │                 MaterialIcons 路径按 SHA-256 版本化防陈旧，static-fonts 与 js 强缓存
   │
   ├──► Node Agent: Deck 本地 (127.0.0.1:8769)
   └──► Node Agent: Windows / 远程主机 (内网 / Tailscale, 默认 8765)
            ├── SessionEventHub: Per-Connection 订阅制 + 无持久化句柄字节偏移追踪
            ├── RootRegistry: 受控 root_id 路径沙箱（保留映射盘符显示路径 _client_paths）+ 敏感黑名单 + 二进制 415 嗅探
            ├── SessionMessageQueueManager: 持久化每会话 FIFO 待发消息队列
            └── EngineProvider:
                  • 官方 conversation_summaries.db 严格只读 (?mode=ro)
                  • WindowsEngineProvider: 异步 Connect-RPC 发消息/打断/配额 + agentapi 新建会话
                  • DeckEngineProvider: 托管子进程组 (PGID) + systemd-run Keyring 配额
```

---

## 2. 关键安全与数据机制

### 2.1 多用户认证与双通道鉴权
- **密码存储**：`server/agy_hub/common/security.py` 使用 Python 标准库 `hashlib.scrypt`（每用户 16B 随机盐）和 `hmac.compare_digest` 校验；拒绝明文或无盐 SHA256。
- **防爆破限流与真实 IP 提取**：`hub.db` 表 `login_attempts` 按 `<ip>:<username>` 记录失败次数，连续失败达到阈值（默认 5 次）返回 HTTP 429 并锁定（默认 900 秒）。`gateway/app.py` 的 `_resolve_client_ip()` 仅在请求来自本机回环反代（`127.0.0.1` / `::1`）时解析 `CF-Connecting-IP` 与 `X-Forwarded-For`，避免不同外网用户共用同机隧道限流桶的同时防止直连伪造头部。
- **令牌双通道**：
  - **Web / iOS PWA**：网关签发 `HttpOnly; SameSite=Lax` Cookie（`agy_access` 作用域 `/`；`agy_refresh` 作用域 `/api/v2/auth`），前端使用 `BrowserHttpClientAdapter(withCredentials: true)` 自动携带。
  - **Android / iOS 原生端**：`Refresh Token` 存入系统安全存储（`FlutterSecureStorage`），请求通过 `Authorization: Bearer <access_token>` 鉴权，遇到 401 时由 `ApiClient` 互斥拦截器自动轮换并重放原请求。
  - **复用检测**：已撤销的 `Refresh Token` 若再次提交刷新，网关立即撤销该用户全部活跃会话。
- **内部通信与签名 Ticket**：
  - 网关向节点发出的全部 HTTP/WS 请求附带 `X-Hub-Timestamp`、`X-Hub-Nonce`、`X-Hub-User`、`X-Hub-Permissions`、`X-Hub-Signature`（允许 60s 时间窗防重放）。
  - 外部下载器、Android `DownloadManager` 与流式媒体播放器使用 `POST /api/v2/nodes/{node_id}/files/ticket` 签发 **600 秒有效、绑定单节点与单文件** 的签名 Ticket。
- **沙箱密钥黑名单**：`common/sandbox.py` 的 `SENSITIVE_PATTERNS` 除常规 `.ssh`、`.env`、`*_config.json`、`hub.db` 外，已显式拦截 `key.properties`、`*.jks`、`*.keystore`、`*.pfx`、`*.p12`。

### 2.2 官方数据库与 Windows 映射驱动器边界
- **只读约定**：`BaseEngineProvider._connect_ro()` 以 `?mode=ro` 只读打开 `conversation_summaries.db`；磁盘已删孤儿会话仅在内存中过滤，归档写入独立 `archive_file`。
- **映射网络驱动器保留（`_client_paths`）**：Windows 下 RaiDrive 等映射盘符（如 `Z:\`）在经过 `Path.resolve()` 后会变成底层 UNC 路径（如 `\\RaiDrive-Tetra\WebDAV\`）。`RootRegistry` 内部仍以 `resolve()` 后的物理路径做沙箱边界判断，同时通过 `_client_paths` 向客户端展示原始盘符路径 `z:\`，保证消息内的 `file:///Z:/...` 链接能正确匹配并下载。
- **真实打断**：
  - Windows：`WindowsEngineProvider.stop_session()` 异步调用 `CancelCascadeInvocation(killBackgroundTasks=true)` 与 `ForceStopCascadeTree`。
  - Deck：`DeckEngineProvider.stop_session()` 对托管子进程组发送 `SIGTERM`（3 秒超时升 `SIGKILL`）。

### 2.3 WebSocket 与按轮次 Diff 契约
- **WS 订阅流**：`WSS /ws/v2/nodes/{node_id}/events`，支持 `subscribe(session_id, since_step?)`、`unsubscribe(session_id)`、`ping`；`SessionEventHub` 每次轮询仅打开检查字节偏移并立即关闭句柄。
- **四维 Diff 提取 (`common/session_diff.py`)**：
  - `GET /agent/sessions/{sid}/changes` 支持 `scope=all|latest_turn`、`step_index` 与 `turn_id` 筛选；
  - 响应内始终附带轻量级 `turns: list[SessionTurnChangeSummary]`，供客户端在每轮对话末尾内嵌 `本轮修改` 卡片，同时顶部/底部悬浮栏聚焦 `最新修改`，评审面板可随时在四档范围间切换。

---

## 3. 客户端关键模块（Flutter & Native）

- **核心层 (`lib/core/`)**：
  - `ServerConfig` / `ComposerPrefs` / `ResponsiveLayout`（平板 `600dp`/`900dp` 断点）
  - `ApiClient` / `NodeEventSocket` / `PlatformBridge` / `AndroidNativeBridge`
  - `AppColors` / `AppFonts` / `FontLoaderService`（4 款按需字体 + 6 套双模式配色）
  - `LatexMathConverter`（在 `MarkdownMessageBody` 渲染前预处理 LaTeX 公式为可读 Unicode，跳过代码块/行内代码/纯货币）
- **原生与 PWA 适配**：
  - **Android Kotlin (`MainActivity.kt` & `AgentStatusService.kt`)**：支持系统 `DownloadManager`（`setAllowedOverRoaming(true)`）、流式 `openRemoteMedia` 拉起系统视频/音频播放器、`FileProvider` 打开本地文件与系统相册、前台运行通知、系统分享接收及相机直拍（已在 `AndroidManifest.xml` `<queries>` 声明 `IMAGE_CAPTURE`）。
  - **iOS PWA (`web/`)**：提供 `180×180` 纯白底 `apple-touch-icon.png`、跟随系统明暗色启动过渡页、`viewport-fit=cover`、`orientation: any` 与 Safari 同手势帧防弹窗拦截打开。

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

### 4.2 部署与更新
- **Windows Node Agent**：按 `agent_config.example.json` 配置 `server/agent_config.json`，运行 `powershell -ExecutionPolicy Bypass -File server\deploy\install_windows_task.ps1` 注册单实例守护计划任务 `AGY_NodeAgent_v2`（对外暴露 Tailscale IP 时传入 `-BindHost <Tailscale_IP>`）。
- **Steam Deck / Linux**：将 `server/deploy/agy-agent-deck.service` 与 `server/deploy/agy-gateway.service` 部署到 `~/.config/systemd/user/` 并启用 `systemctl --user enable --now agy-agent-deck.service agy-gateway.service`。
- **Web / PWA 更新**：根目录执行 `flutter build web --release --no-tree-shake-icons` 后同步 `build/web/` 至网关并重启 `agy-gateway.service`（`main.dart.js` 与字体均带哈希参数击穿缓存）。
- **Android APK 构建**：推送至 GitHub 后在 Actions 运行 `Build Android APK`，流水线默认采用 Secrets 正式签名并按 `5000 + GITHUB_RUN_NUMBER` 自动递增版本号，产出单一 `android-arm64` 安装包。
