# AGY Remote Hub (v2.0.0)

> **Google Antigravity 跨平台多节点远程协同控制中心**  
> 分离式 **Edge Gateway + 无状态 Node Agent** 后端架构与 **Flutter 真三端（Web / Android / iOS）** 客户端，支持多用户长期共存、细粒度节点权限隔离、实时按需事件订阅、受控文件沙箱与安全远程打断。

---

## 核心特性

- **分离式 Gateway + Node Agent 架构**：
  - **Edge Gateway**（FastAPI + SQLite WAL `hub.db`）：统一负责多用户鉴权、RBAC 节点隔离、静态前端托管及 `/api/v2/nodes/{node_id}/*` 与 `/ws/v2/nodes/{node_id}/events` 的透明反向代理。
  - **Node Agent**（无状态 FastAPI 服务）：仅在内网 / Tailscale 监听，不保存任何用户密码或会话凭证，所有请求强制验证网关 HMAC-SHA256 防重放签名头。
- **多用户长期共存与双通道无 URL-Token 鉴权**：
  - 密码采用每用户随机盐 **`scrypt`** 哈希 + 恒定时间比对，内置登录失败限流锁定。
  - 短时效 Access Token + 可撤销/轮换 Refresh Token：Web 端走同源 `HttpOnly; SameSite=Lax` Cookie，Android/iOS 原生端使用 `FlutterSecureStorage` + `Authorization: Bearer`；下载与外链媒体走 60 秒单文件一次性签名 Ticket，彻底消除 URL 明文 Token。
- **Per-Connection 实时事件订阅制**：
  - 废弃全局广播与持久化文件句柄，按 `session_id` 按需增量读取 `transcript.jsonl` 字节偏移并定向推送给对应订阅连接，支持断线自动重连与 `since_step` 补发，多设备并发互不串屏。
- **官方数据库严格只读与真实打断**：
  - 对官方 `conversation_summaries.db` 全程使用 SQLite 只读 URI（`?mode=ro`），孤儿记录与归档操作绝不向官方主库写入 `DELETE`。
  - Windows 端通过异步 Connect-RPC（`SendUserCascadeMessage`、`CancelCascadeInvocation`、`ForceStopCascadeTree`、`RetrieveUserQuotaSummary`）发送、打断与查询配额；Steam Deck 端托管 `agy` 子进程组，支持可靠 `SIGTERM`/`SIGKILL` 停止与可配置权限模式。
- **受控文件沙箱与二进制防呆**：
  - 所有目录浏览、文本预览、图片媒体、Git Diff 与文件下载强制限定在受控 `RootRegistry`（`root_id` + `Path.resolve()` + `is_relative_to()`），结合敏感凭据黑名单与 `\x00` 二进制嗅探（HTTP 415）。
- **Flutter v2.0 真三端前端**：
  - 采用 Riverpod 状态管理与 Dio 401 自动 Refresh 拦截器，去除假打字机定时器与废弃 `dart:js` 桥接，保留 6 套 Catppuccin / Nord 明暗双模式自适应主题与官方真实模型矩阵。
- **桌面级交互与审查**：
  - 支持会话级 Git Diff 与逐行/逐块 Comment 审查（`/changes`、`/git/repos`）、任务进度条（`update_steps` / `update_focus`）、交互式问答卡片（`ask_question`）、点击工具卡片查看完整输入输出（`/tool-output`）、会话产物浏览器（`/artifacts`）、受控文本轻编辑（`PUT /files/content`，带 `mtime` 冲突保护）及对话内搜索。
- **持久化消息队列与通用设置**：
  - 支持每会话 `排队入列 (queue)` / `立即发送 (immediate)` 双模式切换、队列预览/编辑/立即插队/删除（`/queue*`）以及发送键（`Enter` / `Ctrl+Enter`）与主题偏好持久化配置。
- **跨区代理与前端缓存加固**：
  - 内置跨区高延迟代理超时/重试与流式 `Content-Length` 透传，以及 `MaterialIcons-Regular.otf` 路径版本号缓存击穿机制（`FontManifest.json` 禁缓存）。

---

## 目录结构

```text
agy_mobile_app/
├── lib/
│   ├── core/
│   │   ├── config/          # ServerConfig（URL 规范化与持久化）
│   │   ├── network/         # ApiClient（Dio + Refresh 拦截器 + 平台适配器 + TokenStore）
│   │   ├── platform/        # 三端平台桥接（file_picker / url_launcher / package:web 拖拽粘贴）
│   │   ├── realtime/        # NodeEventSocket（WS 订阅、心跳、指数退避重连）
│   │   ├── theme/           # AppColors & Riverpod 主题状态
│   │   └── utils/           # FileUtils 工具类
│   ├── features/
│   │   ├── auth/            # AuthController & 登录页面
│   │   ├── chat/            # 消息卡片、Markdown 渲染、代码块高亮复制、输入栏与上下文菜单
│   │   ├── hub/             # HubController & 主控界面
│   │   ├── sessions/        # 抽屉（节点切换/折叠配额/项目树/搜索）与新建会话弹窗
│   │   └── workspace/       # 受控根目录文件浏览器、文本查看器、Git Diff 审查器
│   ├── models/              # 强类型数据模型（对齐后端 Pydantic schemas）
│   └── main.dart            # 应用入口
├── server/
│   ├── agy_hub/
│   │   ├── common/          # Pydantic 契约、scrypt/HMAC/Ticket、RootRegistry 沙箱、Transcript 解析
│   │   ├── gateway/         # Edge Gateway App、hub.db、AuthService、NodeRegistry、统一反代、管理 CLI
│   │   └── agent/           # Node Agent App、HMAC 验签、SessionEventHub、Windows/Deck Provider
│   ├── deploy/              # systemd 单元模板与 Windows Task Scheduler 注册脚本
│   ├── tests/               # pytest 单元与端到端测试矩阵
│   ├── gateway_config.example.json
│   ├── agent_config.example.json
│   ├── pyproject.toml
│   └── server.py            # 统一 CLI 入口（gateway / agent / user）
├── test/                    # Flutter 单元测试与组件测试
├── web/                     # Flutter Web 模板入口
├── pubspec.yaml             # v2.0.0+20
├── README.md
└── HANDOVER.md
```

---

## 快速上手

### 1. 后端初始化与账号创建

```powershell
cd server
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e ".[dev]"

# 复制占位符配置并填入真实高熵密钥（>= 24 字符）和内网/Tailscale 节点地址
copy gateway_config.example.json gateway_config.json
copy agent_config.example.json agent_config.json

# 创建管理员用户并授予节点权限
.\.venv\Scripts\python.exe server.py user add `
  --db hub.db `
  --username admin `
  --password "YourStrongPassword!123" `
  --role admin `
  --nodes deck windows `
  --default-node windows `
  --allow-delete
```

### 2. 启动后端服务

- **Windows 节点（Node Agent）**：
  ```powershell
  .\server\.venv\Scripts\python.exe server\server.py agent --platform windows --config agent_config.json --host 0.0.0.0 --port 8765
  ```
  后台自启托管请使用 [install_windows_task.ps1](server/deploy/install_windows_task.ps1) 注册计划任务（默认仅监听 `127.0.0.1`；如需供 Tailscale 远端网关访问，调用时请显式传入 `-BindHost <Tailscale_IP>`）。

- **Steam Deck / Linux 入口机（本地 Agent + Edge Gateway）**：
  ```bash
  .venv/bin/python -u server.py agent --platform deck --config agent_config.json --host 127.0.0.1 --port 8769
  .venv/bin/python -u server.py gateway --config gateway_config.json --host 0.0.0.0 --port 8768
  ```
  生产环境请参考 [agy-agent-deck.service](server/deploy/agy-agent-deck.service) 与 [agy-gateway.service](server/deploy/agy-gateway.service)。

### 3. 前端编译与测试验证

```bash
# 获取依赖并静态分析
flutter pub get
flutter analyze

# 运行 Flutter 测试与后端 pytest
flutter test
server/.venv/Scripts/pytest.exe server/tests -v

# 构建 Web 生产产物（Gateway 自动优先挂载 ../build/web）
flutter build web --release
```

### 4. Android APK 云端构建（GitHub Actions）

- 工作流位置：[build-android.yml](.github/workflows/build-android.yml)，支持在 GitHub Actions 页面手动触发（`workflow_dispatch`）或在推送 `v*` 标签时自动构建并发布 Release 附件（含分 ABI APK、通用 APK 与 `SHA256SUMS.txt`）。
- 首次零配置即可直接运行（未配置正式签名时自动回退为 debug 签名方便自测安装）；如需固定正式签名覆盖安装并预填默认网关地址，可在仓库 `Settings -> Secrets and variables -> Actions` 中配置以下可选 Secrets：
  - `ANDROID_KEYSTORE_BASE64`：`.jks` / `.keystore` 文件的 Base64 编码字符串
  - `ANDROID_KEYSTORE_PASSWORD`：Keystore 密码
  - `ANDROID_KEY_ALIAS`：密钥别名
  - `ANDROID_KEY_PASSWORD`：密钥密码
  - `DEFAULT_GATEWAY_URL`：可选，预设原生端默认网关 URL（通过 `--dart-define=DEFAULT_GATEWAY_URL=...` 编译注入）
