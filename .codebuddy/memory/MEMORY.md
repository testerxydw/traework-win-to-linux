# 项目长期记忆 (MEMORY.md)

本仓库含两条 Linux 移植线：**trae**（TraeWork CN → trae-solo-cn）与 **workbuddy**（WorkBuddy → workbuddy）。

## 用户规则 / 偏好（稳定）
- **设计先出 HTML 预览再动 Vue/正式代码**：改 UI（如 UpdateCenterItem.vue）前先做 `prototype/*.html` 原型（含亮/暗主题），等用户选定方案再改组件并打包。
- **/tmp 临时文件用后清理**：解包目录、截图、deb 对比产物、构建临时目录不再需要时主动清理；
  必须排除系统关键文件（X11 socket、systemd）与活跃程序 IPC（`.sock/.lock/.pipe`，`workbuddy-*`/`codebuddy-*`/`wps-*`）。
  本环境审批弹窗常无响应，破坏性 `rm` 宜直接给出精确命令交用户在终端执行。
- 版本号只从「真实发布源」取值，禁止写死。

## 一、trae（build.sh，5 阶段流水线）
流水线：`stage_extract` → `stage_slim`（默认开，`--no-slim` 关）→ `stage_desktop` → `stage_deb` → `stage_ll`（默认关，`--ll` 开）+ 安装。
源码→deb-pkg→deb；关键变量 `PKG_DIR/APP_DIR/RES_DIR/CONTROL_FILE`。

### 打包元数据必须由脚本生成（2026-09-12 修复）
- commit `ad81296` 删除了 `deb-pkg/DEBIAN/{control,postinst,prerm,postrm}`、`deb-pkg/usr/bin/trae-solo-cn`、`usr/share/applications/*.desktop`
  （deb-pkg 定位为纯构建产物，.gitignore 亦忽略 `opt/*`、`md5sums`、`icons/`）。
- 后果：`stage_deb` 里 `chmod 755 DEBIAN/postinst prerm postrm` 因文件不存在报错，叠加 `set -e` **直接中断打包**（无 deb 产出）；
  `stage_desktop` 也未创建 desktop 文件（只做 sed 完善）→ 菜单项缺失。
- 修复：新增 `ensure_deb_meta()`（stage_desktop 第 0 步，幂等、仅缺失时生成）补齐
  control（Version 取 manifest.appVersion，无修订号）/ postinst 基础体 / prerm / postrm / desktop 文件 / `usr/bin/trae-solo-cn` 软链；
  `stage_deb` 的 chmod 改为逐个判存在（缺失只警告，不再中断）。

### 版本号同步
- 真实发布版本 = TraeWork `manifest.json` 的 `appVersion`（不是 product.json 的 VSCode 内核 `version`）。
- `stage_deb` 优先读 appVersion：同 appVersion 自增修订号（0.1.64-1→-2），appVersion 变化重置为 `-1`；无 manifest 回退 bump_version。
- 玲珑版本号 = deb 主版本 + 修订号转点分（0.1.58-5 → 0.1.58.5）。

### main.js 标题栏补丁（0.1.63 起，动态探测）
- **禁写死 minify 变量/函数名**（isLinux：Lt→Qf；解析函数：oW→hV→bV 每版都变）。用正则动态探测。
- **插入点必须在 `return"custom";` 分号之后**，否则 `SyntaxError: Unexpected token 'if'`。
- 漏打后果：无 titleBarOverlay + `frame:false` → "Titlebar overlay is not enabled"，窗口打不开
  （0.1.63 打不开的根因；旧补丁还写死 `Lt||` 而 Lt 已变恒真字符串）。
- 官方 0.1.63 原版 Linux 能正常开窗（自绘标题栏），但 DDE 上有白块 → **补丁继续保留强制 native**。
- product.json 仅改渲染侧（buildPlatform=linux、titleBarStyle=native），对主进程建窗无效，必须直接补 main.js。

### 精简（stage_slim，仅减 deb 分发体积）
- 保留：locales 仅 zh-CN/en-US；删重复 ripgrep/fd、macOS 模块、`*.bat`。
- 删跨平台残留：`*.dll/*.exe/*win32-x64*/*.msvc.node/node-v*-win-*.zip/windows.node/foreground_love.node/*dSYM/*framework`
  + `*-{darwin,win32,msvc,linux-musl,linux-arm64,linux-armhf}*` 目录；媒体 `mp4/mov/webm/avi/mkv/gif`(~47MB)。
- `strip --strip-unneeded` 所有 ELF（`*.so*`/`*.node`/可执行位文件/主二进制）；实测 1209MB→996MB（省 213MB）。

### 体积与架构的已知结论（勿重复论证）
- 安装体积 ≈ TraeCode 官方 Linux 包本体（~1G）：运行时壳 193MB + 前端 ~350MB + `modules/ai-agent` 349MB(含 libai_agent.so 245MB)。
  stage_extract 只复制运行必需集，不是脚本引入的冗余。
- asar 化只减 deb 分发体积（300→~220MB），**不减安装磁盘**；strip 对 libai_agent.so 收益极小（主体非符号表）。
- 不要试图「自编译替代 TraeCode 运行时」：TraeCode 是字节闭源 VSCode 定制分支，无开源底座；
  Windows 包里 AI 引擎是 .dll/.exe（619MB），Linux 必须用 TraeCode 的 .so 版本——**Linux 版 trae 必然依赖 TraeCode**。
  唯一可换的是 Electron 壳（省 ~40MB，风险丢补丁）。想真正减体积只能等官方云化 AI 引擎。
- 对比：workbuddy 无本地 AI 引擎（AI 走云端）故可纯官方 Electron + 自编译，路线不可套用到 trae。

## 二、workbuddy（build-workbuddy.sh）
### 社区版 otohime 的真实来源（2026-09-01 实测）
- `cn.workbuddy.otohime_*.deb` **不是**腾讯官方 Linux 构建泄露：`qimei.node`、`wechat_copydata_decoder.node` 实为 **PE32+ Windows DLL**（Linux 加载失败，靠 try/catch 降级）。
- 真正可用的 Linux 成分均来自公开渠道：electronjs.org 官方 Electron **39.2.7** Linux 预编译、`better-sqlite3.node` 自行编译、`@lydell/node-pty-linux-x64`、koffi linux prebuild。
- 腾讯私有模块（qimei / wechat-copydata-decoder / aegis / universal-report / tencent-docs-ai-engine）社区版也是 win DLL → 无真 Linux 版。
- 结论：社区版 = 社区按同思路（拆 win 包 + 官方 Electron 39.2.7 + 开源自编译 + 私有降级）拼的包；
  版本号可从 Windows 包反查。**零原理上不可替代成分** —— 去社区化可行（改用官方 Electron 39.2.7 + 自编译 + 私有降级）。
  注意 CodeBuddy 用的是 Electron 37，大版本必须按 Windows 包声明选。

### 构建依赖图
- 外部源：① `WorkBuddy-win32-x64-user-*.exe` → app.asar 前端 + icon.png；② 社区版 deb（或 runtime-cache/files）→ Electron 运行时 + 原生模块 + desktop。
- 运行时来源优先级：`--runtime` > `workbuddy-build/runtime-cache/files/` > `cn.workbuddy.otohime_*.deb`。

### 已固化修复（app.asar 内原地替换，不重打包）
- `scripts/patch_daemon_lifecycle.py`：daemon 感知宿主失联（stdin 关/EPIPE）后主动停池退出（修退出后进程残留）。
- `scripts/patch-tray-linux.py`：Linux/AppIndicator 下补 setContextMenu 经 DBusMenu 暴露（修托盘右键菜单不显示）。
- launcher `workbuddy`：孤儿进程清理 + `--title-bar-style=custom` + 默认 `--no-sandbox`。

## 发布约定
- GitHub：`gh release create` 单文件（~276MB，限制 2GB）。
- Gitee：单文件附件限 ~100MB，须 `split -b 90M` 分卷；建 release API **必填 `target_commitish`**（=master），否则 400；需 access_token。
