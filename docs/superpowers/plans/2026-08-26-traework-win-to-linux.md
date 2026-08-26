# TraeWork CN Windows → Linux deb 重打包实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 TraeWork CN Windows 安装包解包后，替换 Windows Electron 运行时为 Linux 版本，恢复可用的公共 npm 原生包，重新打包为 deb 安装到 /opt/trae-solo-cn/。

**Architecture:** 从 VSCode 1.107.1 Linux x64 提取 Electron 运行时，与 TraeWork 的跨平台应用资源组合，安装/编译 Linux 原生 npm 包替代 Windows 版，移除 Windows 专用模块，创建启动脚本含不可用功能提示，最终用 dpkg-deb 构建 deb 包。

**Tech Stack:** innoextract (已编译), VSCode Linux tar.gz, dpkg-deb, npm rebuild, shell scripts

**Spec:** `docs/superpowers/specs/2026-08-26-traework-win-to-linux-design.md`

---

### Task 1: 下载并提取 VSCode Linux Electron 运行时

**Files:**
- Download: `/tmp/vscode-linux.tar.gz`
- Extract to: `/tmp/vscode-linux/VSCode-linux-x64/`

- [ ] **Step 1: 下载 VSCode 1.107.1 Linux x64**

```bash
curl -L --max-time 600 "https://update.code.visualstudio.com/1.107.1/linux-x64/stable" -o /tmp/vscode-linux.tar.gz
```

Expected: 文件约 155MB，下载完成后 `file /tmp/vscode-linux.tar.gz` 显示 gzip compressed data

- [ ] **Step 2: 解压 VSCode Linux**

```bash
rm -rf /tmp/vscode-linux
mkdir -p /tmp/vscode-linux
tar xzf /tmp/vscode-linux.tar.gz -C /tmp/vscode-linux
ls /tmp/vscode-linux/VSCode-linux-x64/
```

Expected: 包含 `code`, `*.pak`, `icudtl.dat`, `snapshot_blob.bin`, `v8_context_snapshot.bin`, `locales/`, `resources/` 等文件

- [ ] **Step 3: 验证 Linux Electron 二进制**

```bash
file /tmp/vscode-linux/VSCode-linux-x64/code
```

Expected: ELF 64-bit LSB executable, x86-64

---

### Task 2: 创建 deb 包目录结构

**Files:**
- Create: `/media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux/deb-pkg/` 整个目录树

- [ ] **Step 1: 创建基础目录结构**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux
rm -rf deb-pkg
mkdir -p deb-pkg/opt/trae-solo-cn
mkdir -p deb-pkg/opt/trae-solo-cn/resources/app
mkdir -p deb-pkg/opt/trae-solo-cn/resources/app/bin
mkdir -p deb-pkg/opt/trae-solo-cn/locales
mkdir -p deb-pkg/opt/trae-solo-cn/win-dlls
mkdir -p deb-pkg/opt/trae-solo-cn/aha_doctor
mkdir -p deb-pkg/usr/share/applications
mkdir -p deb-pkg/usr/share/icons/hicolor/256x256/apps
mkdir -p deb-pkg/usr/bin
mkdir -p deb-pkg/DEBIAN
```

- [ ] **Step 2: 验证目录结构**

```bash
find deb-pkg -type d | sort
```

Expected: 显示上述所有目录

---

### Task 3: 复制 Linux Electron 运行时文件

**Files:**
- Source: `/tmp/vscode-linux/VSCode-linux-x64/`
- Dest: `deb-pkg/opt/trae-solo-cn/`

- [ ] **Step 1: 复制 Electron 二进制和运行时文件**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux
VSCODE_DIR=/tmp/vscode-linux/VSCode-linux-x64
DEB_DIR=deb-pkg/opt/trae-solo-cn

# 复制 Electron 二进制
cp "$VSCODE_DIR/code" "$DEB_DIR/"
chmod 755 "$DEB_DIR/code"

# 复制运行时数据文件
for f in *.pak icudtl.dat snapshot_blob.bin v8_context_snapshot.bin; do
  [ -f "$VSCODE_DIR/$f" ] && cp "$VSCODE_DIR/$f" "$DEB_DIR/"
done

# 复制 locales
cp -r "$VSCODE_DIR/locales/"* "$DEB_DIR/locales/"
```

- [ ] **Step 2: 验证复制结果**

```bash
ls -lah deb-pkg/opt/trae-solo-cn/code
ls deb-pkg/opt/trae-solo-cn/*.pak
ls deb-pkg/opt/trae-solo-cn/locales/ | head -5
```

Expected: code 二进制可执行，.pak 文件和 locales 存在

---

### Task 4: 复制 TraeWork 跨平台应用资源

**Files:**
- Source: `extracted/code$GetDestDir/resources/app/`
- Dest: `deb-pkg/opt/trae-solo-cn/resources/app/`

- [ ] **Step 1: 复制核心应用资源（out, extensions, modules, node_modules）**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux
SRC="extracted/code\$GetDestDir/resources/app"
DST=deb-pkg/opt/trae-solo-cn/resources/app

# 复制跨平台目录
cp -r "$SRC/out" "$DST/"
cp -r "$SRC/extensions" "$DST/"
cp -r "$SRC/modules" "$DST/"
cp -r "$SRC/node_modules" "$DST/"
cp -r "$SRC/licenses" "$DST/" 2>/dev/null

# 复制配置文件
cp "$SRC/package.json" "$DST/"
cp "$SRC/product.json" "$DST/"
cp "$SRC/LICENSE.txt" "$DST/" 2>/dev/null
cp "$SRC/ThirdPartyNotices.txt" "$DST/" 2>/dev/null
cp "$SRC/node_modules.asar" "$DST/" 2>/dev/null
```

- [ ] **Step 2: 验证复制结果**

```bash
du -sh deb-pkg/opt/trae-solo-cn/resources/app/*/
```

Expected: out(~50M), extensions(~87M), modules(~665M), node_modules(~263M)

---

### Task 5: 修改 product.json 为 Linux 平台

**Files:**
- Modify: `deb-pkg/opt/trae-solo-cn/resources/app/product.json`

- [ ] **Step 1: 修改 buildPlatform 和移除 Windows 专用字段**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux
python3 -c "
import json

with open('deb-pkg/opt/trae-solo-cn/resources/app/product.json', 'r') as f:
    data = json.load(f)

# 修改平台信息
data['buildPlatform'] = 'linux'

# 写回
with open('deb-pkg/opt/trae-solo-cn/resources/app/product.json', 'w') as f:
    json.dump(data, f, indent='\t')

print('buildPlatform changed to:', data['buildPlatform'])
"
```

Expected: 输出 `buildPlatform changed to: linux`

- [ ] **Step 2: 验证修改**

```bash
python3 -c "import json; d=json.load(open('deb-pkg/opt/trae-solo-cn/resources/app/product.json')); print('buildPlatform:', d['buildPlatform']); print('buildArch:', d['buildArch'])"
```

Expected: `buildPlatform: linux`, `buildArch: x64`

- [ ] **Step 3: Commit**

```bash
git add deb-pkg/
git commit -m "feat: copy app resources and set buildPlatform to linux"
```

---

### Task 6: 安装 Linux 原生 npm 包（优先恢复）

**Files:**
- Install into: `deb-pkg/opt/trae-solo-cn/resources/app/node_modules/`

- [ ] **Step 1: 安装 @parcel/watcher Linux 版**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux/deb-pkg/opt/trae-solo-cn/resources/app
npm install @parcel/watcher-linux-x64-glibc@2.5.4 --no-save --ignore-scripts 2>&1 | tail -5
ls node_modules/@parcel/watcher-linux-x64-glibc/ 2>/dev/null
```

Expected: 安装成功，目录存在且包含 `watcher.node`

- [ ] **Step 2: 安装 ripgrep Linux 版**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux/deb-pkg/opt/trae-solo-cn/resources/app
npm install @byted-fe/ripgrep-linux-x64@1.0.3 --no-save --ignore-scripts 2>&1 | tail -5
ls node_modules/@byted-fe/ripgrep-linux-x64/ 2>/dev/null
```

Expected: 安装成功（如果公共 registry 有的话），否则记录失败

- [ ] **Step 3: 尝试 rebuild node-pty**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux/deb-pkg/opt/trae-solo-cn/resources/app
# 先检查是否有编译工具
which gcc g++ make python3 2>/dev/null
# 尝试 rebuild
cd node_modules/node-pty && npm run rebuild 2>&1 | tail -10 || echo "node-pty rebuild failed (expected - needs Linux build tools)"
```

Expected: 如果 build tools 可用则编译成功，否则记录需要安装 build-essential

- [ ] **Step 4: 尝试 rebuild native-keymap**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux/deb-pkg/opt/trae-solo-cn/resources/app/node_modules/native-keymap
npm run rebuild 2>&1 | tail -10 || echo "native-keymap rebuild failed"
```

- [ ] **Step 5: 移除 Windows 专用 .node 文件**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux/deb-pkg/opt/trae-solo-cn/resources/app

# 移除 Windows 专用原生模块
for mod in windows-foreground-love native-is-elevated registry-js; do
  if [ -d "node_modules/$mod" ]; then
    rm -rf "node_modules/$mod/build"
    echo "Removed build/ for $mod"
  fi
done

# 移除 Windows 专用 @aha-kit 平台包
for pkg in net-win32-x64-msvc ipc-win32-x64 perf-sdk-win32-x64; do
  if [ -d "node_modules/@aha-kit/$pkg" ]; then
    rm -rf "node_modules/@aha-kit/$pkg"
    echo "Removed @aha-kit/$pkg"
  fi
done

# 移除 Windows 专用 @byted-icube 平台包
for pkg in trae-network-client-win32-x64-msvc; do
  if [ -d "node_modules/@byted-icube/$pkg" ]; then
    rm -rf "node_modules/@byted-icube/$pkg"
    echo "Removed @byted-icube/$pkg"
  fi
done
```

- [ ] **Step 6: Commit**

```bash
git add deb-pkg/
git commit -m "feat: install Linux native npm packages, remove Windows-only modules"
```

---

### Task 7: 处理 Windows 专有 DLL 和工具

**Files:**
- Move to: `deb-pkg/opt/trae-solo-cn/win-dlls/`
- Create: `deb-pkg/opt/trae-solo-cn/resources/app/bin/fetch`
- Create: `deb-pkg/opt/trae-solo-cn/resources/app/bin/ffmpeg`
- Create: `deb-pkg/opt/trae-solo-cn/resources/app/bin/ffprobe`
- Create: `deb-pkg/opt/trae-solo-cn/aha_doctor/aha_doctor`

- [ ] **Step 1: 移动 Windows 专有 DLL 到 win-dlls/**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux
SRC="extracted/code\$GetDestDir"

for dll in aha_kit_wer.dll aha_net.dll doctor_sdk.dll innoplugin.dll \
           logifier_retrieval.dll metasecml.dll simplelog.dll sscronet.dll \
           TTNetDownloaderCrossPlatform.dll; do
  [ -f "$SRC/$dll" ] && cp "$SRC/$dll" deb-pkg/opt/trae-solo-cn/win-dlls/
done

ls -la deb-pkg/opt/trae-solo-cn/win-dlls/
```

Expected: 9 个 DLL 文件

- [ ] **Step 2: 创建 fetch 包装脚本**

```bash
cat > deb-pkg/opt/trae-solo-cn/resources/app/bin/fetch << 'SCRIPT'
#!/bin/sh
# fetch wrapper - replaces Windows fetch.exe with curl
if command -v curl >/dev/null 2>&1; then
    exec curl -fSL "$@"
else
    echo "Error: curl is required but not installed" >&2
    echo "Install with: sudo apt install curl" >&2
    exit 1
fi
SCRIPT
chmod 755 deb-pkg/opt/trae-solo-cn/resources/app/bin/fetch
```

- [ ] **Step 3: 创建 ffmpeg/ffprobe 包装脚本**

```bash
cat > deb-pkg/opt/trae-solo-cn/resources/app/bin/ffmpeg << 'SCRIPT'
#!/bin/sh
# ffmpeg wrapper - uses system ffmpeg
if command -v ffmpeg >/dev/null 2>&1; then
    exec ffmpeg "$@"
else
    echo "Error: ffmpeg is required but not installed" >&2
    echo "Install with: sudo apt install ffmpeg" >&2
    exit 1
fi
SCRIPT
chmod 755 deb-pkg/opt/trae-solo-cn/resources/app/bin/ffmpeg

cat > deb-pkg/opt/trae-solo-cn/resources/app/bin/ffprobe << 'SCRIPT'
#!/bin/sh
# ffprobe wrapper - uses system ffprobe
if command -v ffprobe >/dev/null 2>&1; then
    exec ffprobe "$@"
else
    echo "Error: ffmpeg is required but not installed" >&2
    echo "Install with: sudo apt install ffmpeg" >&2
    exit 1
fi
SCRIPT
chmod 755 deb-pkg/opt/trae-solo-cn/resources/app/bin/ffprobe
```

- [ ] **Step 4: 创建 aha_doctor 占位脚本**

```bash
cat > deb-pkg/opt/trae-solo-cn/aha_doctor/aha_doctor << 'SCRIPT'
#!/bin/sh
echo "=========================================="
echo " TRAE SOLO CN - aha_doctor (Linux 版)"
echo "=========================================="
echo ""
echo "aha_doctor 诊断工具在 Linux 上不可用。"
echo "该工具的原生 Windows 版本未包含在此安装包中。"
echo ""
echo "如需诊断支持，请检查："
echo "  - 日志文件: ~/.config/trae-solo-cn/logs/"
echo "  - 系统日志: journalctl --user -u trae-solo-cn"
echo ""
exit 1
SCRIPT
chmod 755 deb-pkg/opt/trae-solo-cn/aha_doctor/aha_doctor
```

- [ ] **Step 5: Commit**

```bash
git add deb-pkg/
git commit -m "feat: handle Windows DLLs, create tool wrappers and placeholders"
```

---

### Task 8: 创建启动脚本（含不可用功能提示）

**Files:**
- Create: `deb-pkg/opt/trae-solo-cn/trae-solo-cn`

- [ ] **Step 1: 创建主启动脚本**

```bash
cat > deb-pkg/opt/trae-solo-cn/trae-solo-cn << 'SCRIPT'
#!/bin/bash
# TRAE SOLO CN - Linux Launcher
# Repackaged from Windows installer with Linux Electron runtime

APP_NAME="TRAE SOLO CN"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ELECTRON="$APP_DIR/code"
CLI="$APP_DIR/resources/app/out/cli.js"
DATA_FOLDER="$HOME/.config/trae-solo-cn"
WARNING_FLAG="$DATA_FOLDER/linux-warning-shown"

# Handle special arguments
case "$1" in
    --reset-warnings)
        rm -f "$WARNING_FLAG"
        echo "Warning notifications have been reset."
        shift
        ;;
esac

# Show one-time Linux compatibility warning
if [ ! -f "$WARNING_FLAG" ]; then
    mkdir -p "$DATA_FOLDER"
    
    MSG="TRAE SOLO CN (Linux 版)\n\n以下功能在当前 Linux 环境下不可用：\n  • AI 网络服务（TTNet）— 部分在线功能可能受限\n  • 安全模块 / 错误上报 / 诊断工具\n  • 自动更新（请使用 apt upgrade 更新）\n\n核心编辑器功能不受影响。"
    
    if command -v zenity >/dev/null 2>&1; then
        zenity --info --title="$APP_NAME" --text="$MSG" --width=400 --ok-label="确定" 2>/dev/null
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "$APP_NAME" "部分功能在 Linux 上不可用。运行 trae-solo-cn --reset-warnings 可重新显示提示。" 2>/dev/null
    else
        echo "=== $APP_NAME (Linux) ==="
        echo -e "$MSG"
        echo "================================"
    fi
    
    touch "$WARNING_FLAG"
fi

# Launch
exec "$ELECTRON" "$CLI" --app-path="$APP_DIR" "$@"
SCRIPT
chmod 755 deb-pkg/opt/trae-solo-cn/trae-solo-cn
```

- [ ] **Step 2: 验证脚本**

```bash
head -5 deb-pkg/opt/trae-solo-cn/trae-solo-cn
file deb-pkg/opt/trae-solo-cn/trae-solo-cn
```

Expected: bash script, executable

- [ ] **Step 3: Commit**

```bash
git add deb-pkg/
git commit -m "feat: create launcher script with Linux compatibility warning"
```

---

### Task 9: 创建 .desktop 文件和符号链接

**Files:**
- Create: `deb-pkg/usr/share/applications/trae-solo-cn.desktop`
- Create: `deb-pkg/usr/share/icons/hicolor/256x256/apps/trae-solo-cn.png`
- Symlink: `deb-pkg/usr/bin/trae-solo-cn`

- [ ] **Step 1: 复制应用图标**

```bash
cp /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux/trae-icon-256.png \
   /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux/deb-pkg/usr/share/icons/hicolor/256x256/apps/trae-solo-cn.png
```

- [ ] **Step 2: 创建 .desktop 文件**

```bash
cat > deb-pkg/usr/share/applications/trae-solo-cn.desktop << 'DESKTOP'
[Desktop Entry]
Name=TRAE SOLO CN
Comment=AI-powered code editor (Linux port)
GenericName=Code Editor
Exec=/opt/trae-solo-cn/trae-solo-cn %F
Icon=trae-solo-cn
Type=Application
StartupNotify=true
StartupWMClass=trae-solo-cn
Categories=Development;IDE;TextEditor;
MimeType=text/plain;inode/directory;
Actions=new-window;

[Desktop Action new-window]
Name=New Window
Exec=/opt/trae-solo-cn/trae-solo-cn --new-window %F
Icon=trae-solo-cn
DESKTOP
```

- [ ] **Step 3: 创建 /usr/bin 符号链接**

```bash
ln -sf /opt/trae-solo-cn/trae-solo-cn deb-pkg/usr/bin/trae-solo-cn
```

- [ ] **Step 4: 验证**

```bash
ls -la deb-pkg/usr/bin/trae-solo-cn
ls -la deb-pkg/usr/share/applications/trae-solo-cn.desktop
ls -la deb-pkg/usr/share/icons/hicolor/256x256/apps/trae-solo-cn.png
```

- [ ] **Step 5: Commit**

```bash
git add deb-pkg/
git commit -m "feat: add .desktop file, icon, and /usr/bin symlink"
```

---

### Task 10: 创建 DEBIAN 控制文件并构建 deb 包

**Files:**
- Create: `deb-pkg/DEBIAN/control`
- Create: `deb-pkg/DEBIAN/postinst`
- Create: `deb-pkg/DEBIAN/prerm`
- Output: `trae-solo-cn_0.1.54_amd64.deb`

- [ ] **Step 1: 创建 DEBIAN/control**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux

# 计算安装大小
INSTALLED_SIZE=$(du -sk deb-pkg/opt/ | cut -f1)

cat > deb-pkg/DEBIAN/control << EOF
Package: trae-solo-cn
Version: 0.1.54
Section: editors
Priority: optional
Architecture: amd64
Installed-Size: $INSTALLED_SIZE
Maintainer: TraeWork CN Linux Packager <noreply@trae.com.cn>
Description: TRAE SOLO CN - AI-powered code editor (Linux port)
 TraeWork CN is an AI-powered code editor based on VS Code,
 developed by ByteDance. This is a Linux port repackaged from
 the Windows installer with Linux Electron runtime.
 .
 Note: Some ByteDance proprietary features (TTNet networking,
 security module, diagnostics) are not available on Linux.
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0, libsecret-1-0, libgbm1
Recommends: ffmpeg, curl
EOF
```

- [ ] **Step 2: 创建 postinst 脚本**

```bash
cat > deb-pkg/DEBIAN/postinst << 'POSTINST'
#!/bin/sh
set -e

# Update desktop database
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications/ 2>/dev/null || true
fi

# Update icon cache
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q /usr/share/icons/hicolor/ 2>/dev/null || true
fi

echo "TRAE SOLO CN has been installed to /opt/trae-solo-cn/"
echo "Run 'trae-solo-cn' from terminal or find it in your application menu."
POSTINST
chmod 755 deb-pkg/DEBIAN/postinst
```

- [ ] **Step 3: 创建 prerm 脚本**

```bash
cat > deb-pkg/DEBIAN/prerm << 'PRERM'
#!/bin/sh
set -e

# Clean up desktop database
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications/ 2>/dev/null || true
fi
PRERM
chmod 755 deb-pkg/DEBIAN/prerm
```

- [ ] **Step 4: 构建 deb 包**

```bash
cd /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux
dpkg-deb --build --root-owner-group deb-pkg trae-solo-cn_0.1.54_amd64.deb 2>&1
```

Expected: 构建成功，输出 `dpkg-deb: building package 'trae-solo-cn' in 'trae-solo-cn_0.1.54_amd64.deb'`

- [ ] **Step 5: 验证 deb 包**

```bash
ls -lah trae-solo-cn_0.1.54_amd64.deb
dpkg-deb --info trae-solo-cn_0.1.54_amd64.deb
dpkg-deb --contents trae-solo-cn_0.1.54_amd64.deb | head -30
```

Expected: 显示正确的包信息，包含 /opt/trae-solo-cn/ 下的所有文件

- [ ] **Step 6: Commit**

```bash
git add deb-pkg/DEBIAN/ trae-solo-cn_0.1.54_amd64.deb
git commit -m "feat: build trae-solo-cn_0.1.54_amd64.deb package"
```

---

### Task 11: 测试安装和启动

- [ ] **Step 1: 安装 deb 包**

```bash
sudo dpkg -i /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux/trae-solo-cn_0.1.54_amd64.deb 2>&1
# 如果有依赖问题，修复
sudo apt-get install -f -y 2>&1 | tail -5
```

- [ ] **Step 2: 验证安装**

```bash
which trae-solo-cn
ls -la /opt/trae-solo-cn/code
ls /opt/trae-solo-cn/resources/app/product.json
python3 -c "import json; d=json.load(open('/opt/trae-solo-cn/resources/app/product.json')); print('Platform:', d['buildPlatform'])"
```

Expected: 命令可用，product.json 显示 Platform: linux

- [ ] **Step 3: 测试启动（命令行）**

```bash
# 仅测试二进制是否能启动（不等待 GUI）
timeout 5 /opt/trae-solo-cn/code --version 2>&1 || true
timeout 5 /opt/trae-solo-cn/code --no-sandbox --version 2>&1 || true
```

Expected: 应输出 Electron/Chromium 版本号，或至少不报 "not found" 类错误

- [ ] **Step 4: 记录问题并清理**

```bash
# 如果测试发现问题，记录到文件
cat > /media/dp25/DATA/deb/fcitx5-deb/traework-win-to-linux/TESTING-NOTES.md << 'NOTES'
# Testing Notes

## Installation
- deb package built successfully
- Installation path: /opt/trae-solo-cn/

## Known Issues
- (To be filled after testing)

## Restored Features
- @parcel/watcher: Linux version installed
- node-pty: (rebuilt / needs rebuild)
- native-keymap: (rebuilt / needs rebuild)

## Non-functional Features
- TTNet networking (private npm package unavailable)
- Security module (metasecml.dll - Electron binary level)
- Diagnostics (aha_doctor - Windows only)
- Auto-update (use apt upgrade instead)
NOTES
```
