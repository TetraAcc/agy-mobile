# AGY Remote Hub (v2.2.0)

> **Google Antigravity 跨平台多节点远程协同控制中心**  
> 分离式 **Edge Gateway + 无状态 Node Agent** 后端架构与 **Flutter 三端（Web / iOS PWA / Android 原生）** 客户端，支持多用户长期共存、细粒度节点权限隔离、实时按需事件订阅、四维 Diff 审查、受控文件沙箱与安全远程打断。

---

## 核心特性

### 1. 分离式网关与零信任节点架构
- **Edge Gateway**（FastAPI + SQLite WAL `hub.db`）：统一负责多用户鉴权、RBAC 节点隔离、静态前端托管（Web / PWA），以及 `/api/v2/nodes/{node_id}/*` 与 `/ws/v2/nodes/{node_id}/events` 的透明反向代理。
- **Node Agent**（无状态 FastAPI 服务）：仅在内网 / Tailscale 监听，不保存任何用户密码或会话凭证，所有请求强制验证网关 HMAC-SHA256 60 秒防重放签名头。
- **反代限流安全**：支持在本地反向代理（如 Cloudflare Tunnel `127.0.0.1`）后安全解析 `CF-Connecting-IP` / `X-Forwarded-For` 作为登录失败计数键，同时拒绝直连请求伪造转发头绕过限流。

### 2. 多用户认证、双通道会话与单文件签名 Ticket
- 密码采用每用户随机盐 **`scrypt`** 哈希 + `hmac.compare_digest` 恒定时间比对，内置登录失败限流锁定。
- 短时效 Access Token + 可撤销 / 轮换 Refresh Token（含复用检测并吊销全会话）：Web 端走同源 `HttpOnly; SameSite=Lax` Cookie，原生端使用 `FlutterSecureStorage` + `Authorization: Bearer`。
- 下载与流式外链走 **600 秒**（10 分钟）单节点单文件一次性签名 Ticket，彻底消除 URL 明文 Token。

### 3. Per-Connection 实时订阅与官方库只读边界
- **按需增量事件流**：`SessionEventHub` 按连接订阅的 `session_id` 增量追踪 `transcript.jsonl` 字节偏移，不长期持有文件句柄，支持断线自动重连与 `since_step` 补发，多设备并发互不串屏。
- **严格只读官方 DB**：对官方 `conversation_summaries.db` 全程使用 SQLite 只读 URI（`?mode=ro`）；归档与删除仅写独立 `archive_file`，绝不破坏官方主库。
- **双平台真实控制**：Windows 端通过异步 Connect-RPC 与 `language_server` 交互，Steam Deck 端托管 `agy` 子进程组（PGID）并支持 `SIGTERM` / `SIGKILL` 可靠打断。
- **智能默认会话与项目呼吸灯**：进入应用或切换节点时优先自动打开正在运行的对话；若无运行中会话，则按最近修改时间打开最活跃的对话；侧边栏折叠项目标题旁支持实时绿色呼吸灯（及多并发数量角标）直观提示运行中任务，并在重连、切回前台与切换节点时自动重探节点在线状态。

### 4. 四维 Diff 体系与桌面级协同审查
- **对话流每轮内嵌 Diff**：在每轮产出文件修改的 AI 回复末尾自动挂载 `本轮修改` 可展开卡片，直观还原桌面端按轮次追踪改动体验；
- **底部常驻最新修改栏**：输入框上方悬浮 `最新修改` 条，无需上翻聊天记录即可一键展开刚才的修改；
- **单步工具胶囊跳转**：点击消息内的 `edit: ...` / `write: ...` 胶囊，直接定位到该单步（`单步 #N`）的变更详情；
- **全量变更与多仓库 Git 审查**：`+` 号菜单进入 `ChangeReviewSheet`，支持在 `单步 #N` / `本轮修改` / `最新修改` / `全部修改` 四档范围间自由切换，提供 CJK 句词级行内对比、逐段批注组装以及本地 Git 仓库 `uncommitted / HEAD` Diff。
- **配套工作区能力**：受控文本轻编辑（带 `mtime` 并发冲突 409 保护）、持久化每会话消息队列（`queue` / `immediate` 双模式、插队与暂停）、任务进度条（`update_steps` / `update_focus`）、交互式 `ask_question` 卡片、工具完整输入输出查看及会话产物浏览器（`/artifacts`）。

### 5. 受控文件沙箱与 Windows 映射驱动器兼容
- 所有目录浏览、文本读写、流式媒体与 Git 探针强制限定在 `RootRegistry`（`root_id` + 敏感黑名单 + `\x00` 二进制 415 嗅探），严禁访问凭据、数据库与签名密钥（`.env`、`.ssh`、`key.properties`、`*.jks` 等）。
- **映射网络驱动器原生兼容**：针对 Windows 下 RaiDrive 等 WebDAV/网络映射盘符（如 `Z:\`），在暴露给客户端的工作区根目录清单中保留原始盘符路径（`_client_paths`），同时在服务端内部安全映射到实际物理路径，解决点击链接匹配失败的问题。

### 6. 全平台客户端打磨（Android 原生 / 平板 / iOS PWA / Web）
- **Android 原生深度集成**：
  - 系统 `DownloadManager` 托管下载（支持漫游网络与通知栏实时进度，文件直接落入公共 `Downloads`）；
  - 工作区音视频免预缓存直接通过签名流 URI 拉起手机系统播放器（`openRemoteMedia`），图片应用内秒开缩放预览并支持右上角一键拉起系统相册；
  - 前台运行状态常驻通知（`AgentStatusService`）与后台完成 / `ask_question` 震动提醒；
  - 接收外部 App 系统分享内容（`SEND` / `SEND_MULTIPLE`）与系统相机拍照直传。
- **Android 平板与宽屏响应式布局**：`>= 900dp` 启用可折叠常驻左侧边栏（`296px`）、`840px` 居中阅读列、`1080px` 工作区底部弹窗约束及横屏软键盘紧凑输入模式。
- **iOS PWA 专属优化**：`180×180` 24-bit 纯白底主屏幕高清图标（`apple-touch-icon.png`）、随系统明暗色切换的启动过渡屏、`viewport-fit=cover` 刘海/灵动岛安全区适配、Safari 同手势帧防弹窗拦截及 iPhone SE3 (`375px`) 窄屏防溢出保护。
- **排版与数学渲染**：内置 `LatexMathConverter` 自动将行内（`$...$`、`\( ... \)`）与块级（`$$...$$`、`\[ ... \]`）LaTeX 数学公式转译为清晰 Unicode 数学符号并跳过代码块与货币数字；提供 4 款自托管按需加载字体与 6 套 Catppuccin / Nord 明暗主题。

---

## 目录结构

```text
agy_mobile_app/
├── .github/workflows/
│   └── build-android.yml          # GitHub Actions 单架构 (arm64) 正式签名 APK 自动构建流水线
├── android/                       # Android 原生工程（Kotlin 桥接、前台通知服务、FileProvider、自适应图标）
├── ios/                           # iOS 工程与 AppIcon 图集
├── lib/
│   ├── core/
│   │   ├── config/                # ServerConfig、ComposerPrefs、ResponsiveLayout 断点约束
│   │   ├── network/               # ApiClient（Dio + 401 Refresh 拦截器 + Ticket）、TokenStore、双端适配器
│   │   ├── platform/              # PlatformBridge（Web/IO）与 AndroidNativeBridge（下载器/流媒体/通知/相机/分享）
│   │   ├── realtime/              # NodeEventSocket（WS 订阅、心跳、指数退避重连）
│   │   ├── theme/                 # AppColors、AppFonts、FontLoaderService 与 ThemeProvider
│   │   └── utils/                 # FileUtils、LatexMathConverter（LaTeX 数学公式转 Unicode）
│   ├── features/
│   │   ├── auth/                  # AuthController & 登录页面
│   │   ├── chat/                  # MessageCard、MarkdownMessageBody、代码高亮块、BottomInputBar、队列与步骤栏
│   │   ├── hub/                   # HubController、HomeScreen、下载进度弹窗
│   │   ├── sessions/              # QuotaDrawer（置顶/搜索/折叠配额/项目树）与新建会话弹窗
│   │   └── workspace/             # WorkspaceFilePicker、FileViewerSheet、ChangeReviewSheet、Artifacts 与工具详情
│   ├── models/                    # 强类型模型（对齐后端 Pydantic schemas）
│   └── main.dart                  # 应用入口（edgeToEdge 与主题注入）
├── server/
│   ├── agy_hub/
│   │   ├── __init__.py            # 统一后端版本号（2.1.2）
│   │   ├── common/                # Schemas、scrypt/HMAC/Ticket、RootRegistry 沙箱、按轮次 Diff、产物检索与 Transcript 解析
│   │   ├── gateway/               # Edge Gateway App、hub.db、AuthService（含反代 IP 提取）、NodeRegistry、反代、CLI
│   │   └── agent/                 # Node Agent App、HMAC 验签、SessionEventHub、消息队列、Windows/Deck Provider
│   ├── deploy/                    # systemd 单元模板与 Windows Task Scheduler 注册脚本
│   ├── tests/                     # pytest 单元与端到端测试套件（10 个测试模块）
│   ├── gateway_config.example.json
│   ├── agent_config.example.json
│   ├── pyproject.toml
│   └── server.py                  # 统一 CLI 入口（gateway / agent / user）
├── test/                          # Flutter 单元与组件测试套件（4 个测试文件）
├── web/                           # Web / iOS PWA 入口（apple-touch-icon、自适应启动页、manifest.json）
├── pubspec.yaml                   # Flutter 工程配置（v2.1.2+5000）
├── README.md
├── CHANGELOG.md
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
  后台自启托管请使用 [install_windows_task.ps1](server/deploy/install_windows_task.ps1) 注册计划任务（默认仅监听 `127.0.0.1`；如需供 Tailscale 远端网关访问，调用时显式传入 `-BindHost <Tailscale_IP>`）。

- **Steam Deck / Linux 入口机（本地 Agent + Edge Gateway）**：
  ```bash
  .venv/bin/python -u server.py agent --platform deck --config agent_config.json --host 127.0.0.1 --port 8769
  .venv/bin/python -u server.py gateway --config gateway_config.json --host 0.0.0.0 --port 8768
  ```
  生产环境请参考 [agy-agent-deck.service](server/deploy/agy-agent-deck.service) 与 [agy-gateway.service](server/deploy/agy-gateway.service)。

### 3. 前端编译与测试验证

```powershell
# 获取依赖并静态分析
flutter pub get
flutter analyze --no-fatal-infos

# 运行 Flutter 全量测试与后端 pytest
flutter test
.\server\.venv\Scripts\pytest.exe server\tests -v

# 构建 Web / PWA 生产产物（Gateway 自动优先挂载 ../build/web）
flutter build web --release --no-tree-shake-icons
```

### 4. Android APK 云端构建（GitHub Actions）

- 工作流位置：[build-android.yml](.github/workflows/build-android.yml)，支持在 GitHub Actions 页面一键触发（`workflow_dispatch`）或推送 `v*` 标签自动发布 Release，仅编译现代设备适用的单一 **`android-arm64`** 正式 APK（输出 `agy-remote-v2.1.2-bXXXX.apk` 与 `SHA256SUMS.txt`），构建号按 `5000 + GITHUB_RUN_NUMBER` 自动递增以确保可无损覆盖升级。
- 仓库 `Settings -> Secrets and variables -> Actions` 可选配置：
  - `ANDROID_KEYSTORE_BASE64`：`.jks` / `.keystore` 文件的 Base64 编码字符串
  - `ANDROID_KEYSTORE_PASSWORD`：Keystore 密码
  - `ANDROID_KEY_ALIAS`：密钥别名
  - `ANDROID_KEY_PASSWORD`：密钥密码
  - `DEFAULT_GATEWAY_URL`：可选，预设原生端默认网关 URL（通过 `--dart-define=DEFAULT_GATEWAY_URL=...` 编译注入）
