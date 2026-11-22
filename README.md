# AGY Mobile & Remote Hub 🚀

> **Google Antigravity 跨平台轻量级远程协同中心 & 多租户双机网关**  
> 一套免客户端安装、单端口同源、支持多租户设备物理隔离的 Web / Mobile 伴侣应用。支持在统一公网域名下智能透明反代并实时控制 **Steam Deck (24h低功耗常驻网关)**、**Windows PC (主力开发机)** 以及 **专属电脑节点**。

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Python](https://img.shields.io/badge/Python-3.10+-3776AB?logo=python)](https://python.org)
[![Version](https://img.shields.io/badge/Version-v1.3.5-brightgreen.svg)](https://github.com/TetraAcc/agy-mobile)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-13%2F13%20Passed-success.svg)](test/widget_test.dart)

---

## 🌟 核心特性

- 📱 **侧边栏配额卡片智能折叠与会话列表大视口释放 (v1.3.5 新增)**：
  - **手机端竖屏挤压痛点彻底根治**：将原本占用 ~200px 纵向高度的静态固定配额面板改造为**轻量折叠手风琴卡片**，默认在移动端紧凑折叠；
  - **极简胶囊摘要栏（Compact Capsule Bar）**：折叠时高度仅 ~32px，一行自适应展示 `⚡ 额度: Gemini 76.9% · Claude 100%` 关键剩余百分比徽章与独立刷新按钮；
  - **平滑手风琴动效**：轻触即可展开完整的周额度与 5 小时滑动进度条及重置倒计时，再次轻触即可收起；
  - **抽屉全局垂直布局精简**：优化主机选择器、操作按钮和搜索栏内边距，并将夜间模式与版本号整合为一行，为中央会话列表累计释放超 200px 垂直浏览视口，手机翻看和切换会话极度从容。
- 🖼️ **Agent 回复 Markdown 本地图片双端透明代理与交互式全屏预览 (v1.3.4 新增)**：
  - **破解 Web 端图片跨域沙箱限制**：在 Web 网页端彻底解决 Agent 回复 Markdown 中 `file:///...` 本地协议图片无法显示、直接破图的顽疾；
  - **双端智能路径清洗与反代**：`StreamingMarkdownBody` 内置 `imageBuilder` 代理拦截，将本地绝对路径与 `file://` 协议自动转换为网关及 Windows 的 `/api/media?path=...&token=...&node=...` 接口；
  - **交互式全屏 Lightbox 弹窗**：点击图片即刻唤起全屏半透明模态框，支持 `InteractiveViewer` 无级平移缩放、滚轮缩放、原图独立标签页打开及一键下载查看，方便阅读长图与架构细节；
  - **加载状态平滑兜底**：配备优雅的加载菊花指示与失败友好的容错卡片。
- 🔍 **侧边栏会话实时搜索过滤 (v1.3.3 新增)**：
  - 侧边栏“+ 新建会话”正下方集成微型实时搜索栏；
  - 毫秒级模糊匹配**会话标题、所属工程名称与文本内容**，并附带项目徽标；右侧支持一键清空 `[×]`。
- ⚡ **消息流式打字机逐字渲染 & 完结记忆锁定 (v1.3.3 新增)**：
  - Agent 输出时不再是一大段突兀刷新，而是带有类似 ChatGPT/Claude 的自然打字机逐字吐字动效与呼吸光标；
  - **四重排他锁定**：通过 `isLatest` 物理位置锁定、全局完结指纹记忆库（`_globallyFinishedKeys`）与历史加载全量预置，严格限定**仅当前会话最顶部的第 0 条最新消息**允许打字，彻底杜绝历史旧消息被重复打字重载；支持点击卡片立即跳过。
- 🖥️ **代码块一体化沉浸终端底色 (v1.3.3 优化)**：
  - 剥离第三方高亮组件自带的死灰色窄块补丁，通过 `LayoutBuilder` 结合 `ConstrainedBox` 强制 100% 满宽平铺；
  - 采用现代微冷终端底色（`#0B101D`）与精致微边框，消除任何视觉割裂感。
- 🛡️ **Windows 本地自愈看门狗 (Watchdog) & WebSocket 防爆沙箱 (v1.3.3 增强)**：
  - 新增 `watchdog_windows.py`，主服务意外闪退或休眠唤醒后 1.5 秒内自动清理端口并自愈拉起；
  - WebSocket 握手阶段各子模块（会话树、历史记录、额度、节点探测）全部解耦为独立安全沙箱，单模块偶发异常绝不断联。
- 🎨 **多套护眼强调色主题系统 (v1.3.0 新增)**：
  - 彻底解决深色模式下亮蓝强调色刺眼对眼睛不友好的问题；
  - 侧边栏底部提供专属色板选择器，开箱提供 **翡翠绿 (护眼极客)**、**青竹绿 (北欧温润)**、**紫罗兰 (温和沉浸)**、**暖琥珀 (夜间暖光)** 与 **科技蓝 (经典)** 5 大低饱和护眼主题；
  - 全局色彩平滑联动并自动持久化，无论主按钮、激活指示、边框或图标均柔和护眼。
- 📋 **代码块语法高亮与一键复制 (v1.3.0 新增)**：
  - 深度集成 `flutter_highlight`，完美匹配多语言（Python, Dart, Shell, C, JavaScript, JSON 等）语法着色；
  - 每个代码块顶部配备专属暗色操作栏，标注大写语言标签，并提供**一键复制**功能（附带防抖与绿色 `✓ 已复制` 动效反馈）。
- ⚓ **智能滚动控制与“↓ 回到底部”悬浮药丸 (v1.3.0 新增)**：
  - 监听视口行程：当用户向上翻看历史消息时（`offset > 120`），新消息涌入**坚决不强制拉回底部**；
  - 右下角智能浮现精致的 **`↓ 回到底部`** 悬浮药丸，点击丝滑平滑回弹到底部，自然滑到底部时自动消隐。
- 🗺️ **WebSocket 消息协议 Map 化路由调度 & 60s 配额自动巡检 (v1.3.0 新增)**：
  - 废弃长达数百行的 `if-else if` 巨石消息链，下沉为结构清爽的 Handler Map 注册表，扩展极度便利；
  - 连接时自动巡检配额，并常驻 60 秒定时静默拉取，无需频繁手动点击刷新。
- 📁 **项目内一键新建会话与智能工作区绑定 (v1.2.1 新增)**：
  - 侧边栏项目列表每一项标题右侧均提供一键 `+` 加号按钮，直接在此项目内开启新会话；
  - “开启全新会话”弹窗新增“所属项目 / 关联工作区”下拉选单，支持在“🌐 通用任务 (无项目绑定)”与“📁 具体项目”间随时无缝切换；
  - 服务端底座自动将底层 `language_server.exe agentapi new-conversation` 执行工作目录 (`cwd`) 设置为目标工程物理路径，Antigravity 天然将新任务准确归属于该项目。
- 🌐 **全跨平台免客户端安装**：基于 Flutter 3 编译为高性能 Web 应用，手机 Safari/Chrome、平板、电脑浏览器打开即用，PWA 即刻安装到桌面。
- 🔄 **会话级执行状态与消息流物理隔离 (v1.2.2 增强)**：
  - 各个 Session 的运行/停止状态完全独立追踪，告别“全局停止按钮”设计缺陷；
  - **静默超时自动复位 (v1.2.2)**：服务端引入 2.5 秒日志无写入自动归位机制，若会话长时间无新步骤，后端自动向前端同步空闲态，杜绝假死悬挂；
  - **历史记录倒序校准 (v1.2.2)**：修正前端历史记录升序读取逻辑，严格以权威最新 step 判定运行态，彻底根除“无任务仍显示在运行”的假态问题；
  - 某个后台会话运行时，其他会话底部正常显示发送箭头，互不干扰；
  - 侧边栏抽屉带微型旋转动画与红色的 **`[运行中]`** 动态标签，哪个后台任务在跑一目了然；
  - 消息流精确过滤，绝不发生跨会话实时打字串屏。
- 🧱 **全模块化低耦合架构 (v1.2.0 新增)**：
  - 告别单文件 3700 行巨石代码，下沉为 8 大高内聚独立 UI 组件；
  - 抽离 `lib/utils/file_utils.dart`、`lib/models/`（7 大数据模型）与 `lib/constants/app_colors.dart`；
  - 代码清晰直观，开箱即拥有 13 项完整的单元测试矩阵。
- 🛡️ **生产级安全防御加固**：
  - **凭据外部化**：口令 Token 与内网机器 IP 完全迁移至本地 `server_config.json`，受 `.gitignore` 严格保护；
  - **路径遍历防御**：下载与媒体接口全面采用 `os.path.realpath` 规范化校验，结合根目录白名单并坚决阻断 `.ssh`、`id_rsa`、`.env` 等敏感文件，越权返回 403 Forbidden；
  - **收紧 CORS 跨域**：动态校验 `Origin` 请求头，拒绝全开放通配符 `*`。
- 🔑 **多租户设备与权限物理隔离**：
  - 基于 URL Token 自动鉴权（如 `?token=tetra2026` 控制主力机与 Deck，`?token=simeng` 仅看到并控制专属电脑）；
  - 物理级列表屏蔽与隔离路由，彼此不可见其他节点、项目或会话；
  - 自动持久化至本地存储，免去繁琐输入。
- 🎮 **双机/多机智能网关与透明反代**：
  - **Steam Deck** 作为低功耗 24 小时在线网关（通过 `cloudflared` 绑定顶级域名）；
  - 顶栏一键切换控制主机，Deck 边缘根据用户权限透明反向代理目标宿主机（支持 LAN IP 与 Tailscale 虚拟局域网），宿主机无需暴露于公网。
- 📊 **官方底层 Connect-RPC 真实配额监控**：
  - 直连 Antigravity 后台 `LanguageServerService/RetrieveUserQuotaSummary`；
  - 抽屉侧边栏实时渲染 Gemini 系列（周额度 + 5 小时滑动窗口）及 Claude / GPT 模型的真实官方消耗进度条。
- ⚡ **真实模型矩阵与思考分级（Thinking Budget）**：
  - 废弃伪造模型标签，全面对齐官方真实模型：`Gemini 3.8 Flash (High/Medium/Low)`、`Claude Sonnet 4.6`、`Claude Opus 4.6 (Thinking)`、`GPT-OSS 120B`、`Gemini 2.5 Pro` 等；
  - 新建会话弹窗与底部快捷切换均支持官方思考预算级别调整。
- 🛑 **真全双工底层打断 (Stop) 与斜杠指令**：
  - 运行时实时显示【🛑 停止】按钮，直接通过 RPC `CancelCascadeTask` 发送底层打断信号，支持全速中断输出；
  - 原生悬浮补全 `/goal`、`/plan`、`/compact`、`/browser` 等官方核心斜杠指令。
- 📦 **全双工流式下载与防排版死锁保护**：
  - 消息附件与工作区文件浏览器支持 `/api/download` 流式下载通道，浏览器端直接拉起原生下载；
  - 前端扩展名识别 + 后端空字节 `\x00` 嗅探双重防御，彻底杜绝 CanvasKit 渲染二进制文件（`.zip`, `.exe`, `.pdf` 等）时发生的排版引擎假死崩溃。
- 📋 **多模态与图片秒级粘贴 (`Ctrl + V`)**：
  - 支持直接在输入框按 `Ctrl + V` 粘贴剪贴板截图，或将文件直接拖入页面；
  - 自动存入底层 `.user_uploaded` 会话目录并展示缩略图预览胶囊，发送时随消息提交给 Agent；
  - 包含工作区文件树直接浏览查看、Git 变更全屏 Diff 对比审查等进阶面板。

---

## 🏗️ 架构拓扑

```mermaid
flowchart TD
    Client["📱 移动端 / 💻 浏览器 (https://agy.your-domain.com?token=xxx)"]
    CF["☁️ Cloudflare Zero Trust (Tunnel)"]
    DeckGateway["🎮 Steam Deck 多租户边缘网关 (Port 8768)\n• aiohttp 静态托管 (Flutter Web 产物)\n• 多租户隔离路由 & WebSocket/HTTP 反向代理\n• 24h 常驻值守 (agy-remote.service)"]
    WinHost["💻 Windows 主力开发机 (Port 8765)\n• aiohttp 后台服务 (server_windows.py)\n• Antigravity AgentAPI & Brain / RPC 配额监听\n• 局域网反代 (LAN IP / Tailscale IP)"]
    GFHost["💻 专属隔离主机 (例如女友 PC)\n• 独立口令访问 (如 token=simeng)\n• Tailscale 虚拟局域网反代 (100.x.x.x:8765)\n• 物理隔离其他设备列表"]

    Client -->|HTTPS / WSS| CF
    CF -->|localhost:8768| DeckGateway
    DeckGateway -->|Target = Deck (本地)| DeckGateway
    DeckGateway -->|Target = Windows (LAN/Tailscale反代)| WinHost
    DeckGateway -->|Target = Li / 隔离节点 (Tailscale反代)| GFHost
```

---

## 📂 项目结构

```text
agy-mobile/
├── lib/
│   ├── main.dart                          # 顶层 App 生命周期、WebSocket 分发与 Scaffold 装配
│   ├── constants/
│   │   └── app_colors.dart                # 全站十六进制统一调色板
│   ├── models/                            # 7 大独立核心数据模型
│   │   ├── agent_message.dart             # 消息结构、标签清洗与纯工具判断
│   │   ├── session_item.dart              # 会话结构与项目分组
│   │   ├── host_node.dart                 # 控制主机节点在线状态
│   │   ├── file_item.dart                 # 工作区文件项
│   │   ├── models.dart                    # Barrel 统一导出
│   │   └── ...
│   ├── utils/
│   │   └── file_utils.dart                # 二进制识别、路径清洗、图标色彩与工具解析
│   ├── widgets/                           # 8 大解耦独立 UI 组件
│   │   ├── quota_drawer.dart              # 侧边栏抽屉与底座配额卡片
│   │   ├── message_card.dart              # 聊天卡片、思考折叠、Markdown 与下载卡片
│   │   ├── bottom_input_bar.dart          # 底部输入框与发送/停止切换
│   │   ├── file_viewer_sheet.dart         # 纯文本全文带行号查看器
│   │   ├── workspace_file_picker_dialog.dart # 工程目录树浏览与拾取
│   │   ├── context_menu_sheet.dart        # 添加上下文与快捷操作菜单
│   │   ├── git_diff_viewer_sheet.dart     # Git 变更 Diff 对比审查器
│   │   ├── new_session_dialog.dart        # 新建任务弹窗与思考分级
│   │   ├── slash_command_menu.dart        # 斜杠指令自动补全悬浮卡片
│   │   ├── attachment_preview_bar.dart    # 待上传附件预览胶囊条
│   │   └── widgets.dart                   # Barrel 统一导出
│   └── bridge/                            # 条件编译跨平台桥接 (Web / Non-Web)
├── server/
│   ├── server_windows.py                  # Windows 主力机服务端
│   ├── server_deck.py                     # Steam Deck 多租户边缘网关
│   ├── server_common.py                   # 共享核心逻辑 (路径安全白名单、CORS头、消息清洗)
│   ├── server_config.example.json         # 外部化配置模板 (Token、IP、白名单)
│   └── agy-remote.service                 # SteamOS systemd 守护进程
├── test/
│   └── widget_test.dart                   # 13 项全量业务单元测试 (模型矩阵/清洗/安全/工具)
├── web/
│   └── index.html                         # 原生粘贴与剪贴板桥接注入
├── pubspec.yaml                           # Flutter 配置 (v1.2.0)
└── README.md                              # 项目说明文档
```

---

## 🚀 快速上手

### 1. 本地单元测试验证

```bash
flutter test
# 预期输出: All tests passed! (13/13)
```

### 2. 前端编译与生产构建 (Flutter Web)

```bash
# 获取依赖
flutter pub get

# 生产级构建 (自动树摇优化)
flutter build web --release

# 同步部署至网关机 (例如 Steam Deck)
scp -r build/web/* deck@<DECK_IP>:/home/deck/agy_remote/web/
```

### 3. Steam Deck 网关部署

1. 配置文件就绪：
   ```bash
   cp server/server_config.example.json ~/agy_remote/server_config.json
   # 修改 server_config.json 填入真实口令与目标机 IP
   ```
2. 安装 Systemd 用户级守护进程：
   ```bash
   cp server/agy-remote.service ~/.config/systemd/user/agy-remote.service
   systemctl --user daemon-reload
   systemctl --user enable --now agy-remote.service
   loginctl enable-linger deck
   ```

### 4. Windows 客户端部署

1. 配置文件就绪：
   ```bash
   cp server/server_config.example.json server/server_config.json
   ```
2. 启动 Windows 桥接服务：
   ```bash
   python server/server_windows.py
   ```

### 5. 公网域名访问

通过 Cloudflare Tunnel 绑定网关机器端口（8768）：
👉 **`https://agy.your-domain.com/?token=your_auth_token`**

---

## 📄 License

MIT License © 2026 TetraAcc
