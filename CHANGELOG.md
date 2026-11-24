# Changelog

所有面向用户与运维的核心变更均按时间倒序记录在此文件中。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

---

## [2.1.3] - 2026-11-24

### Added
- **项目旁运行状态呼吸灯提示**：
  - `QuotaDrawer` 在折叠/展开的项目标题旁新增动态绿色呼吸灯（`_ProjectBreathingDot`），当该项目内存在运行中的会话时持续呼吸闪烁，存在 2 个及以上运行中会话时同步显示数量角标，无需点开项目即可一眼察觉活跃任务。

### Fixed & Hardened
- **修复长回复被 `<truncated N bytes>` 腰斩截断的问题**：
  - `BaseEngineProvider.get_transcript_path()` 与 `SessionEventHub` 实时监听流改为优先读取无损完整版 `transcript_full.jsonl`（旧会话无该文件时自动回退 `transcript.jsonl`），解决单条 AI 回复超过约 4KB 时因读取紧凑日志而丢失中间段落的问题；
  - `SessionEventHub` 新增监听路径切换时的 `step_index` 无缝衔接与多块回溯行尾偏移计算，并在聊天流工具胶囊解析时限制超长内联文件字符串体积。
- **多节点离线缓存死锁修复与实时状态同步**：
  - `HubController` 新增 `refreshNodes()` 并发去重刷新接口：在 WebSocket 断线重连/意外断开、App 从后台恢复、打开侧边栏、打开顶部节点切换菜单以及 60 秒轮询时自动向网关刷新各节点最新在线状态；
  - `switchNode()` 在遇到本地缓存显示离线或缺失的节点时，先向网关实时重探一次后再判断能否切入，消除远端主机重启上线后必须退出重新登录才能恢复连接的死锁问题；
  - 侧边栏 `目标控制主机` 标题栏新增手动刷新按钮，且点击当前处于断线/离线状态的节点也会触发重探与 WS 重连。
- **全盘代码质量与安全加固**：
  - 在 `AndroidManifest.xml` `<queries>` 中补充 `android.media.action.IMAGE_CAPTURE`，确保 Android 11+ 设备拍照上传 `resolveActivity` 可正常识别系统相机；
  - 服务端沙箱敏感文件黑名单新增 `key.properties`、`*.jks`、`*.keystore`、`*.pfx`、`*.p12` 拦截；
  - 网关登录限流增加 `_resolve_client_ip`，仅对本地回环代理（`127.0.0.1` / `::1`）信任 `CF-Connecting-IP` 与 `X-Forwarded-For`；
  - 修复 `HubController.switchNode` 切换节点时遗漏清理 `sessionQueue` 状态的问题；
  - 统一后端 `__version__`、`pyproject.toml` 与网关/节点 FastAPI 版本号源。

---

## [2.1.2] - 2026-11-24

### Added
- **每轮对话内嵌 Diff + 底部最新修改并存**：
  - 后端 `/agent/sessions/{sid}/changes` 新增 `turns`（按轮次聚合的轻量变更列表）及 `turn_id` 精确筛选参数。
  - 前端在每轮产生文件修改的 AI 回复末尾自动内嵌 `本轮修改` 可展开卡片（对齐桌面端 Antigravity 风格），同时保留底部 `最新修改` 常驻栏与单步工具胶囊跳转；`ChangeReviewSheet` 支持 `单步 #N` / `本轮修改` / `最新修改` / `全部修改` 四档范围自由切换。
- **工作区音视频免预缓存流播与系统相册联动**：
  - `FileUtils` 新增常见视频/音频格式识别与彩色图标区分，`WorkspaceFilePickerDialog` 新增音视频播放入口。
  - Android 原生层（`MainActivity.kt`）新增 `openRemoteMedia` 直接拉起系统视频/音乐播放器流式播放（无需提前下载整个文件）；图片应用内缩放弹窗支持一键拉起系统相册。
- **LaTeX 数学公式转 Unicode 渲染**：
  - 新增 `LatexMathConverter`，在 Markdown 渲染前将行内（`$...$`、`\( ... \)`）与块级（`$$...$$`、`\[ ... \]`）数学公式转译为标准 Unicode 符号与上下标（如 `$\min$` $\rightarrow$ `min`、`$\ge$` $\rightarrow$ `≥`、`$x_1$` $\rightarrow$ `x₁`），自动跳过代码块与货币数字并防止未转译下划线被误解析为斜体。
- **iOS PWA 专属打磨与 SE3 小屏适配**：
  - 生成 `180×180` 24-bit 纯白底 `apple-touch-icon.png` 及全套 iOS 原生 `AppIcon` 图集，修复透明背景在 iOS 主屏幕被染黑的问题。
  - 优化 `web/index.html` 与 `manifest.json`：加入系统明暗双态自适应启动过渡屏、`viewport-fit=cover`、`overscroll-behavior: none`，放开 `orientation: any` 旋转限制，并修复 iOS Safari 异步外链打开被弹窗拦截与 `SessionChangesBar` / 范围切换栏在 `375px` 窄屏下的溢出问题。

### Changed
- **单架构 APK 流水线与版本递增基线**：
  - 简化 `.github/workflows/build-android.yml`，移除多余的 `build_universal` 勾选项并只构建 `android-arm64` 单一 APK。
  - 将 `pubspec.yaml` 版本基线升级至 `5000+`，跨越历史 `--split-per-abi` 的 `2000` 版本号偏移量，确保持续覆盖安装升级不提示降级冲突。

### Fixed & Hardened
- **Windows 映射网络驱动器路径兼容**：修复 `RootRegistry` 在调用 `Path.resolve()` 后将 RaiDrive 等映射盘符（如 `Z:\`）改写为 `\\RaiDrive-Tetra\WebDAV\` 导致客户端路径前缀匹配失败的问题（内部保留真实路径解析与安全校验，对外清单保留客户端原始盘符）。

---

## [2.1.0] - 2026-11-23

### Added
- **Android 原生系统下载器接管**：集成 `DownloadManager` 托管后台下载（支持漫游网络与通知栏进度展示，并修复同步极速失败弹窗卡死与取消令牌）；文件签名票据 TTL 由 60 秒延长至 600 秒。
- **Android 平板与宽屏响应式布局**：新增 `ResponsiveLayout`，在 `>= 900dp` 宽度屏幕启用可折叠常驻左侧栏、`840px` 居中阅读列、`1080px` 工作区抽屉宽度与横屏紧凑输入栏。
- **品牌自适应图标**：绘制并校准了垂直视觉重心的无阴影 Google 四色几何 `A` 图标（适配 Android Adaptive Icon、Web Favicon 与 PWA）。
- **智能初始会话选择与 Diff Scope**：进入节点优先自动打开运行中会话（无则选最近修改活跃会话）；工作区根目录同步时预注册 SQLite 内全部 `workspace_uris`；前端 `file:///` 路径与 `#L...` 行号锚点解析加固。
- **Tier-2 原生能力与极简重构**：支持系统分享接收（Share Target）、系统相机直拍、前台任务运行状态常驻通知与后台完成/`ask_question` 震动提醒、4 款自托管按需字体加载及侧边栏会话置顶独立分组。

---

## [2.0.0] - 2026-11-23

### Added
- **架构重构（Edge Gateway + 无状态 Node Agent）**：废弃 v1.x 单体脚本服务端，全面解耦为独立 Gateway 与多租户受控 Agent；支持 `scrypt` 密码哈希、登录防爆破、HttpOnly Cookie + Bearer 双通道 Token 刷新复用检测、HMAC-SHA256 防重放内网签名。
- **实时与只读边界重构**：引入基于字节偏移量的 Per-Connection `SessionEventHub`、官方 `conversation_summaries.db` 严格只读（`?mode=ro`）、Connect-RPC 与 PGID 真实打断。
- **桌面级工作区协同**：新增会话变更 Diff & Comment 逐段评审、多 Git 仓库 `uncommitted / HEAD` Diff、受控文本轻编辑（带 `mtime` 冲突保护）、持久化每会话消息队列、任务步骤进度栏、工具调用输入输出详情、Artifacts 浏览器与 6 套 Catppuccin / Nord 明暗双模式主题。

---

## [1.3.7] 及早期版本 - 2026-11-22 ~ 2026-11-23

- 完成早期 Windows 守护进程重连、跨节点配额同步、侧边栏折叠配额胶囊卡片（v1.3.5）、会话切换防黑屏修复（v1.3.6）及基础 Flutter Web/Mobile 控制闭环。
