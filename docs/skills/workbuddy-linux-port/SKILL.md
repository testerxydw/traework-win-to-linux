---
name: workbuddy-linux-port
description: "WorkBuddy（腾讯 AI Agent 桌面应用，Electron 架构）从 Windows 安装包移植到 Linux 并打包为 deb 的完整流程与踩坑手册。当需要拆包 WorkBuddy 的 NSIS/7z 安装包、提取 app.asar、替换 Linux Electron 运行时、编译或替换原生 .node 模块、处理 ABI 不匹配导致的 SIGSEGV、为腾讯私有模块制作 stub，或调试移植后部分功能不可用时使用。也适用于其它 Electron 应用（非 VS Code 分支）的 Linux 移植参考。"
---

# WorkBuddy → Linux 移植技能

把 Windows 版 WorkBuddy（`@genie/workbuddy-desktop`，Electron 应用）移植到 Linux 并打包为 deb。

> ⚠️ 非官方移植，仅供学习交流，版权归原开发方（腾讯）所有。
> 与 `traework-deb-repack` 的区别：TraeWork/CodeBuddy 是 **VS Code 分支**（有 `out/main.js`），
> 可直接借同源 Linux 运行时；WorkBuddy 是**自定义 Electron 应用**（入口 `main/index.js`），
> 无同源 Linux 版，需自行解决原生模块与私有依赖。

## 何时触发

- 拆包 WorkBuddy Windows 安装包（NSIS → `app-64.7z` → `resources/app.asar`）。
- 需要替换 Electron 运行时、编译/替换 Linux `.node` 原生模块。
- 遇到 `SIGSEGV`（段错误）、`Cannot find module 'bindings'`、`ELECTRON_RUN_AS_NODE` ABI 问题。
- 移植后部分功能不可用（设备指纹/微信联动等）需评估与降级。

---

## 架构认知（动手前必读）

WorkBuddy 不是 VS Code 分支，结构如下：

```
app-64.7z 解压后/
  WorkBuddy.exe          # Windows Electron 二进制（不能直接用）
  resources/
    app.asar             # 应用代码（asar 归档，入口 package.json → main/index.js）
    app.asar.unpacked/   # ★ 原生模块与需解包的资源（移植主要改动点）
      node_modules/      # better-sqlite3 / node-pty / koffi / @tencent/*
      native/            # wechat-copydata-decoder（Windows 专属）
      resources/         # icon.png、插件、preload 脚本等
```

关键点：
- `main/*.js` 是 **webpack bundle**（`common.js` 2.7MB、`index.js` 867KB），
  纯 JS 依赖已被打进 bundle，**运行时只依赖 `app.asar.unpacked` 里的原生模块**。
  这大幅简化移植：只需处理少数几个 `.node`。
- 入口由 `app.asar/package.json` 的 `"main": "main/index.js"` 指定，
  Electron 会自动读取，无需额外配置。

## 移植方案（已验证可行）

**核心思路**：Windows 的 JS 代码（asar）+ Linux 的 Electron 运行时 + Linux 原生模块。

| 组成部分 | 来源 | 说明 |
|---|---|---|
| Electron 运行时 | CodeBuddy Linux deb 的 `usr/share/buddycn/buddycn` | Electron 37.7.0，ABI 136 |
| 应用代码 | 自拆 Windows 包的 `app.asar` | 版本需与运行时兼容 |
| 原生模块 | 部分自带 + 部分自编译/替换 | 见下表 |
| 私有依赖 | 制作 stub 降级 | 见后文 |

### 标准流程

1. **拆包 Windows 安装包**
   ```bash
   7z x -y -o wb_extract WorkBuddy-win32-x64-user-*.exe
   # 真实应用在 $PLUGINSDIR/app-64.7z
   7z x -y -o app64 "wb_extract/\$PLUGINSDIR/app-64.7z"
   ```

2. **检查原生模块**（决定需要补哪些）
   ```bash
   find app64/resources/app.asar.unpacked -name "*.node" | sed 's|.*unpacked/||'
   ```

3. **准备 Linux Electron 运行时**（从 CodeBuddy Linux deb）
   ```bash
   dpkg-deb -x CodeBuddy-linux-x64-*.deb cb_extract
   cp cb_extract/usr/share/buddycn/{buddycn,*.so,*.pak,icudtl.dat,chrome-sandbox} opt/workbuddy/
   rsync -a cb_extract/usr/share/buddycn/locales/ opt/workbuddy/locales/
   ```

4. **替换/编译原生模块**（见下表）

5. **组装 + 打包**（md5sums、Installed-Size、`--root-owner-group`）

### 原生模块处理清单（WorkBuddy 5.3.14 实测）

| 模块 | Windows 包内状态 | Linux 处理 | 结果 |
|---|---|---|---|
| koffi | 自带 `linux_x64/koffi.node` | **无需处理** | ✅ |
| better-sqlite3 | 仅 `win32-x64-136` | 自编译（Electron ABI 136） | ✅ |
| node-pty | 无 linux prebuild | npm 装 `@lydell/node-pty-linux-x64` | ✅ |
| @tencent/qimei-node | 仅 mac/win，无 linux | **制作 stub** | ⚠️ 遥测降级 |
| wechat-copydata-decoder | Windows 专属 | 代码已有 try/catch | ⚠️ 功能缺失 |

编译 better-sqlite3（Electron ABI 136）：
```bash
# Electron headers 可从 electronjs.org 获取（无需 GitHub）
curl -sL -o eh.tar.gz "https://artifacts.electronjs.org/headers/dist/v37.7.0/node-v37.7.0-headers.tar.gz"
tar -xzf eh.tar.gz -C eh
export npm_config_nodedir=$PWD/eh/node_headers
npm install better-sqlite3@12.8.0 --build-from-source
```

---

## ⚠️ 关键陷阱

### 陷阱 1：`Cannot find module 'bindings'` —— 只复制 `.node` 不够

自编译的 `better-sqlite3` 依赖 `bindings`（及 `file-uri-to-path`）在运行时定位 `.node`。
只把编译出的 `.node` 复制进 `app.asar.unpacked` 会报 `Cannot find module 'bindings'`。

✅ 必须连带复制其**运行时 JS 依赖**：
```bash
cp -a linux_native/node_modules/{bindings,file-uri-to-path} \
      wb_pkg/.../app.asar.unpacked/node_modules/
```

### 陷阱 2：ABI 不匹配导致 `SIGSEGV`（段错误，退出码 139）

**现象**：主进程 GUI 正常，但 daemon 子进程崩溃
`Daemon app-server exited before ready: code=null signal=SIGSEGV`

**原因**：daemon 以 `ELECTRON_RUN_AS_NODE=1` 启动（见 `main/index.js` 的 spawn 处），
此时进程是 **Node 22（ABI 127）**；而为 Electron 编译的模块是 **ABI 136**。
原生模块 ABI 强绑定，混用直接段错误。

**注意**：段错误发生在原生层，**JS 的 try/catch 无法拦截**。

**验证方法**（快速区分是否 ABI 问题）：
```bash
ELECTRON_RUN_AS_NODE=1 ./workbuddy-bin -e "require('<路径>/better_sqlite3.node')"
echo $?   # 139 = 段错误
```

**处理思路**：
- 按 `process.versions.modules` 做 ABI 分流加载（改 `lib/database.js`）；
- 但注意 **Electron 内嵌 Node 与同版本官方 Node 并非完全二进制兼容**，
  用官方 Node headers 编译的版本在 `RUN_AS_NODE` 下也可能崩溃（本例实测如此）。
- **✅ 最终解法（实测有效）**：换用与 WorkBuddy 5.3.14 原生匹配的 **Electron 39.2.7**
  运行时（借自社区移植版 `cn.workbuddy.otohime_5.3.14_amd64.deb`）后，
  daemon 的 SIGSEGV 完全消失。原因：Electron 39 的 RUN_AS_NODE 与主进程 ABI 一致，
  同一份 Linux 原生模块两个场景都能加载。
- 结论：**优先选与原应用 ABI 匹配的 Electron 大版本**，不要跨大版本借运行时
  （37→39 的 ABI 差异就会触发此坑）。

### 陷阱 3：腾讯私有包无法从 npm 获取

以下包在公开 npm 上不存在（私有/需鉴权），**无法安装，只能降级**：
`@tencent/qimei-node`、`@tencent/aegis-electron-sdk-v2`、
`@tencent/universal-report`、`@tencent/tencent-docs-ai-engine`

而公开可装的：
`better-sqlite3`、`@lydell/node-pty-linux-x64`、`koffi`、`@tencent-connect/qqbot-connector`

**stub 写法**（以 qimei 为例，避免加载 mac/win 原生二进制）：
```js
class QimeiStub {
    getVersion() { return ''; }
    getQimei36() { return Promise.resolve(''); }
    start() {} stop() {}
}
module.exports = QimeiStub;
```

### 陷阱 4：asar 提取可能报 ENOENT（可忽略）

```bash
asar extract app.asar out/   # 可能报 unpacked 内某文件缺失
```
只要主体目录（main/、resources/、package.json）提取出来即可，
缺失的是 unpacked 引用文件，不影响分析。

### 陷阱 5：网络 —— GitHub 不通但 npm 通

本环境实测：
- ❌ `github.com` 443 不通（无法下 Release 资产、无法 `gh auth login`）
- ✅ **SSH 到 GitHub 可用**（`git push` 正常）
- ✅ npm registry 通（`registry.npmjs.org`）
- ✅ `artifacts.electronjs.org` 通（可下 Electron headers）
- ✅ `registry.npmmirror.com` 通（可下 Node headers 等镜像资源）

**启示**：不要依赖"下载别人移植好的包"作为唯一路径，
利用 npm + npmmirror 完全可以自主编译所需原生模块。

---

## 实测结果（WorkBuddy 5.3.14 / deepin 25 / X11 / 最终版）

**最终方案**：官方 Windows `app.asar` + 社区移植版 **Electron 39.2.7** 运行时
+ 社区完整 Linux 原生模块（含 qimei-node 的 Linux 版）+ 启动脚本。

- ✅ SIGSEGV = 0（daemon 正常，不再崩溃）
- ✅ GUI 窗口正常（标题栏三键显示，`--title-bar-style=custom` 生效）
- ✅ `CellJS container initialized`、**`signalStartupFirstPaint` 首帧绘制完成**（页面内容正常渲染，非空白）
- ✅ 原生模块 better-sqlite3 / node-pty / koffi / qimei 加载正常
- ✅ 遥测与配置下发正常（`publishResolvedConfiguration ... Connector: true`）
- ✅ 平台识别 `workbuddy-linux-x64`、系统 git/python/node 自动使用
- ⚠️ 微信消息解码（wechat-copydata-decoder）为 Windows 专属，缺失自动降级

> 与社区结论一致：此类移植**部分功能可用**是正常预期。

### 标题栏三键修复（重要）

WorkBuddy 是自绘标题栏应用，Linux 下若三键不显示，启动时加：
```bash
--title-bar-style=custom
```
该参数让 WorkBuddy 自绘的标题栏（右上角最小化/最大化/关闭）正常显示。
否则窗口 `_MOTIF_WM_HINTS` decorations=0 且无三键。

## 验证清单

1. `dpkg-deb -c out.deb` 文件齐全、symlink 正确。
2. `ls .../app.asar.unpacked/node_modules/` 含 `bindings`、`file-uri-to-path`。
3. 启动后 `xdotool search --name WorkBuddy` 能查到窗口。
4. 日志确认 `CellJS container initialized` 且无模块加载错误。
5. 已知限制写入 `control` 的 `Description`，避免使用者误解。

## 关联

- 同类技能：`traework-deb-repack`（VS Code 分支的移植，可对比参考）
- 一键脚本：`workbuddy-build/scripts/build-workbuddy.sh`（拆包→组装→仅产出 deb）
  ```bash
  bash build-workbuddy.sh                          # 自动找源材料
  bash build-workbuddy.sh <win.exe> <社区.deb>      # 显式指定
  bash build-workbuddy.sh --skip-extract --no-install   # 仅重算并构建 deb
  bash build-workbuddy.sh --install-deps            # 装依赖
  ```
- 本技能产物：`workbuddy-build/workbuddy_5.3.14-2_amd64.deb`
