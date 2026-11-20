# AGY Mobile & Remote Hub 🚀

> **Google Antigravity 跨平台轻量级远程协同中心 & 双机智能网关**  
> 一套免客户端安装、单端口同源、支持 URL Token 自动鉴权的 Web / Mobile 伴侣应用，支持在统一公网域名下智能透明反代并实时控制 **Steam Deck (24h低功耗常驻机)** 与 **Windows PC (主力开发机)**。

---

## 🌟 核心特性

- 🌐 **全跨平台免客户端安装**：基于 Flutter 3 编译为高性能 Web 应用，手机、平板、电脑浏览器打开即用，PWA 即刻安装到桌面。
- 🔑 **多租户零摩擦鉴权与设备物理隔离**：
  - 基于 URL Token 自动鉴权（如 `?token=tetra2026` 访问双机，`?token=simeng` 仅访问专属 PC），完全实现不同用户、不同设备间的物理级权限隔离与列表屏蔽；
  - 自动持久化至 LocalStorage 并完成安全握手，免去重复登录。
- 🎮 **双机/多机智能网关与透明反代**：
  - **Steam Deck** 作为低功耗 24 小时在线网关（通过 `cloudflared` 绑定顶级域名）；
  - 顶栏一键切换控制主机，Deck 边缘根据用户权限透明反向代理目标宿主机（支持 LAN IP 与 Tailscale 虚拟局域网），宿主机无需暴露于公网。
- 📊 **官方底层 Connect-RPC 配额监控**：
  - 直连 Antigravity 后台 `LanguageServerService/RetrieveUserQuotaSummary`；
  - 抽屉侧边栏实时渲染 Gemini 周/5小时额度及 Claude/GPT 模型的真实消耗进度条。
- ⚡ **真实模型矩阵与思考分级（Thinking Budget）**：
  - 废弃伪造模型标签，全面对齐官方真实模型：`Gemini 3.8 Flash (High/Medium/Low)`、`Claude Sonnet 4.6`、`GPT-OSS 120B`、`Gemini 2.5 Pro` 等；
  - 新建会话弹窗与底部快捷切换均支持官方思考预算级别调整。
- 🛑 **真全双工底层打断 (Stop) 与斜杠指令**：
  - 运行时实时显示【🛑 停止】按钮，直接通过 RPC `CancelCascadeTask` 发送底层打断信号，支持全速中断输出；
  - 原生支持 `/clear`、`/status` 等核心控制台指令。
- 📦 **全双工流式下载与防排版死锁保护**：
  - 消息附件与工作区文件浏览器支持 `/api/download` 流式下载通道，浏览器端直接拉起原生下载；
  - 前端扩展名识别 + 后端空字节 `\x00` 嗅探双重防御，彻底杜绝 CanvasKit 渲染二进制文件（`.zip`, `.exe`, `.pdf` 等）时发生的排版引擎假死崩溃。
- 📋 **多模态与图片秒级粘贴 (`Ctrl + V`)**：
  - 支持直接在输入框按 `Ctrl + V` 粘贴剪贴板截图，或将文件直接拖入页面；
  - 自动存入底层 `.user_uploaded` 会话目录并展示缩略图预览胶囊，发送时随消息提交给 Agent；
  - 补齐“添加上下文”中的 **【📁 添加本地文件】** 与 **【🖼️ 上传图片】** 菜单。

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
