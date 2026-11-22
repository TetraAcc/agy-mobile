# AGY Remote Hub (v1.3.7+12) 技术架构与交接开发手册

> **版本标识**：`v1.3.7+12`  
> **交接日期**：2026-11-23  
> **适用对象**：接手本项目维护、新功能演进的前端与后端研发人员  

---

## 1. 项目概述与定位

`AGY Remote Hub` 是为 **Google Antigravity (AGY)** 量身打造的跨平台多节点远程协同控制中心。它打破了桌面端 IDE 的物理限制，支持在手机浏览器、平板、Steam Deck 及任意 Web 终端上实时查看和控制分布在不同主机（Windows 工作站、Steam Deck 便携节点等）上的 AGY AI 编程会话。

### 核心功能指标：
- **双端多节点统一路由**：支持 Steam Deck 与 Windows PC 节点自由热切换，一键穿透内网。
- **动态账号密码鉴权**：支持基于 SHA256 哈希认证、高熵动态会话（Session Token）及多租户节点权限隔离。
- **官方会话树像素级对齐**：直连 AGY 核心 SQLite 库与 `transcript.jsonl`，项目分组、盘符解析及排序 100% 还原官方 GUI。
- **精准运行态（Running State）保持**：权威判定会话思考/执行状态，页面刷新（F5）与节点重连状态持久不丢失。
- **全流程额度与模型监控**：集成官方 CLI 实时监控 Gemini / Claude 等模型配额。

---

## 2. 系统拓扑与网络架构

```mermaid
graph TD
    Client["客户端 (Web / Mobile / Tablet)<br/>HTTPS / WSS"] -->|通过 Cloudflare Tunnel| DeckGW["Steam Deck 网关 (Linux/Edge)<br/>Port: 8768 (aiohttp)"]
    
    subgraph "集群内部通信 (高熵 Internal Secret 签名)"
        DeckGW -->|反代 / 路由| LocalDeck["Deck 本地引擎 (Port: 8768)<br/>~/.gemini/antigravity-cli"]
        DeckGW -->|内网 / Tailscale 直连 (192.168.0.22 / 100.x)| WinNode["Windows PC 节点 (Port: 8765)<br/>~/.gemini/antigravity"]
    end

    WinNode --> WinDB[("Antigravity 核心底座<br/>state.vscdb / transcript.jsonl")]
    LocalDeck --> DeckDB[("AGY CLI 状态底座<br/>state.vscdb / transcript.jsonl")]
```

- **统一访问入口**：客户端无论访问公网（如 `https://agy.tetraacc.me`）还是局域网，统一经由 Steam Deck 边缘网关汇聚。
- **内部转发机制**：网关依据当前连接请求携带的 `node=windows` 或 `node=deck` 查询参数，自动代理双向 WebSocket 消息流与文件/图片媒体资源。

---

## 3. 核心机制实现详解

### 3.1 账号密码认证与多租户权限隔离
- **废除静态 Token**：系统已全面移除 URL 明文静态 token。采用 `/api/login` 接口进行账号密码登录，成功后颁发 32 字节高熵 Session Token。
- **凭据存储规范**：密码在 `server/server_config.json` 中以 SHA256 加盐哈希存储，活跃 Session 缓存于 `server/sessions.json`，均被 `.gitignore` 严格保护。
- **多租户隔离**：
  - 用户配置中的 `allowed_nodes` 严格限制当前租户可见并可操作的物理节点。
  - 前端未登录时不展示敏感账号名；登录态过期或未鉴权请求一律重定向至登录卡片。

### 3.2 官方会话树（Session Tree）精准对齐算法
- **源码位置**：`server/server_core.py` 中的 `get_grouped_sessions()` 与 `server/server_common.py` 中的 `parse_project_name_and_path()`。
- **Windows 盘符根目录保护**：对于 `Z:\` 等独立挂载盘符，算法自动识别避免被 `basename` 截断为空，单独作为根节点 `Z:` 展示。
- **数据库映射（`conversations_fts`）**：针对历史无工作区绑定但实际属于特定工程的会话，从底座 SQLite `conversations_fts` 与 `project_id` 构建映射字典精确回溯，确保“课件翻译”等工程分类与桌面端官方 GUI 100% 保持一致。
- **时间排序机制**：各分组工程按内部最新会话的更新时间降序排列；会话列表按最新修改时间降序排列。

### 3.3 运行态（Running State）权威判定与刷新持久化
- **判定原理**：后端 `is_session_running(sid)` 方法结合双重数据源权威判断：
  1. 查询底层 SQLite 中的全局标记 `CASCADE_RUN_STATUS_RUNNING` 与 `not_fully_idle`；
  2. 读取目标 `transcript.jsonl` 文件尾部最新 Step 是否为非完成态。
  - **避坑提示**：彻底废弃了“日志超过 3 秒无更新即判停”的脆弱逻辑，彻底解决长思考模型或网络波动时的状态闪退。
- **前端状态持久化**：
  - `lib/main.dart` 在 `_handleSessionHistory` 中，当收到后端推送或最后一条消息处于未完成状态时，严格将会话追加至 `_runningSessionIds` 集合。
  - 无论用户如何 F5 刷新网页或重启浏览器，抽屉中的红色 `[运行中]` 徽章与思考状态指示器均能准确还原。

---

## 4. 项目源码结构

```
agy_mobile_app/
├── lib/                             # Flutter 前端核心源码
│   ├── main.dart                    # 全局状态管理、双节点网关 WebSocket 通信、鉴权状态机
│   ├── widgets/
│   │   ├── quota_drawer.dart        # 侧边栏抽屉：项目树/会话树分组、多节点切换、额度与主题
│   │   └── chat_message_widget.dart # 聊天消息体（Markdown、思维链折叠、工具调用预览）
│   └── models/                      # 数据模型定义
├── server/                          # 后端核心服务（Python 异步单真实源）
│   ├── server.py                    # 统一多平台入口启动脚本（自动探测平台）
│   ├── server_core.py               # 单真实源服务核心（网关反代、动态鉴权、会话树聚合）
│   ├── platform_adapter.py          # 平台适配抽象（WindowsAdapter / DeckAdapter）
│   ├── server_common.py             # 共享工具类（盘符解析、Transcript清洗、路径校验）
│   ├── server_config.example.json   # 平台节点与用户账号配置示例模板
│   ├── watchdog_windows.py          # Windows 端进程看门狗守护
│   ├── start_windows_bridge.vbs     # Windows 静默后台自启脚本
│   └── stop_windows_bridge.bat      # Windows 优雅停止脚本
├── web/                             # Flutter Web 构建产物部署目录
├── pubspec.yaml                     # 项目依赖与版本配置（保持 v1.3.7+12）
└── HANDOVER.md                      # 本技术架构与交接手册
```

---

## 5. 部署与运维指南

### 5.1 Windows PC 节点
1. **环境依赖**：Python 3.10+，安装依赖 `aiohttp`, `websockets`。
2. **配置文件**：
   ```bash
   cp server/server_config.example.json server/server_config.json
   # 修改 windows 部分的端口、允许的域名及账号密码哈希
   ```
3. **日常启动与停止**：
   - 调试启动：`python -u server/server.py`
   - 后台静默守护启动：双击运行 `server/start_windows_bridge.vbs`（由 `watchdog_windows.py` 监控存活并自动重启）
   - 停止服务：运行 `server/stop_windows_bridge.bat`

### 5.2 Steam Deck / Linux 网关节点
1. **服务配置**：部署为 systemd 用户态服务。
   - 服务文件位置：`~/.config/systemd/user/agy-remote.service`
2. **常用管理命令**：
   ```bash
   # 重启网关服务
   systemctl --user restart agy-remote.service
   # 查看实时运行日志
   journalctl --user -u agy-remote.service -f -n 50
   # 查看服务状态
   systemctl --user status agy-remote.service
   ```
3. **公网穿透**：运行 `cloudflared tunnel run <TUNNEL_NAME>` 绑定域名 `agy.tetraacc.me`。

### 5.3 前端编译与热同步流程
当修改了 `lib/` 源码后，需重新编译 Web 静态产物并同步：
```bash
# 1. 编译 Web 生产版本
flutter build web --release

# 2. 同步至 Windows 本地服务端 web 目录
Copy-Item -Recurse -Force build/web/* server/web/

# 3. 同步至 Steam Deck 节点
scp -r build/web/* deck@<deck-ip>:~/agy_remote/web/

# 4. 重启 Deck 服务以确保静态文件缓存刷新
ssh deck@<deck-ip> "systemctl --user restart agy-remote.service"
```

---

## 6. 接手人员后续建议

1. **多模型参数配置面板**：当前新建会话已支持 Gemini 2.5 Flash / Gemini 2.5 Pro / Claude 3.7 Sonnet 等预置模型，可进一步在新建弹窗中扩充 Thinking Budget 等微调控制参数。
2. **断网离线缓存优化**：对于移动端低信号场景，可引入本地 IndexedDB/SQLite 对最近 10 条会话历史进行离线预读渲染。
3. **安全提醒**：切勿将包含真实密码和节点内外网 IP 的 `server/server_config.json` 提交到公开 Git 仓库中。
