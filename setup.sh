#!/usr/bin/env bash
# ============================================================================
# TRAE SOLO CN Linux 打包 —— 源文件提取脚本
# 功能：从两个源重建 deb-pkg/ 中的大文件内容：
#   1. TraeWork CN Windows 安装包 (.exe, NSIS) —— 提供 JS 资源与 solo-lite UI
#   2. TraeCode CN Linux deb (.deb) —— 提供 Electron 运行时与原生模块
#
# 用法：
#   bash setup.sh /path/to/TraeWork_CN-Setup-x64.exe
#   或（已解压过安装包）：
#   bash setup.sh --extracted /path/to/extracted/code\$GetDestDir
#
# 自动识别安装包格式：
#   - Inno Setup（0.1.58 起）：需要 innoextract >= 1.10；发行版自带的 1.9 过旧，
#     优先使用本目录 .innoextract-src/build/innoextract（自编译版）
#   - NSIS（0.1.54 及更早）：使用 7z (p7zip-full)
# 完成后执行：bash build.sh 构建 deb 包
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/deb-pkg"
APP_DIR="${PKG_DIR}/opt/trae-solo-cn"
RES_DIR="${APP_DIR}/resources/app"

# TraeCode Linux 安装路径（已安装）；若未安装可通过 deb 包提取
TRAECODE_INSTALLED="/usr/share/trae-cn"

die() { echo "错误: $*" >&2; exit 1; }

usage() {
    grep -E '^# (用法|   )' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

# ---------- 参数解析 ----------
WIN_EXE=""
EXTRACTED_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --extracted) EXTRACTED_DIR="$2"; shift 2 ;;
        *.exe) WIN_EXE="$1"; shift ;;
        -h|--help) usage ;;
        *) die "未知参数: $1" ;;
    esac
done

# ---------- 依赖检查 ----------
for tool in rsync python3 dpkg-deb; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少依赖: $tool"
done

# 定位可用的 innoextract（自编译版支持 Inno Setup 6.4+，发行版 1.9 过旧）
find_innoextract() {
    local cand="${SCRIPT_DIR}/.innoextract-src/build/innoextract"
    [[ -x "$cand" ]] && { echo "$cand"; return 0; }
    command -v innoextract 2>/dev/null
}

# ---------- Step 1: 准备 TraeWork 源目录 ----------
TWROOT=""
if [[ -n "$EXTRACTED_DIR" ]]; then
    [[ -d "$EXTRACTED_DIR" ]] || die "解压目录不存在: $EXTRACTED_DIR"
    TWROOT="$EXTRACTED_DIR"
elif [[ -n "$WIN_EXE" ]]; then
    [[ -f "$WIN_EXE" ]] || die "安装包不存在: $WIN_EXE"
    EXTRACT_DIR="${SCRIPT_DIR}/extracted"
    mkdir -p "$EXTRACT_DIR"
    # 格式探测：新版安装包（0.1.58+）为 Inno Setup，旧版为 NSIS（7z 可解）
    if grep -qaI --binary-files=text -m1 'Inno Setup' "$WIN_EXE"; then
        INNOEXTRACT="$(find_innoextract || true)"
        [[ -n "$INNOEXTRACT" ]] || die "Inno Setup 安装包需要 innoextract >= 1.10：\n  git clone https://github.com/dscharrer/innoextract .innoextract-src && cd .innoextract-src && mkdir build && cd build && cmake .. && make"
        echo ">>> [1/4] 解压 Windows 安装包 (Inno Setup, 使用 $INNOEXTRACT) ..."
        "$INNOEXTRACT" -d "$EXTRACT_DIR" "$WIN_EXE" >/dev/null
    else
        command -v 7z >/dev/null 2>&1 || die "解压 NSIS 安装包需要 7z（apt install p7zip-full）"
        echo ">>> [1/4] 解压 Windows 安装包 (NSIS) ..."
        7z x -y -o"$EXTRACT_DIR" "$WIN_EXE" >/dev/null
    fi
    TWROOT="${EXTRACT_DIR}/code\$GetDestDir"
    [[ -d "$TWROOT" ]] || die "解压后未找到 code\$GetDestDir 目录"
else
    die "请提供 .exe 安装包路径或 --extracted 解压目录"
fi
echo ">>> TraeWork 源目录: $TWROOT"

# ---------- Step 2: 准备 TraeCode Linux 运行时 ----------
TRAECODE="$TRAECODE_INSTALLED"
if [[ ! -d "$TRAECODE" ]]; then
    # 尝试从当前目录的 deb 提取
    if [[ -f "${SCRIPT_DIR}/TraeCode_CN-linux-x64.deb" ]]; then
        echo ">>> [2/4] 提取 TraeCode Linux deb ..."
        TRAECODE="${SCRIPT_DIR}/.traecode-extract"
        rm -rf "$TRAECODE" && mkdir -p "$TRAECODE"
        dpkg-deb -x "${SCRIPT_DIR}/TraeCode_CN-linux-x64.deb" "$TRAECODE"
        TRAECODE="${TRAECODE}/usr/share/trae-cn"
        [[ -d "$TRAECODE" ]] || die "deb 内未找到 usr/share/trae-cn"
    else
        die "未安装 TraeCode CN Linux（/usr/share/trae-cn），也没有 TraeCode_CN-linux-x64.deb"
    fi
else
    echo ">>> [2/4] 使用已安装的 TraeCode: $TRAECODE"
fi

# ---------- Step 3: 复制 Electron 运行时（来自 TraeCode） ----------
echo ">>> [3/4] 复制 Electron 运行时与原生模块 ..."
mkdir -p "$APP_DIR" "$RES_DIR"

# 二进制与 Chromium 运行时文件
cp -f "$TRAECODE/trae-cn" "$APP_DIR/trae-solo-cn-bin"
for f in chrome_100_percent.pak chrome_200_percent.pak resources.pak \
         icudtl.dat snapshot_blob.bin v8_context_snapshot.bin \
         chrome-sandbox chrome_crashpad_handler vk_swiftshader_icd.json; do
    cp -f "$TRAECODE/$f" "$APP_DIR/" 2>/dev/null || true
done
# 原生 .so 库
cp -f "$TRAECODE"/*.so "$APP_DIR/" 2>/dev/null || true
cp -f "$TRAECODE"/libvulkan.so.* "$APP_DIR/" 2>/dev/null || true
# locales
rsync -a --delete "$TRAECODE/locales/" "$APP_DIR/locales/"
# resources/app 下的平台内容（模块、node_modules、lib、bin、extensions）
rsync -a --delete "$TRAECODE/resources/app/modules/" "$RES_DIR/modules/"
rsync -a --delete "$TRAECODE/resources/app/node_modules/" "$RES_DIR/node_modules/"
rsync -a "$TRAECODE/resources/app/lib/" "$RES_DIR/lib/" 2>/dev/null || true
rsync -a "$TRAECODE/resources/app/bin/" "$RES_DIR/bin/" 2>/dev/null || true

# ---------- Step 4: 覆盖 TraeWork 专属内容 ----------
echo ">>> [4/4] 覆盖 TraeWork JS 资源与 solo-lite 模块 ..."
TWAPP="$TWROOT/resources/app"
[[ -d "$TWAPP" ]] || die "TraeWork 源缺少 resources/app 目录"

# JS 资源（保留 TraeWork 的 out/，含 solo/ 与 solo-lite workbench）
rsync -a --delete "$TWAPP/out/" "$RES_DIR/out/"
cp -f "$TWAPP/package.json" "$RES_DIR/"

# main.js 标题栏回归补丁：0.1.58 起官方删除了 Linux 跳过 titleBarOverlay 的守卫，
# 导致无白底遮挡块且 frame:false 失去系统标题栏。
# 注意：product.json 的 configurationDefaults 对主进程建窗代码无效（它只读
# 简化版配置缓存），必须直接补 main.js。变量名（oW/Lt/rl）为 0.1.58 的 minify 产物，
# 未来版本失效时降级为警告，不阻断构建。
echo ">>> 修补 main.js titleBarOverlay Linux 守卫 ..."
python3 - "$RES_DIR/out/main.js" << 'PYEOF' || echo "  [警告] main.js 未命中已知模式，跳过（若 Linux 出现白块需人工适配）"
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
c1 = 'function oW(t){if(rl)return"custom";'
c2 = 'l.titleBarOverlay={height:29,color:p,symbolColor:b}'
if s.count(c1) != 1 or s.count(c2) != 1:
    sys.exit(1)
# 1) 标题栏样式解析函数：Linux 强制 native（恢复 0.1.54 行为，Lt=isLinux）
s = s.replace(c1, c1 + 'if(Lt)return"native";', 1)
# 2) titleBarOverlay 设置：Linux 跳过（双保险）
s = s.replace(c2, 'Lt||Object.assign(l,{titleBarOverlay:{height:29,color:p,symbolColor:b}})', 1)
open(p, 'w').write(s)
print("  main.js 已修补（Linux 强制 native 标题栏）")
PYEOF

# product.json：复制后修改 buildPlatform 为 linux，并注入原生标题栏默认值
# （对渲染进程侧配置生效；主进程建窗靠上方 main.js 补丁）
cp -f "$TWAPP/product.json" "$RES_DIR/"
python3 - "$RES_DIR/product.json" << 'PYEOF'
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
d['buildPlatform'] = 'linux'
d.setdefault('configurationDefaults', {})['window.titleBarStyle'] = 'native'
with open(p, 'w') as f:
    json.dump(d, f, indent='\t')
print(f"product.json: {d.get('nameShort')} v{d.get('version')} buildPlatform=linux titleBarStyle=native")
PYEOF

# 关键：solo-lite 模块（TraeCode 没有 dist/，必须从 TraeWork 复制）
rsync -a "$TWAPP/node_modules/@byted-icube/solo-lite/" \
    "$RES_DIR/node_modules/@byted-icube/solo-lite/"
rsync -a "$TWAPP/node_modules/@byted-solo/" \
    "$RES_DIR/node_modules/@byted-solo/" 2>/dev/null || true

# 权限
chmod 755 "$APP_DIR/trae-solo-cn-bin" "$APP_DIR/trae-solo-cn"
chmod 755 "$APP_DIR/chrome-sandbox" 2>/dev/null || true

echo ""
echo "=== 源文件提取完成 ==="
echo "下一步: bash build.sh"
