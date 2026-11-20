# AGY Mobile & Remote Hub 🚀

> **Google Antigravity 跨平台轻量级远程协同中心 & 双机智能网关**  
> 一套免客户端安装、单端口同源、支持 URL Token 自动鉴权的 Web / Mobile 伴侣应用，支持在统一公网域名下智能透明反代并实时控制 **Steam Deck (24h低功耗常驻机)** 与 **Windows PC (主力开发机)**。

---

## 🌟 核心特性

- 🌐 **全跨平台免客户端安装**：基于 Flutter 3 编译为高性能 Web 应用，手机、平板、电脑浏览器打开即用，PWA 即刻安装到桌面。
- 🔑 **URL Token 零摩擦鉴权**：在公网穿透（如 Cloudflare Tunnel）中只需一次性带上 `?token=xxx`，自动写入 LocalStorage 并完成安全握手，免去重复登录。
- 🎮 **双机智能网关与透明反代**：
  - **Steam Deck** 作为低功耗 24 小时在线网关（通过 `cloudflared` 绑定顶级域名）；
  - 顶栏一键切换控制主机（Steam Deck / Windows PC），Deck 在内网全双工透明反代 Windows 端口，Windows 主力机无需暴露于公网。
- 📋 **多模态与图片秒级粘贴 (`Ctrl + V`)**：
  - 支持直接在输入框按 `Ctrl + V` 粘贴剪贴板截图，或将文件直接拖入页面；
  - 自动存入底层 `.user_uploaded` 会话目录并展示缩略图预览胶囊，发送时随消息提交给 Agent；
  - 补齐“添加上下文”中的 **【📁 添加本地文件】** 与 **【🖼️ 上传图片】** 菜单。
- ⚡ **会话管理与模型/模式一键切换**：
  - 抽屉侧边栏提供历史会话管理，支持单个会话二次确认彻底物理删除；
  - 输入框常驻 **运行模式胶囊** (`Auto 全自动` / `Turbo 极速` / `Plan 规划` / `Dev 开发`)；
  - 常驻 **推理模型胶囊** (`Gemini 3.8 Flash` / `Gemini 3.8 Pro` / `Claude Sonnet 4.6`)；
  - 支持在抽屉中新建带有初始 Prompt 与模式配置的全新任务会话。
- 💬 **实时全双工与思考反馈动效**：
  - 基于 WebSocket 实现双向秒级日志监听与工具调用（Tool Calls）流式呈现；
  - 发送即刻清空输入框，底部呈现 `[ 🤖 Agent 正在思考并执行指令... ]` 呼吸动效。

---

## 🏗️ 架构拓扑

```mermaid
flowchart TD
    Client["📱 移动端 / 💻 浏览器 (https://agy.your-domain.com)"]
    CF["☁️ Cloudflare Zero Trust (Tunnel)"]
    DeckGateway["🎮 Steam Deck 网关 (Port 8768)\n• aiohttp 静态托管 (Flutter Web)\n• 智能路由 & WebSocket 反向代理\n• 24h 常驻值守 (agy-remote.service)"]
    WinHost["💻 Windows 主力机 (Port 8765)\n• aiohttp 后台服务 (server_windows.py)\n• Antigravity AgentAPI & Brain 监听\n• 局域网按需连接 (内网IP: 192.168.x.x)"]

    Client -->|HTTPS / WSS| CF
    CF -->|localhost:8768| DeckGateway
    DeckGateway -->|Target = Deck| DeckGateway
    DeckGateway -->|Target = Windows (LAN反代)| WinHost
```

---

## 📂 项目结构

```text
agy-mobile/
├── lib/
│   └── main.dart                     # Flutter Web/Mobile 主界面、消息卡片、模式与多模态逻辑
├── web/
│   ├── index.html                    # 注入 agyBridge 原生粘贴与文件拖拽监听
│   └── ...
├── server/
│   ├── server_windows.py             # Windows 主力机端服务 (文件上传/AgentAPI消息桥接/日志监听)
│   ├── server_deck.py                # Steam Deck 24h 智能网关服务 (双机代理/媒体反代/会话管理)
│   ├── agy-remote.service            # Linux/SteamOS systemd 守护进程单元文件
│   └── start_windows_bridge.vbs      # Windows 开机后台静默自启脚本
├── pubspec.yaml                      # Flutter 依赖配置
└── README.md                         # 本文档
```

---

## 🚀 快速上手

### 1. 前端编译与部署 (Flutter Web)

```bash
# 获取依赖
flutter pub get

# 生产级构建 (自动树摇与资源优化)
flutter build web --release

# 将产物部署至网关机 (例如 Steam Deck)
scp -r build/web/* deck@<DECK_IP>:/home/deck/agy_remote/web/
```

### 2. Steam Deck 网关端部署

1. 部署服务端文件：
   ```bash
   mkdir -p ~/agy_remote/web
   cp server/server_deck.py ~/agy_remote/server.py
   ```
2. 安装 Systemd 用户级常驻守护进程：
   ```bash
   cp server/agy-remote.service ~/.config/systemd/user/agy-remote.service
   systemctl --user daemon-reload
   systemctl --user enable --now agy-remote.service
   
   # 开启用户驻留 (关屏或注销后进程不退出)
   loginctl enable-linger deck
   ```

### 3. Windows 主力机部署

1. 启动 Windows 桥接服务：
   ```bash
   python server/server_windows.py
   ```
2. （可选）开机后台自启：
   将 `server/start_windows_bridge.vbs` 快捷方式放入 Windows 开机启动目录：
   `shell:startup`

### 4. Cloudflare Tunnel 绑定

在 Cloudflare Zero Trust 控制台添加公共主机名：
- **子域名**：`agy`
- **域**：`your-domain.com`
- **Service Type**：`HTTP`
- **Service URL**：`http://localhost:8768`

完成后即可直接通过公网访问：
👉 `https://agy.your-domain.com/?token=your_auth_token`

---

## 📄 License

MIT License © 2026 TetraAcc
