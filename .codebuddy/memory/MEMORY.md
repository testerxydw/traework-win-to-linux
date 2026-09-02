# 项目长期记忆 (MEMORY.md)

## WorkBuddy Linux 移植：社区版 otohime 的真实来源（关键溯源，2026-09-01 实测）
- 社区版 `cn.workbuddy.otohime_*.deb` **不是**腾讯官方 Linux 构建泄露：实测 deb 内
  `@tencent/qimei-node/build/Release/qimei.node` 与
  `native/wechat-copydata-decoder/.../wechat_copydata_decoder.node` 均为 **PE32+ (Windows DLL)**，
  不是 Linux ELF，在 Linux 加载不了（靠 app 代码 try/catch 降级）。
- 社区版真正能用的 Linux 成分全来自公开可自主渠道：
  - Electron 39.2.7 运行时二进制 + Chromium 配套：electronjs.org 官方 Linux 预编译（Electron 开源）。
  - `better-sqlite3.node`：npm 源码 + electron headers 自编译（deb 内时间戳 2026-08-19，晚于基础包 08-17，印证后补编译），`file` 确认 ELF。
  - `node-pty (linux-x64)`：npm `@lydell/node-pty-linux-x64` 预编译。
  - `koffi (linux_x64)`：npm koffi 自带 linux prebuild。
- 腾讯私有模块（qimei / wechat-copydata-decoder / aegis / universal-report / tencent-docs-ai-engine）
  社区版也是打包 Windows DLL 充数，Linux 上降级；**社区并没有这些的真 Linux 版**。
- 结论：社区版 otohime = 社区按与本项目相同思路（拆 Windows 包 + 官方 Electron 39.2.7 + 自编译开源模块 + 私有降级），
  但**选对了 Electron 大版本（39.2.7，而非 CodeBuddy 的 37）**自己拼的移植包。版本号可从 Windows 包反查
  （app.asar 依赖声明 / WorkBuddy.exe 版本）。
- **去社区化可行**：运行时改 electronjs.org 官方 Electron 39.2.7 linux 包 + 开源模块自编译 + 私有降级，
  即完全不依赖社区 deb。社区版当前唯一价值 = 省去试错的「已验证能跑的整包」。
  风险点：需确认 WorkBuddy 没给 Electron 打私有补丁；社区已证明 39.2.7 官方二进制能跑（SIGSEGV=0、GUI 正常），可替换。
- ⚠️ 修正：上一轮「原生模块硬依赖社区版、唯一不可替代」论断**错误**——私有模块社区也是 win DLL，
  开源模块均可自主。社区版零原理上不可替代成分。

## build-workbuddy.sh 构建依赖图
- 外部源：
  1. Windows 安装包 `WorkBuddy-win32-x64-user-*.exe` → app.asar（前端）+ icon.png（纯 1024x1024 logo）。
  2. 社区版 deb（或 runtime-cache/files）→ Electron 运行时 + 原生模块 + desktop。
- 社区版经 RUNTIME_ROOT 拷进 deb：workbuddy-bin(3a)、.so/.pak/sandbox/swiftshader/vulkan/version/LICENSE(3b)、
  locales(3b)、app.asar.unpacked 原生模块(3d)、desktop(3f)、图标 fallback(3f)。
- 运行时来源优先级：`--runtime` > `workbuddy-build/runtime-cache/files/` > `cn.workbuddy.otohime_*.deb`。

## 已固化修复（app.asar 内原地替换，不重打包）
- `scripts/patch_daemon_lifecycle.py`：daemon 感知宿主失联（stdin 关/EPIPE）后主动停池退出，修「退出后进程残留」。
- `scripts/patch-tray-linux.py`：Linux/AppIndicator 下补 setContextMenu 经 DBusMenu 暴露菜单，修「托盘右键菜单不显示」。
- launcher `workbuddy`（heredoc 写入 wb_pkg）：孤儿进程清理 + --title-bar-style=custom + 默认 --no-sandbox。

## 发布约定
- tag 命名：`workbuddy-<版本>`（无 v 前缀，如 `workbuddy-5.3.14-4`）。
- GitHub：`gh release create` 上传单文件（276MB，GitHub 限制 2GB，OK）。
- Gitee：单文件附件限 ~100MB，须 `split -b 90M` 分卷（3 卷）；建 release 的 API **必填 `target_commitish`**（=master），否则 400。
- Gitee API 需 access_token（环境无，用户临时提供）。

## 用户规则 / 偏好
- **/tmp 临时文件用后清理**：在项目中若在 `/tmp` 创建临时文件（解包目录、截图、deb 对比产物、构建临时目录等），
  **不再需要时务必主动清理**，避免 /tmp 长期堆积、混淆活跃进程数据。
  - 清理时必须排除系统关键文件（X11 socket、systemd）与正在运行程序的 IPC（`.sock/.lock/.pipe`，
    以及 `workbuddy-*` / `codebuddy-*` / `wps-*` 等活跃程序运行时目录），只删明确无歧义的残留。
  - 本环境命令审批弹窗常无响应，破坏性清理命令宜直接交给用户在终端执行（给出精确命令），
    不要反复触发审批超时的 `rm`。

## Trae Solo deb 瘦身分析（trae-solo-cn_0.1.58-13，2026-09-02 实测）
- deb 353MB / Installed-Size 1.2GB。最大瘦身点：`resources/app/modules/ai-agent/libai_agent.so` 256MB **未 strip**（含 .symtab，strip 预计省数十~上百 MB）；
  `libsscronet.so`（根目录+ai-agent 两份共 20MB）亦未 strip。
- `trae-solo-cn-bin`(202MB)、`libckg.so`(47MB) 已 **stripped**，无法靠 strip 减。
- **Windows 二进制残留（Linux 用不到，可安全删，共 ~73MB 原始）**：node-v24.14.0-win-x64.zip(36MB)、
  skia.win32-x64-msvc.node(26MB)、aha_cua.dll(7MB)、TraeRecordReplayRuntime.exe(2.2MB)、
  trae-computer-use-mask.exe、koffi-win32-x64/win32_x64/koffi.node(1MB)。（其余 win*.js 是 npm 跨平台源码，勿删以免破坏 require）
- 重复二进制：ripgrep 三份 rg(共17MB)、fd 两份(共8MB)，留 1 份即可。
- 可选删：locales 285 文件 46MB（精简 zh+en 省 ~43MB）、desktop-modules/dist/media 50MB（UI 动画）、vsce-sign 17MB（发布工具）。
- 理论 deb 可降至 ~200-230MB（推荐档：删 win 残留+重复+strip libai_agent/sscronet）；激进档 ~180-210MB。
- 实现：解包→删残留→strip 未剥离 .so→dpkg-deb -b 重打包→重算 md5sums/Installed-Size。strip 后需验证启动。
- **已在 build.sh 落地（2026-09-02）**：精简阶段默认开启（`DO_SLIM=1`，`--no-slim` 关闭）。`stage_slim` 在原有 locales/重复 ripgrep/fd/mac/bat 基础上，
  新增删除 Windows 残留（*.dll/*.exe/*win32-x64*/*.msvc.node/node-v*-win-*.zip/windows.node/foreground_love.node/koffi-win32-x64）+ 对 *.so/*.node/主二进制 `strip --strip-unneeded`。
  预估 deb 可从 353MB 降到 ~200-250MB。验证启动命令：`bash build.sh --skip-extract --no-install --deb-only`。
- 对比基线（2026-09-02）：同类型 `com.xydw.workbuddy_5.5.1-3_amd64.deb` 解包 657MB 但 deb 仅 150MB。其干净打包=无 Windows 残留 + locales 仅 zh-CN/en-US + 主二进制 stripped + 未 strip .so 仅 30.9MB（多平台 koffi/node-pty prebuild）。
  trae 比它大的主因：① `libai_agent.so` 256MB 未 strip 的 AI 本地引擎（trae 独有、功能必需、非多余）；② 前端散装未打 `app.asar`（dpkg 压缩率低，是追平 150MB 的最大杠杆）；③ Windows 残留（已默认删）；④ 未 strip 符号（已默认 strip）。
  要再逼近 150MB 必须做**前端 asar 化**（resources/app 打 app.asar + 原生模块 unpack），并接受 libai_agent.so 的最小体量。
  澄清：trae 的 .node 原生模块来自 TraeCode 官方 Linux 包预编译（非本机自编译、亦非社区移植）；无论来源，.node/.so 皆须 --unpack 放出到 resources/app.asar.unpacked（dlopen 需真实 fs 路径，asar 虚拟 fs 不能直载）。asar 化只压缩 JS/JSON 前端，原生模块体积小不损压缩收益。落地顺序：stage_extract(rsync+patch main.js) → stage_asar(pack+unpack+rm 散目录) → stage_desktop → stage_deb；需 asar 命令。

## Trae 14版实测（trae-solo-cn_0.1.58-14, 2026-09-02）
- deb 300MB / 解包 1017MB(=安装磁盘)。构成：ai-agent 模块 349MB(34%, 功能硬伤: libai_agent.so 245 + agent-tool-host 87 + libckg 45) + 主二进制 193MB + 前端/扩展/媒体散装 ~425MB(媒体 mp4/gif 47MB 可删) + 运行时 .so ~50MB。
- **关键认知纠正**：asar 化只减 deb 分发体积(300→~220MB)，**完全不减安装磁盘 1G**(asar 内压缩, 解包后仍占满)；strip 对 libai_agent.so 收益极小(245MB 主体非符号表)。要减安装 1G 只能裁剪功能(砍 ai-agent 349MB 或删媒体 47MB)。
- 14 版仍含 koffi-win32-x64 残留 1MB + locales 仅 2 个，说明未跑本仓库 build.sh 默认 slim（其会删 *win32-x64*）；**已在 stage_slim 落实（参考 workbuddy 移植经验）**：删跨平台残留 darwin/win32/msvc/musl/arm64（用 -prune -exec rm -rf 系统化替代原 -name -delete）+ 媒体 mp4/mov/webm/avi/mkv/gif(~47MB)。重新跑 `bash build.sh` 生效（before/after 会打印 MB 差值）。
- **根因定性（用户追问）**：安装 1G ≈ TraeCode 官方 Linux 包本身体积。build.sh 的 stage_extract 把 TraeCode 完整运行时(主二进制193+ .so 50)+ 前端 resources/app(~350)+ AI 引擎 modules/ai-agent(349，libai_agent.so 245 等) 复制进 deb，故安装体积=TraeCode 本体。这不是本脚本引入的多余依赖(stage_extract 只复制运行必需集)，而是 trae 功能核心。TraeCode 包内"真正冗余"(Win 残留/多平台/未strip)已在 slim 清掉；剩余 ~950MB 主体靠"少复制依赖"动不了。根本减体积只能 TraeCode 官方精简 AI 引擎(云端化)或换架构(如 workbuddy 式精简运行时，但 trae 私有 AI 模块社区无真 Linux 版，不可行)。
- **架构判断（用户提议"自编译替代 TraeCode 运行时"）**：对 trae 不可行+收益极小。理由：(1) 无开源底座可自编译——TraeCode 是字节闭源 VSCode 定制分支，trae 官方 Linux 交付即 trae-cn 包，不存在"开源版+补丁"；(2) 体积三大头仅运行时壳~193MB 勉强可换，但换纯 Electron 会丢登录/同步/AI 入口等补丁能力且前端可能跑不起来；AI 引擎349MB+前端350MB 闭源必搬，减不了；(3) libai_agent.so 245MB 是引擎代码非模型权重，权重在~/.trae 首启下载、不在 deb，故无"权重首启下载"优化空间。对比 workbuddy 路线(开源壳可编+闭源核心可 stub)对 trae 不成立。**已借鉴 workbuddy 的 stage_slim 经验强化 trae 跨平台+媒体清理(见上条)。** 进一步减安装体积只能等 TraeCode 官方云化 AI 引擎(云端化 349MB 引擎)或换架构(不可行)。
- **实测验证（从 TraeWork_CN-Setup-x64.exe 分析，2026-09-02）**：exe 411MB，解压后 extracted/code$GetDestDir 即 TraeWork 源。resources/app/modules/ai-agent 解压 **619MB**(Windows 形态：ai_agent.dll/toolhost.dll/harness.dll/aiep_vm.dll/vm_sdk.dll/sscronet.dll + bin/agent-tool-host.exe)，ckg 41MB(libckg.dll)，sandbox 6.3MB；顶层 TRAE SOLO CN.exe 为 Windows Electron 主二进制。→ **TraeWork 是完整自包含 Windows Electron 应用，自带 619MB AI 引擎**。但 Linux 移植时这些 .dll/.exe 全不能加载，必须换 Linux 原生版；AI 引擎 Linux 原生版(libai_agent.so 等)闭源、唯一来源是 TraeCode(=trae 官方 Linux 构建)。**故 Linux 版 trae 必然依赖 TraeCode，非本脚本多余依赖**——TraeCode 就是 Windows 包里那些 .dll/.exe 的 Linux 等价物。唯一可摆脱 TraeCode 的是 Electron 壳(可换官方 Electron，省~40MB 但风险丢补丁能力)；AI 引擎无替代。这正解释为何 trae≠workbuddy：workbuddy 无本地 AI 引擎(AI 走云端)故可纯官方 Electron+自编译。
- **版本号同步（已修复，2026-09-02）**：trae build.sh 的 stage_deb 原仅基于 DEBIAN/control 旧值 bump_version 自增修订，control 初值 0.1.58 写死且与真实版本脱节。**真实应用发布版本源 = TraeWork 的 `manifest.json` 的 `appVersion` 字段**（实测 0.1.61），该文件由 stage_extract 复制进 `deb-pkg/opt/trae-solo-cn/manifest.json`；而 product.json 的 `version`(1.107.1) 是 VSCode 内核版本体系、非 solo 发布版本，不宜作 deb 版本。修复：stage_deb 优先从 manifest.json 读 `appVersion`，同版本仅自增修订号（0.1.61-1, -2...），appVersion 变化（升级新包）则重置为 -1；无 manifest 时回退旧 bump_version 逻辑。--skip-extract 时 deb-pkg 已含该文件故仍可读。
- **build.sh postinst 空行累积 bug（已修，2026-09-02）**：stage_desktop 的 postinst 注入每次 `cat >>` 带前导空行追加桌面快捷方式块，原移除正则 `re.sub(r"\n# ---- BEGIN.*?# ---- END ----\n", "\n")` 只吞 1 个 `\n`，导致块前空行每次 +1（实测修复前已累积 5 个）。已改为 `\n+... \n+` 贪婪匹配块前后所有连续空行归一为单个 `\n`，验证 5→2 且幂等不再增长。全脚本仅此一处 `cat >>` 累积点（532 行）。
