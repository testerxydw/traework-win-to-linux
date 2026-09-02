---
name: traework-deb-repack
description: "TraeWork CN（TRAE SOLO）Windows 安装包拆包并重新打包为 Linux deb/玲珑 uab 的标准流程与踩坑手册。当用户需要对 trae-solo-cn 的 .deb 进行拆包、修改启动脚本/标题栏、重打包、修复 main.js、调整 md5sums/Installed-Size、或处理 usr/bin 软链接陷阱时使用。也适用于 build.sh 流水线之外的手工二次打包、标题栏三键缺失修复、deb 调试。"
---

# TraeWork CN → Linux deb 拆包重打包技能

本技能固化 TraeWork CN（TRAE SOLO，VS Code 1.107.1 内核 fork）从 Windows 安装包
拆包、植入 Linux Electron 运行时、修复标题栏、重新打包为 deb（默认）的完整流程，
玲珑 uab 为可选项（需 `build.sh --ll`）。
并重点记录一系列**只有踩过坑才知道的陷阱**。

> ⚠️ 非官方移植，仅供学习交流，版权归原开发方（ByteDance）所有。

## 何时触发

- 用户要求「拆包 / 解包 / 重打包 trae 的 deb」「修改启动脚本」「修复标题栏/三键」。
- 安装后应用没有标题栏、没有最小/最大/关闭三键、出现白块遮挡。
- 需要手工改 `opt/trae-solo-cn/trae-solo-cn` 启动脚本参数或 `main.js`。
- 改了文件但打进包里没生效（symlink 陷阱）。
- 维护 `build.sh` 流水线或 `deb-pkg/` 打包目录。

## 目录约定（本项目）

```
build.sh                            # 唯一构建入口（默认拆包→精简→deb→安装；玲珑需 --ll），本技能是其补充
deb-pkg/                            # 打包根目录（最终 dpkg-deb --build 的对象）
  DEBIAN/                          # control / postinst / prerm / postrm / md5sums
  opt/trae-solo-cn/                # 真实安装内容（启动脚本、Electron 二进制、resources/app）
    trae-solo-cn                   # ★ 真实启动脚本（bash 包装器）
    trae-solo-cn-bin               # Electron 二进制（由 build.sh 从 TraeCode 复制）
    resources/app/                 # JS 资源（out/、product.json、node_modules 等）
  usr/bin/trae-solo-cn             # ★ symlink → /opt/trae-solo-cn/trae-solo-cn（陷阱点）
```

> 一键场景请直接用 `bash build.sh`（详见项目 README.md）。本技能侧重
> **流水线之外的手工二次打包 / 调试 / 故障修复**。

---

## 标准流程（手工拆包重打包）

### 步骤 1 — 解包现有 deb

```bash
SRC_DEB=trae-solo-cn_0.1.61-1_amd64.deb   # 以实际产物为准
WORK=/tmp/trae_extract
rm -rf "$WORK" && mkdir -p "$WORK"/{data,ctrl}
dpkg-deb -x "$SRC_DEB" "$WORK/data"     # 解数据文件
dpkg-deb -e "$SRC_DEB" "$WORK/ctrl"     # 解 DEBIAN 控制信息
```

### 步骤 2 — 修改内容（重点看下面的陷阱）

常见修改：
- 改标题栏参数：编辑 `opt/trae-solo-cn/trae-solo-cn`（**真实脚本**，见陷阱 1）。
- 改渲染层：编辑 `opt/trae-solo-cn/resources/app/out/main.js`（见陷阱 2）。
- 增删文件：直接放进 `$WORK/data/opt/trae-solo-cn/...`。

### 步骤 3 — 重算 md5sums（必做！否则 dpkg 校验失败）

```bash
cd "$WORK/data"
: > "$WORK/ctrl/md5sums"
find . -path ./DEBIAN -prune -o -type f -print0 \
  | xargs -0 md5sum | sed 's| \./| |' > "$WORK/ctrl/md5sums"
# 注意：md5sums 路径是相对 deb-pkg 根（不含 ./ 前缀），且必须覆盖所有数据文件
```

### 步骤 4 — （可选）修正 Installed-Size

`DEBIAN/control` 的 `Installed-Size`（单位 KiB）若与实际不符，系统「应用管理」
会显示错误体积。重算：

```bash
size=$(du -s --block-size=1K --exclude=DEBIAN "$WORK/data" | cut -f1)
sed -i "s/^Installed-Size: .*/Installed-Size: $size/" "$WORK/ctrl/control"
```

### 步骤 5 — 重新打包

```bash
dpkg-deb --build --root-owner-group "$WORK/data" out.deb
# 校验
dpkg-deb -I out.deb    # 看 control / md5sums
dpkg-deb -c out.deb    # 看文件列表
```

---

## 版本号同步（重要，曾长期脱节）

`deb-pkg/DEBIAN/control` 的 `Version` **不再写死**，每次 `build.sh` 阶段 4（构建 deb）
从 `opt/trae-solo-cn/manifest.json` 的 `appVersion` 字段同步：

- `appVersion`（如 `0.1.61`）才是 TRAE SOLO 的真实**发布版本**，由 `stage_extract`
  从 TraeWork 安装包复制进 `deb-pkg`。
- `product.json` 的 `version`（如 `1.107.1`）是 VS Code **内核版本体系**，**不是**
  solo 发布版本，严禁用作 deb 版本号。
- 同步规则：同 `appVersion` 仅自增修订号（`0.1.61-1` → `-2` …）；安装包升级致
  `appVersion` 变化则重置为 `-1`。
- 手工二次打包时，务必把 `control` 的 `Version` 改成与 `manifest.json` 的
  `appVersion` 一致，否则版本标示与安装包脱节（旧版曾固定 `0.1.58` 一路错标）。

---

## ⚠️ 关键陷阱（务必先读）

### 陷阱 1：`usr/bin/trae-solo-cn` 是 symlink，改错文件全白干

解包后 `usr/bin/trae-solo-cn` 是一个**符号链接**，指向 `/opt/trae-solo-cn/trae-solo-cn`
（绝对路径）。真实启动脚本在 `opt/trae-solo-cn/trae-solo-cn`。

- ❌ 错误：用 `write_to_file` / `replace_in_file` 工具直接写 `usr/bin/trae-solo-cn`
  —— 工具会跟随 symlink 改写**系统已安装的** `/opt/trae-solo-cn/trae-solo-cn`，
  但重新打包时读的是解包目录里的 symlink 本身，**内容不变，等于没改**。
- ❌ 错误：`sed -i` 直接在 symlink 上操作同理会改写目标真实文件，解包副本无变化。
- ✅ 正确：**直接编辑解包目录里的真实文件** `opt/trae-solo-cn/trae-solo-cn`，
  不要碰 `usr/bin/` 下的 symlink。打包时 symlink 原样保留即可。

> 验证方法：`ls -la "$WORK/data/usr/bin/trae-solo-cn"` 确认是 `-> /opt/...` 的链接；
> 改完后 `grep --title-bar-style "$WORK/data/opt/trae-solo-cn/trae-solo-cn"` 确认命中。

### 陷阱 2：`main.js` 是 minify 产物，补丁与版本强绑定

`resources/app/out/main.js` 是压缩后的代码，关键的标题栏逻辑形如
（0.1.58 示例，变量名随版本变化）：

```js
function oW(t){if(rl)return"custom";          // 标题栏样式解析，Lt=isLinux
l.titleBarOverlay={height:29,color:p,symbolColor:b}
```

- 该补丁**只对特定版本的 minify 变量名有效**。未来版本变量名（如 `oW/Lt/rl`）
  可能改变，补丁会 miss。
- 补丁策略（见 build.sh `stage_extract`）：
  1. `oW` 函数内注入 `if(Lt)return"native";` —— Linux 强制 native 标题栏
     （恢复 0.1.54 行为，避免深/统信桌面下 `frame:false` 变无边框空白窗）。
  2. `titleBarOverlay` 设置前加 `Lt||` 守卫 —— Linux 跳过 overlay，双保险。
- ✅ 应用前先 `grep -c` 校验两个锚点各出现 1 次；否则降级为警告，不强行替换
  （强行 replace 会破坏 JS 语法）。
- ⚠️ `product.json` 的 `configurationDefaults.window.titleBarStyle` **对主进程建窗无效**
  （主进程只读简化版配置缓存），只能作为渲染层辅助，**真正的修复必须进 `main.js`**。

### 陷阱 3：标题栏方案要在「native 自绘」间选对

| 方案 | 效果 | 何时用 |
|------|------|--------|
| `--title-bar-style=custom` | VS Code 自绘标题栏，自带三键 | 想保留原生三键但样式统一 |
| `main.js` 强制 `native` + 跳过 titleBarOverlay | 用系统标题栏（DDE 原生三键） | 0.1.58 在 DDE 下白块遮挡，用此方案 |
| 仅 `--no-sandbox` 之类 | 与标题栏无关 | 仅解决沙箱启动报错 |

> 之前在 DDE 上「装了 10/11/12 版仍无标题栏三键」的根因就是：
> 改的是 symlink（陷阱 1），真实脚本未变 → 没有任何标题栏参数进包。
> 修正为改真实脚本 `opt/trae-solo-cn/trae-solo-cn` 的 `exec "$ELECTRON" "$@"` 行即可。

### 陷阱 4：dpkg-deb 权限与属主

- 必须用 `--root-owner-group`，否则包内文件属主是构建者 UID，安装后权限错乱。
- 维护脚本 `postinst/prerm/postrm` 必须是 `0755`，否则 dpkg 报警告甚至拒绝。
- `chrome-sandbox` 需 `4755`（setuid）才能正常沙箱；本移植通常用 `--no-sandbox`，
  见 `fix-linglong-yaml.py` 与启动脚本。

### 陷阱 5：Windows 安装包格式随版本变化

- 0.1.58 起为 **Inno Setup 6.4**，需 `innoextract >= 1.10`（发行版 apt 只有 1.9，
  无法解析，需自编译 master 分支）。
- 0.1.54 及更早为 **NSIS**，用 `7z` 解压即可。
- 解压后内容在 `code$GetDestDir/resources/app/`。

---

## 验证清单（交付前必查）

1. `dpkg-deb -c out.deb` 文件齐全，`usr/bin/trae-solo-cn` 仍是 symlink。
2. `dpkg-deb -I out.deb | grep -A40 control` 看 `Installed-Size` 合理。
3. `grep -c 'title-bar-style\|titleBarOverlay\|return"native"' opt/.../trae-solo-cn` 确认改生效。
4. 安装：`sudo dpkg -i out.deb`，启动确认标题栏与三键出现。
5. 若仍无标题栏：确认 X11/Wayland（`echo $XDG_SESSION_TYPE`），可能是 workbench 渲染层
   而非配置问题，需进一步 patch `out/main.js` 的建窗逻辑。

## 关联

- 主流程：`build.sh`（默认拆包→deb→安装；`--ll` 加玲珑、`--no-install` 跳过安装）
- 玲珑适配：`scripts/fix-linglong-yaml.py`
- 设计文档：`docs/superpowers/specs/`、`docs/superpowers/plans/`
- 功能清单：`README-功能说明.md`
