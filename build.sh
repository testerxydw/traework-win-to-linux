#!/usr/bin/env bash
# ============================================================================
# TRAE SOLO CN 一键构建脚本（唯一入口）
#
# 流水线：拆包 → [精简] → 桌面集成 → 构建 deb → 转制玲珑 uab → 安装
#
# 各阶段：
#   1/5 拆包 + 组装 deb-pkg   2/5 精简（默认开启，--no-slim 关闭）   3/5 桌面集成（图标/权限/桌面图标）
#   4/5 构建 deb              5/5 玲珑 uab         最后安装
# 桌面集成阶段负责生成图标、修正启动脚本权限（755）与注入桌面快捷方式创建逻辑，
# 这些都必须作用于 deb-pkg 源目录，因此固定排在构建 deb 之前。
#
# 用法：
#   bash build.sh                                # 完整流水线（自动查找目录下 TraeWork_CN-Setup*.exe）
#   bash build.sh /path/TraeWork_CN-Setup-x64.exe  # 指定 Windows 安装包
#   bash build.sh --extracted <解压目录>           # 复用已解压目录（.../code$GetDestDir）
#   bash build.sh --skip-extract                 # 跳过拆包，复用现有 deb-pkg 直接构建
#   bash build.sh                                # 默认：拆包 + 精简 + 构建 deb（不构建玲珑），省约 200-300MB
#   bash build.sh --no-slim                      # 关闭默认精简（保留全平台残留与未 strip 符号，体积最大）
#   bash build.sh --deb-only                     # 仅 deb（不转玲珑），兼容旧用法，等价于默认
#   bash build.sh --ll                           # 在默认基础上额外构建并打包玲珑
#   bash build.sh --ll-only                      # 仅用现有最新 deb 构建玲珑 + 安装玲珑（不拆包/不构建 deb）
#   bash build.sh --no-install                   # 全部构建但都不安装
#   bash build.sh --install-deps                 # 一键安装构建所需的全部依赖工具后退出
#
# 依赖说明：
#   基础工具 rsync/python3/dpkg-deb/sed/grep/md5sum 一般系统自带
#   解包：NSIS 需 7z（包名 7zip）；Inno Setup 需 innoextract>=1.10（apt 只有 1.9 需自编译）
#   玲珑：ll-pica/ll-builder/ll-cli（包名 linglong-pica/linglong-builder/linglong-bin）
#   上述均可用 --install-deps 自动装齐
#
# 源材料（需自行准备）：
#   1. TraeWork CN Windows 安装包（0.1.58 起为 Inno Setup，旧版为 NSIS）
#   2. TraeCode CN Linux 版（已安装于 /usr/share/trae-cn，或提供 TraeCode_CN-linux-x64.deb）
#
# 自动识别安装包格式：
#   - Inno Setup（0.1.58 起）：需要 innoextract >= 1.10；发行版自带的 1.9 过旧，
#     优先使用本目录 .innoextract-src/build/innoextract（自编译版）
#   - NSIS（0.1.54 及更早）：使用 7z (p7zip-full)
#
# 版本同步规则：玲珑版本号 = deb 主版本 + 修订号转点分（0.1.58-5 -> 0.1.58.5）
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/deb-pkg"
APP_DIR="${PKG_DIR}/opt/trae-solo-cn"
RES_DIR="${APP_DIR}/resources/app"
CONTROL_FILE="${PKG_DIR}/DEBIAN/control"
DEB_ARCH="amd64"
WORKDIR="${SCRIPT_DIR}/pica-work"
LL_PKG_DIR="${WORKDIR}/package/trae-solo-cn"
FIX_SCRIPT="${SCRIPT_DIR}/scripts/fix-linglong-yaml.py"

# TraeCode Linux 安装路径（已安装）；若未安装可通过 deb 包提取
TRAECODE_INSTALLED="/usr/share/trae-cn"

# 兼容部分构建环境 PATH 不完整的问题（在原 PATH 基础上追加，不覆盖）
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

die() { echo "错误: $*" >&2; exit 1; }
log() { echo ""; echo "==================================================================="; echo "==> $*"; echo "==================================================================="; }
step() { echo ">>> $*"; }

usage() {
    grep -E '^#   ' "$0" | sed 's/^#   //'
    exit 1
}

# ---------- 依赖安装（--install-deps）----------
# 只安装当前缺失的工具；innoextract 因 apt 仓库只有 1.9（不支持 Inno 6.4），
# 需自编译 master 分支（依赖 git/cmake/g++/libboost-*-dev/liblzma-dev）。
install_deps() {
    log "安装构建依赖（仅装缺失项）"
    command -v sudo >/dev/null 2>&1 || die "缺少 sudo，无法自动安装依赖"

    # 1) apt 包：按命令→包名映射，缺失才装
    local apt_pkgs=()
    local cmd pkg
    for pair in \
        "7z:7zip" \
        "rsync:rsync" \
        "python3:python3" \
        "dpkg-deb:dpkg" \
        "python3-yaml:python3-yaml" \
        "convert:imagemagick" \
        "ll-pica:linglong-pica" \
        "ll-builder:linglong-builder" \
        "ll-cli:linglong-bin"; do
        cmd="${pair%%:*}"; pkg="${pair##*:}"
        case "$cmd" in
            python3-yaml) python3 -c 'import yaml' 2>/dev/null || apt_pkgs+=("$pkg") ;;
            *) command -v "$cmd" >/dev/null 2>&1 || apt_pkgs+=("$pkg") ;;
        esac
    done

    # 2) innoextract：先看自编译产物，再看系统版本 >=1.10，都不满足则需编译工具链
    local need_inno=1
    if [[ -x "${SCRIPT_DIR}/.innoextract-src/build/innoextract" ]]; then
        need_inno=0
    elif command -v innoextract >/dev/null 2>&1; then
        local iv
        iv="$(innoextract --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n 1)"
        [[ "${iv:-0.0}" != "1.9" ]] && need_inno=0   # 1.9 过旧，其他视为可用
    fi
    if [[ "$need_inno" -eq 1 ]]; then
        for pair in "git:git" "cmake:cmake" "g++:g++"; do
            cmd="${pair%%:*}"; pkg="${pair##*:}"
            command -v "$cmd" >/dev/null 2>&1 || apt_pkgs+=("$pkg")
        done
        # boost 组件 dev 包（innoextract 需 filesystem/program-options/iostreams/regex 等）
        apt_pkgs+=(libboost-filesystem-dev libboost-program-options-dev libboost-iostreams-dev libboost-regex-dev libboost-system-dev liblzma-dev)
    fi

    # 3) 去重后一次性 apt 安装
    if [[ ${#apt_pkgs[@]} -gt 0 ]]; then
        local uniq
        uniq="$(printf '%s\n' "${apt_pkgs[@]}" | awk '!seen[$0]++' | tr '\n' ' ')"
        step "apt 安装: ${uniq}"
        sudo apt-get update -qq || step "apt update 失败，继续尝试安装"
        # shellcheck disable=SC2086
        sudo apt-get install -y --no-install-recommends ${uniq} || die "apt 安装失败，请手动检以上包名"
    else
        step "apt 包均已就绪"
    fi

    # 4) 自编译 innoextract（仅当需要且无产物时）
    if [[ "$need_inno" -eq 1 && ! -x "${SCRIPT_DIR}/.innoextract-src/build/innoextract" ]]; then
        step "自编译 innoextract >= 1.10（apt 版本不支持 Inno Setup 6.4）..."
        [[ -d "${SCRIPT_DIR}/.innoextract-src" ]] || \
            git clone --depth 1 https://github.com/dscharrer/innoextract.git "${SCRIPT_DIR}/.innoextract-src"
        cmake -S "${SCRIPT_DIR}/.innoextract-src" -B "${SCRIPT_DIR}/.innoextract-src/build" >/dev/null
        cmake --build "${SCRIPT_DIR}/.innoextract-src/build" -j"$(nproc)" >/dev/null
        [[ -x "${SCRIPT_DIR}/.innoextract-src/build/innoextract" ]] || die "innoextract 编译失败"
        step "innoextract 编译完成: $(${SCRIPT_DIR}/.innoextract-src/build/innoextract --version | head -n1)"
    fi

    step "依赖安装完成，可重新执行构建命令"
}

# ---------- 参数解析 ----------
WIN_EXE=""
EXTRACTED_DIR=""
DO_EXTRACT=1
DO_DEB=1
DO_LL=0
DO_INSTALL=1
DO_SLIM=1
RUN_INSTALL_DEPS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --extracted)   EXTRACTED_DIR="$2"; shift 2 ;;
        --skip-extract) DO_EXTRACT=0; shift ;;
        --slim)        DO_SLIM=1; shift ;;
        --no-slim)     DO_SLIM=0; shift ;;
        --deb-only)    DO_LL=0; shift ;;
        --ll)          DO_LL=1; shift ;;
        --ll-only)     DO_EXTRACT=0; DO_DEB=0; DO_LL=1; shift ;;
        --no-install)  DO_INSTALL=0; shift ;;
        --install-deps) RUN_INSTALL_DEPS=1; shift ;;
        -h|--help)     usage ;;
        *.exe)         WIN_EXE="$1"; shift ;;
        *) echo "未知参数: $1" >&2; usage ;;
    esac
done

# ---------- 依赖安装模式（装完即退出，不需预先具备任何构建工具）----------
if [[ "${RUN_INSTALL_DEPS}" -eq 1 ]]; then
    install_deps
    exit 0
fi

# ---------- 依赖检查 ----------
for tool in rsync python3 dpkg-deb sed grep md5sum chmod; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少依赖: $tool（可运行 bash build.sh --install-deps 自动安装）"
done

# 定位可用的 innoextract（自编译版支持 Inno Setup 6.4+，发行版 1.9 过旧）
find_innoextract() {
    local cand="${SCRIPT_DIR}/.innoextract-src/build/innoextract"
    [[ -x "$cand" ]] && { echo "$cand"; return 0; }
    command -v innoextract 2>/dev/null
}

# ============================================================================
# 阶段 1/5：拆包 + 组装 deb-pkg（原 setup.sh）
# ============================================================================
stage_extract() {
    log "阶段 1/5：拆包 Windows 安装包并组装 deb-pkg"

    # ---------- 定位 TraeWork 源目录 ----------
    local TWROOT=""
    if [[ -n "$EXTRACTED_DIR" ]]; then
        [[ -d "$EXTRACTED_DIR" ]] || die "解压目录不存在: $EXTRACTED_DIR"
        TWROOT="$EXTRACTED_DIR"
    else
        # 未显式指定则自动查找项目目录下的安装包
        if [[ -z "$WIN_EXE" ]]; then
            WIN_EXE="$(ls -t "${SCRIPT_DIR}"/TraeWork_CN-Setup*.exe 2>/dev/null | head -n 1 || true)"
        fi
        [[ -n "$WIN_EXE" ]] || die "未找到 Windows 安装包（TraeWork_CN-Setup*.exe），请指定路径，或用 --skip-extract 复用现有 deb-pkg"
        [[ -f "$WIN_EXE" ]] || die "安装包不存在: $WIN_EXE"
        local EXTRACT_DIR="${SCRIPT_DIR}/extracted"
        mkdir -p "$EXTRACT_DIR"
        # 格式探测：新版安装包（0.1.58+）为 Inno Setup，旧版为 NSIS（7z 可解）
        if grep -qaI --binary-files=text -m1 'Inno Setup' "$WIN_EXE"; then
            local INNOEXTRACT
            INNOEXTRACT="$(find_innoextract || true)"
            [[ -n "$INNOEXTRACT" ]] || die "Inno Setup 安装包需要 innoextract >= 1.10：
  git clone --depth 1 https://github.com/dscharrer/innoextract .innoextract-src
  cmake -S .innoextract-src -B .innoextract-src/build && cmake --build .innoextract-src/build -j\$(nproc)"
            step "解压 Windows 安装包 (Inno Setup, 使用 $INNOEXTRACT) ..."
            "$INNOEXTRACT" -d "$EXTRACT_DIR" "$WIN_EXE" >/dev/null
        else
            command -v 7z >/dev/null 2>&1 || die "解压 NSIS 安装包需要 7z（apt install p7zip-full）"
            step "解压 Windows 安装包 (NSIS) ..."
            7z x -y -o"$EXTRACT_DIR" "$WIN_EXE" >/dev/null
        fi
        TWROOT="${EXTRACT_DIR}/code\$GetDestDir"
        [[ -d "$TWROOT" ]] || die "解压后未找到 code\$GetDestDir 目录"
    fi
    step "TraeWork 源目录: $TWROOT"

    # ---------- 准备 TraeCode Linux 运行时 ----------
    local TRAECODE="$TRAECODE_INSTALLED"
    if [[ ! -d "$TRAECODE" ]]; then
        if [[ -f "${SCRIPT_DIR}/TraeCode_CN-linux-x64.deb" ]]; then
            step "提取 TraeCode Linux deb ..."
            TRAECODE="${SCRIPT_DIR}/.traecode-extract"
            rm -rf "$TRAECODE" && mkdir -p "$TRAECODE"
            dpkg-deb -x "${SCRIPT_DIR}/TraeCode_CN-linux-x64.deb" "$TRAECODE"
            TRAECODE="${TRAECODE}/usr/share/trae-cn"
            [[ -d "$TRAECODE" ]] || die "deb 内未找到 usr/share/trae-cn"
        else
            die "未安装 TraeCode CN Linux（/usr/share/trae-cn），也没有 TraeCode_CN-linux-x64.deb"
        fi
    else
        step "使用已安装的 TraeCode: $TRAECODE"
    fi

    # ---------- 复制 Electron 运行时（来自 TraeCode） ----------
    step "复制 Electron 运行时与原生模块 ..."
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

    # ---------- 覆盖 TraeWork 专属内容 ----------
    step "覆盖 TraeWork JS 资源与 solo-lite 模块 ..."
    local TWAPP="$TWROOT/resources/app"
    [[ -d "$TWAPP" ]] || die "TraeWork 源缺少 resources/app 目录"

    # JS 资源（保留 TraeWork 的 out/，含 solo/ 与 solo-lite workbench）
    rsync -a --delete "$TWAPP/out/" "$RES_DIR/out/"
    cp -f "$TWAPP/package.json" "$RES_DIR/"

    # main.js 标题栏回归补丁：0.1.58 起官方删除了 Linux 跳过 titleBarOverlay 的守卫，
    # 导致出现白底遮挡块且 frame:false 失去系统标题栏。
    # 注意：product.json 的 configurationDefaults 对主进程建窗代码无效（它只读
    # 简化版配置缓存），必须直接补 main.js。变量名（oW/Lt/rl）为 0.1.58 的 minify 产物，
    # 未来版本失效时降级为警告，不阻断构建。
    step "修补 main.js titleBarOverlay Linux 守卫 ..."
    python3 - "$RES_DIR/out/main.js" << 'PYEOF' || echo "  [警告] main.js 未命中已知模式，跳过（若 Linux 出现白块需人工适配）"
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
applied = []
# 1) 标题栏样式解析函数（旧版 oW / 新版 hV 等）：Linux 强制 native。
#    各版本 minify 函数名不同，逐个宽松匹配，命中即补，不命中不阻断。
for pat in ['function oW(t){if(rl)return"custom";',
            'function hV(t){if(cl)return"custom";']:
    if pat in s:
        # 在「return"custom"」前插入 Linux native 分支（Lt=isLinux / cl 为原生开关）
        s = s.replace(pat, pat + 'if(Lt)return"native";', 1)
        applied.append(pat[:20] + '...')
# 2) titleBarOverlay 设置：Linux 跳过（双保险，避免白块遮挡）
c2 = 'l.titleBarOverlay={height:29,color:p,symbolColor:b}'
if c2 in s:
    s = s.replace(c2, 'Lt||Object.assign(l,{titleBarOverlay:{height:29,color:p,symbolColor:b}})', 1)
    applied.append('titleBarOverlay')
# 3) 配置层：去掉对 window.titleBarStyle 的硬编码 custom，改为读取真实配置
#    （fallback native）。否则渲染进程配置层始终返回 custom，DDE 下不显示系统标题栏。
c3 = 'switch(i){case"window.titleBarStyle":return"custom"}'
if c3 in s:
    s = s.replace(c3, 'switch(i){case"window.titleBarStyle":return this.a.getValue("window.titleBarStyle",e,void 0)||"native"}', 1)
    applied.append('config.custom->native')
if not applied:
    sys.exit(1)
open(p, 'w').write(s)
print("  main.js 已修补（命中: " + ", ".join(applied) + "）")
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

    # ---------- 关键：应用身份 manifest.json ----------
    # 位于应用根目录（与 TraeCode 的 /usr/share/trae-cn/manifest.json 同级）。
    # 内含 appId / packageType / region / registryUrl（设备注册地址）/ ahaNet 网络参数。
    # 缺失后果：ICubeDeviceRegister 拿不到 registryUrl 与 appId，设备无法注册
    #   → 运行日志表现为 [ICDRS] did: 0（只有本地 ldid，没有服务端 deviceId）
    #   → 服务端无该设备在线记录 → 手机端列表显示「打包版本」且离线、无法远程发消息。
    # 必须取 TraeWork 的（appId 931506 / name "SOLO CN"），不能用 TraeCode 的
    # （appId 787976 / name "Trae CN" / appVersion 3.3.91），否则身份错配。
    if [[ -f "$TWROOT/manifest.json" ]]; then
        cp -f "$TWROOT/manifest.json" "$APP_DIR/manifest.json"
        step "  已复制 TraeWork manifest.json（appId/registryUrl，设备注册必需）"
    else
        echo "  [警告] 未找到 $TWROOT/manifest.json，设备注册将失败（手机端显示离线）"
    fi

    # ---------- 关键：内置扩展 extensions ----------
    # 含 cloudide.icube-im-bridge（手机端消息桥接）、git/git-base、solo-lite、
    # byted-solo.builtin-mcp 等。缺失会导致远程发消息等能力不可用。
    # 用 TraeWork 自带的一套（与 product.json / solo-lite UI 配套），而非 TraeCode 的。
    if [[ -d "$TWAPP/extensions" ]]; then
        rsync -a --delete "$TWAPP/extensions/" "$RES_DIR/extensions/"
        step "  已复制内置扩展 $(ls "$TWAPP/extensions" | wc -l) 个（含 icube-im-bridge）"
    else
        echo "  [警告] 未找到 $TWAPP/extensions，内置扩展缺失"
    fi

    # 权限
    chmod 755 "$APP_DIR/trae-solo-cn-bin" "$APP_DIR/trae-solo-cn"
    chmod 755 "$APP_DIR/chrome-sandbox" 2>/dev/null || true
}

# ============================================================================
# 阶段 2/5：精简冗余文件（默认执行，--no-slim 关闭）
#
# 各项均已实测：删除后应用正常启动（ai-agent/ckg healthy、IPC ready、0 模块错误）
#   - locales 55 个语言包只留 zh-CN/en-US：Chromium 标准优化，其余语言回退英文
#   - @byted-fe/ripgrep-{linux-x64,linux-musl-x64}：未被引用（代码硬编码 @vscode/ripgrep/bin/rg）
#   - @byted-fe/fd-linux-musl-x64：glibc 系统只用 fd-linux-x64（按平台检测加载）
#   - @byted-icube/trae-macos-native：macOS 专用
#   - Windows 残留（零风险删）：*.dll / *.exe / *win32-x64* / *.msvc.node /
#     node-v*-win-*.zip / windows.node / foreground_love.node / koffi-win32-x64。
#     打包脚本把全平台 build 产物塞进 deb，这些 Linux 永不加载。
#   - *.bat：Windows 遗留
#   - strip 未剥离的 .so / .node / 主二进制：仅去符号表（--strip-unneeded），
#     功能无损；实测 libai_agent.so 256MB 未 strip 是最大瘦身点。
# 注意：两个 libsscronet.so（顶层与 ai-agent 内）MD5 不同，不是重复，不可删；
#       但两者均未 strip，本阶段会一并 strip。
# ============================================================================
stage_slim() {
    log "阶段 2/5：精简冗余文件"
    local BASE="${PKG_DIR}/opt/trae-solo-cn"
    [[ -d "$BASE" ]] || die "未找到 ${BASE}，请先执行拆包阶段"

    local before after
    before="$(du -sm "$BASE" | cut -f1)"

    find "$BASE/locales" -name '*.pak' ! -name 'zh-CN.pak' ! -name 'en-US.pak' -delete 2>/dev/null || true
    rm -rf "${BASE}/resources/app/node_modules/@byted-fe/ripgrep-linux-x64"
    rm -rf "${BASE}/resources/app/node_modules/@byted-fe/ripgrep-linux-musl-x64"
    rm -rf "${BASE}/resources/app/node_modules/@byted-fe/fd-linux-musl-x64"
    rm -rf "${BASE}/resources/app/node_modules/@byted-icube/trae-macos-native"
    find "$BASE" -name '*.bat' -delete 2>/dev/null || true

    # ---------- Windows / macOS 平台残留（Linux 用不到，零风险删除） ----------
    # 全平台 build 产物被打包脚本一股脑塞进 deb：Windows 的 node 运行时 zip、
    # skia 原生模块、computer-use 的 exe/dll、win 版 koffi 等。按文件名特征清理。
    find "$BASE" \( -name '*.dll' -o -name '*.exe' \) -delete 2>/dev/null || true
    find "$BASE" -name '*win32-x64*' -delete 2>/dev/null || true
    find "$BASE" -name '*.msvc.node' -delete 2>/dev/null || true
    find "$BASE" -name 'node-v*-win-*.zip' -delete 2>/dev/null || true
    find "$BASE" -name 'windows.node' -delete 2>/dev/null || true
    find "$BASE" -name 'foreground_love.node' -delete 2>/dev/null || true
    find "$BASE" -path '*trae-macos-native*' -delete 2>/dev/null || true

    # ---------- 参考 workbuddy 移植经验：系统性跨平台 / 跨架构 / 媒体清理 ----------
    # trae 与 workbuddy 同源（Electron 应用），全平台 build 产物同样被一股脑塞进 deb。
    # 以下路径在 Linux x64 运行时绝不加载，零风险删除；媒体为演示/引导资源，非功能必需。
    # macOS 调试符号与框架
    find "$BASE" -name '*.dSYM'      -prune -exec rm -rf {} + 2>/dev/null || true
    find "$BASE" -name '*.framework' -prune -exec rm -rf {} + 2>/dev/null || true
    # 跨平台 / 跨架构残留：darwin / win32 / msvc / musl / 非 x64（Linux x64 永不加载）
    find "$BASE" -path '*darwin-x64*'   -prune -exec rm -rf {} + 2>/dev/null || true
    find "$BASE" -path '*darwin-arm64*' -prune -exec rm -rf {} + 2>/dev/null || true
    find "$BASE" -path '*win32*'        -prune -exec rm -rf {} + 2>/dev/null || true
    find "$BASE" -path '*msvc*'         -prune -exec rm -rf {} + 2>/dev/null || true
    find "$BASE" -path '*linux-musl*'   -prune -exec rm -rf {} + 2>/dev/null || true
    find "$BASE" -path '*linux-arm64*'  -prune -exec rm -rf {} + 2>/dev/null || true
    find "$BASE" -path '*linux-armhf*'  -prune -exec rm -rf {} + 2>/dev/null || true
    # 非功能媒体（演示视频 / 引导动画）：不影响启动与 AI 能力（实测约 47MB）
    find "$BASE" \( -name '*.mp4' -o -name '*.mov' -o -name '*.webm' \
        -o -name '*.avi' -o -name '*.mkv' -o -name '*.gif' \) -delete 2>/dev/null || true

    # ---------- strip 未剥离的二进制（仅去符号表，功能无损，体积大减） ----------
    # 实测 libai_agent.so 256MB 含 .symtab，strip 后显著缩小；已 stripped 的文件重 strip 无副作用。
    if command -v strip >/dev/null 2>&1; then
        find "$BASE" -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.node' \) \
            -exec sh -c 'file "$1" 2>/dev/null | grep -q "ELF" && strip --strip-unneeded "$1" 2>/dev/null' _ {} \;
        [[ -f "$BASE/trae-solo-cn-bin" ]] && file "$BASE/trae-solo-cn-bin" 2>/dev/null | grep -q "ELF" && \
            strip --strip-unneeded "$BASE/trae-solo-cn-bin" 2>/dev/null || true
        step "  已 strip 未剥离的 ELF 符号"
    else
        echo "  [警告] 缺少 strip 命令（binutils），跳过符号剥离，体积优化减弱"
    fi

    after="$(du -sm "$BASE" | cut -f1)"
    step "精简: ${before} MB -> ${after} MB (省 $((before-after)) MB)"
}

# ============================================================================
# 阶段 3/5：桌面集成（图标 + 启动脚本权限 + 强制创建桌面图标）
#
# 解决的问题：
#   1. 图标从未安装：.gitignore 忽略了 deb-pkg/usr/share/icons/，导致
#      desktop 文件的 Icon=trae-solo-cn 解析不到，菜单显示问号
#   2. 启动脚本无执行位：write_to_file 创建的是 664，而本脚本的 chmod 755
#      在 stage_extract 内，用 --skip-extract 打包时会被跳过 → 菜单点击无反应
#   3. 符号链接路径错误：/usr/bin/trae-solo-cn 是软链，用 dirname $0 会解析
#      到 /usr/bin 而找不到 trae-solo-cn-bin → 改用 readlink -f
# 本阶段幂等，可重复执行
# ============================================================================
stage_desktop() {
    log "阶段 3/5：桌面集成（图标 / 权限 / 桌面图标）"
    local ICON_SRC="${SCRIPT_DIR}/trae-icon-256.png"
    local ICON_DIR="${PKG_DIR}/usr/share/icons/hicolor"
    local DESKTOP_SRC="${PKG_DIR}/usr/share/applications/trae-solo-cn.desktop"
    local POSTINST="${PKG_DIR}/DEBIAN/postinst"

    [[ -d "${PKG_DIR}/opt" ]] || die "未找到 ${PKG_DIR}/opt，请先执行拆包阶段"

    # ---------- 1. 生成多尺寸图标 ----------
    step "生成图标 ..."
    if [[ ! -f "$ICON_SRC" ]]; then
        echo "  [警告] 缺少图标素材 $ICON_SRC，跳过图标生成（菜单将无图标）"
    elif ! command -v convert >/dev/null 2>&1; then
        echo "  [警告] 缺少 ImageMagick (convert)，跳过图标生成（apt install imagemagick）"
    else
        local size
        for size in 16 32 48 64 128 256 512; do
            mkdir -p "${ICON_DIR}/${size}x${size}/apps"
            convert "$ICON_SRC" -resize "${size}x${size}" "${ICON_DIR}/${size}x${size}/apps/trae-solo-cn.png"
        done
        mkdir -p "${ICON_DIR}/scalable/apps"
        cp -f "$ICON_SRC" "${ICON_DIR}/scalable/apps/trae-solo-cn.png"
        step "  已生成 7 个尺寸 + scalable"
    fi

    # ---------- 2. 启动脚本：权限 + 软链 + sandbox 自动回退 ----------
    step "修正启动脚本 ..."
    cat > "${APP_DIR}/trae-solo-cn" << 'LAUNCHER'
#!/bin/bash
# TRAE SOLO CN - Linux Launcher
# Repackaged from Windows installer with TraeCode CN Linux Electron runtime

APP_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ELECTRON="$APP_DIR/trae-solo-cn-bin"

# 提升文件描述符上限，避免 File Watcher 出现 EMFILE: too many open files
ulimit -n 65535 2>/dev/null || true

# 公共 Electron 参数：
#   --disable-dev-shm-usage : DDE 下 /dev/shm 偏小，缺省会卡住渲染进程重绘，
#                            表现为「work 模式 AI 流式输出不实时刷新、需切页才显示」。
#   --title-bar-style=native: 强制使用系统（DDE）标题栏（双保险，main.js 补丁亦强制 native）。
#   --disable-backgrounding-occluded-windows / --disable-renderer-backgrounding /
#   --disable-background-timer-throttling : 禁用 DDE 下的窗口遮挡检测与后台节流，
#                            避免渲染进程被误判为「被遮挡」而暂停重绘，导致 AI 流式输出
#                            必须切页才刷新。
EXTRA_ARGS="--disable-dev-shm-usage --title-bar-style=native --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling"

# chrome-sandbox 需要 root:setuid 才能启用 Chromium 沙箱。postinst 会设置；
# 若目标系统以 nosuid 挂载或 dpkg 解压时未生效，则自动追加 --no-sandbox，
# 保证应用仍可启动（而不是白屏/闪退）。
if [ ! -u "$APP_DIR/chrome-sandbox" ]; then
    exec "$ELECTRON" --no-sandbox ${EXTRA_ARGS} "$@"
fi

exec "$ELECTRON" ${EXTRA_ARGS} "$@"
LAUNCHER
    chmod 755 "${APP_DIR}/trae-solo-cn"
    chmod 755 "${APP_DIR}/trae-solo-cn-bin" 2>/dev/null || true
    chmod 755 "${PKG_DIR}/usr/bin/trae-solo-cn" 2>/dev/null || true
    step "  trae-solo-cn 已写入并 chmod 755"

    # ---------- 3. 完善 desktop 文件 ----------
    if [[ -f "$DESKTOP_SRC" ]]; then
        grep -q '^Keywords=' "$DESKTOP_SRC" || \
            sed -i '/^GenericName=/a Keywords=code;editor;ai;ide;trae;development;' "$DESKTOP_SRC"
        grep -q '^Terminal=' "$DESKTOP_SRC" || \
            sed -i '/^Type=/a Terminal=false' "$DESKTOP_SRC"
        step "  desktop 文件已完善"
    else
        echo "  [警告] 未找到 $DESKTOP_SRC"
    fi

    # ---------- 4. postinst 注入「强制创建桌面快捷方式」 ----------
    # 先移除旧注入块，保证重复构建不会重复追加
    python3 - "$POSTINST" << 'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"\n+# ---- BEGIN desktop-shortcut ----.*?# ---- END desktop-shortcut ----\n+", "\n", s, flags=re.S)
open(p, 'w').write(s)
PYEOF

    cat >> "$POSTINST" << 'POSTEOF'

# ---- BEGIN desktop-shortcut ----
# 强制为各用户创建桌面快捷方式（兼容 ~/Desktop 与中文 ~/桌面）
SRC_DESKTOP=/usr/share/applications/trae-solo-cn.desktop
if [ -f "$SRC_DESKTOP" ]; then
    for home_dir in /root /home/*; do
        [ -d "$home_dir" ] || continue
        user_name="$(basename "$home_dir")"
        for d in "$home_dir/Desktop" "$home_dir/桌面"; do
            [ -d "$d" ] || continue
            target="$d/trae-solo-cn.desktop"
            if cp -f "$SRC_DESKTOP" "$target" 2>/dev/null; then
                chmod 755 "$target" 2>/dev/null || true
                # 属主设为该用户，否则普通用户无法「允许启动」
                if [ "$user_name" != "root" ] && id -u "$user_name" >/dev/null 2>&1; then
                    user_grp="$(id -gn "$user_name" 2>/dev/null || echo "$user_name")"
                    chown "$user_name:$user_grp" "$target" 2>/dev/null || true
                fi
                # GNOME 需标记为可信才显示图标而非问号
                if [ "$user_name" != "root" ] && command -v gio >/dev/null 2>&1; then
                    sudo -u "$user_name" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$user_name")/bus" \
                        gio set "$target" metadata::trusted true 2>/dev/null || true
                fi
                echo "已创建桌面图标: $target"
            fi
        done
    done
fi
# ---- END desktop-shortcut ----
POSTEOF
    chmod 755 "$POSTINST"
    step "  postinst 已注入桌面图标创建逻辑"
}

# ============================================================================
# 阶段 4/5：构建 deb（原 build.sh）—— 结果写入全局 DEB_FILE
# ============================================================================
DEB_FILE=""

bump_version() {
    local current="$1" base rev
    if [[ "${current}" =~ ^([0-9]+(\.[0-9]+)+)-([0-9]+)$ ]]; then
        base="${BASH_REMATCH[1]}"; rev=$(( ${BASH_REMATCH[3]} + 1 ))
        echo "${base}-${rev}"
    elif [[ "${current}" =~ ^([0-9]+(\.[0-9]+)+)$ ]]; then
        echo "${current}-1"
    else
        die "无法自增版本号: ${current}"
    fi
}

stage_deb() {
    log "阶段 4/5：构建 deb 包"
    [[ -f "${CONTROL_FILE}" ]] || die "未找到 ${CONTROL_FILE}，请确认 deb-pkg/ 目录结构正确"
    [[ -d "${PKG_DIR}/opt" ]] || die "未找到 ${PKG_DIR}/opt，打包目录结构不完整"

    local old_version new_version mver old_base
    old_version="$(grep -E '^Version: ' "${CONTROL_FILE}" | head -n 1 | sed -E 's/^Version:[[:space:]]+//')"
    [[ -n "${old_version}" ]] || die "无法解析 ${CONTROL_FILE} 的 Version"

    # 版本同步：以 TraeWork manifest.json 的 appVersion 为真实应用版本，
    # 避免 control 长期写死、与安装包脱节（旧版曾固定 0.1.58 一路错标）。
    # 同 appVersion 仅自增修订号；安装包升级（appVersion 变化）则重置为 -1。
    mver=""
    if [[ -f "${APP_DIR}/manifest.json" ]]; then
        mver="$(grep -o '"appVersion"\s*:\s*"[^"]*"' "${APP_DIR}/manifest.json" \
                | head -n1 | sed -E 's/.*"appVersion"\s*:\s*"([^"]*)".*/\1/')"
    fi
    old_base="${old_version%%-*}"
    if [[ -n "${mver}" && "${old_base}" == "${mver}" ]]; then
        new_version="$(bump_version "${old_version}")"
    elif [[ -n "${mver}" ]]; then
        new_version="${mver}-1"
    else
        new_version="$(bump_version "${old_version}")"
    fi
    sed -i "s/^Version: .*/Version: ${new_version}/" "${CONTROL_FILE}"
    step "版本: ${old_version} -> ${new_version}${mver:+ (manifest.appVersion=${mver})}"

    # 重算 Installed-Size（单位 KiB，排除 DEBIAN 元数据）：手写值会随内容增删而过期，
    # 导致系统「应用管理」显示体积失真（实测虚标 1.6G vs 磁盘实际 1.2G）
    local installed_size
    installed_size="$(du -s --block-size=1K --exclude=DEBIAN "${PKG_DIR}" | cut -f1)"
    if grep -qE '^Installed-Size: ' "${CONTROL_FILE}"; then
        sed -i "s/^Installed-Size: .*/Installed-Size: ${installed_size}/" "${CONTROL_FILE}"
    else
        sed -i "/^Version: /a Installed-Size: ${installed_size}" "${CONTROL_FILE}"
    fi
    step "Installed-Size 重算: ${installed_size} KiB ($(awk -v k="${installed_size}" 'BEGIN{printf "%.2f GiB", k/1024/1024}'))"

    # 维护脚本权限
    chmod 755 "${PKG_DIR}/DEBIAN/postinst" "${PKG_DIR}/DEBIAN/prerm" "${PKG_DIR}/DEBIAN/postrm"

    # 递归生成数据文件 md5sums（排除 DEBIAN 元数据目录，路径去掉 ./ 前缀）
    : > "${PKG_DIR}/DEBIAN/md5sums"
    (
        cd "${PKG_DIR}"
        find . -path ./DEBIAN -prune -o -type f -print0 | xargs -0 md5sum | sed 's| \./| |'
    ) > "${PKG_DIR}/DEBIAN/md5sums"
    step "md5sums 已重新生成: $(wc -l < "${PKG_DIR}/DEBIAN/md5sums") 个文件"

    # 构建 deb（root 属主）
    DEB_FILE="${SCRIPT_DIR}/trae-solo-cn_${new_version}_${DEB_ARCH}.deb"
    dpkg-deb --build --root-owner-group "${PKG_DIR}" "${DEB_FILE}"
    step "产物: ${DEB_FILE} ($(du -h "${DEB_FILE}" | cut -f1))"
}

# 定位现有最新 deb（--ll-only 模式或拆包后未构建时复用）
locate_latest_deb() {
    DEB_FILE="$(ls -t "${SCRIPT_DIR}"/trae-solo-cn_*_${DEB_ARCH}.deb 2>/dev/null | head -n 1 || true)"
    [[ -n "${DEB_FILE}" ]] || die "未找到 deb 包，请先构建或放置 trae-solo-cn_*_${DEB_ARCH}.deb 于项目目录"
    DEB_FILE="$(realpath "${DEB_FILE}")"
}

# ============================================================================
# 阶段 5/5：转制玲珑 uab（原 build-linglong.sh）—— 结果写入全局 UAB
# ============================================================================
UAB=""

stage_ll() {
    log "阶段 5/5：转换玲珑 uab 包"
    local tool
    for tool in ll-pica ll-builder ll-cli python3; do
        command -v "${tool}" >/dev/null 2>&1 || die "缺少必需命令: ${tool}（请安装 linglong-pica / linglong-builder / linglong-bin）"
    done
    step "工具检查通过: ll-pica / ll-builder / ll-cli / python3"

    # 准备 ll-pica 全局配置
    local PICA_CFG="${HOME}/.pica/config.json"
    mkdir -p "$(dirname "${PICA_CFG}")"
    if [[ ! -f "${PICA_CFG}" ]]; then
        cat > "${PICA_CFG}" <<'CFG'
{"version":"25.2.1.5","base_version":"25.2.1.3","source":"https://ci.deepin.com/repo/deepin/deepin-community/stable","distro_version":"crimson/release","arch":"amd64"}
CFG
        step "已创建 ll-pica 全局配置: ${PICA_CFG}"
    fi

    # 转换：deb -> package.yaml + linglong.yaml
    step "清理并重建工作目录: ${WORKDIR}"
    # ll-builder 的 overlay work 目录权限为 000，删除前先恢复权限
    if [[ -d "${WORKDIR}" ]]; then
        find "${WORKDIR}" -type d -perm 000 -exec chmod 700 {} + 2>/dev/null || true
    fi
    rm -rf "${WORKDIR}"
    step "运行 ll-pica convert ..."
    ll-pica convert -c "${DEB_FILE}" -w "${WORKDIR}" >/dev/null 2>&1 \
        || ll-pica convert -c "${DEB_FILE}" -w "${WORKDIR}"  # 失败时重跑以显示日志

    local LINGLONG_YAML="${LL_PKG_DIR}/linglong.yaml"
    [[ -f "${LINGLONG_YAML}" ]] || die "转换失败：未生成 ${LINGLONG_YAML}"

    # 从 deb 版本同步玲珑版本号（0.1.58-5 -> 0.1.58.5），应用本项目已验证的适配修复
    local DEB_BASE LL_VER
    DEB_BASE="$(basename "${DEB_FILE}")"
    LL_VER=""
    if [[ "${DEB_BASE}" =~ _([0-9]+(\.[0-9]+)+)(-([0-9]+))?_ ]]; then
        LL_VER="${BASH_REMATCH[1]}"
        [[ -n "${BASH_REMATCH[4]}" ]] && LL_VER="${LL_VER}.${BASH_REMATCH[4]}"
    fi
    step "应用玲珑适配修复 (fix-linglong-yaml.py) ..."
    if [[ -n "${LL_VER}" ]]; then
        python3 "${FIX_SCRIPT}" "${LINGLONG_YAML}" --version "${LL_VER}"
    else
        python3 "${FIX_SCRIPT}" "${LINGLONG_YAML}"
    fi

    # 校验 YAML 与关键字段
    python3 - <<'PY' "${LINGLONG_YAML}"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["package"]["kind"] == "app", "package.kind 应为 app"
assert d["base"] == "org.deepin.base/25.2.2", f"base 异常: {d['base']}"
assert d["command"] == ["/opt/apps/trae-solo-cn/files/bin/trae-solo-cn"], f"command 异常: {d['command']}"
assert "WRAPPER" in d["build"], "build 中缺少 bin 包装脚本"
print(f"    OK  版本={d['package']['version']}  base={d['base']}  command={d['command'][0]}")
PY

    # 构建 + 导出 uab
    step "ll-builder build ..."
    cd "${LL_PKG_DIR}"
    ll-builder build 2>&1 | tail -n 5

    step "ll-builder export ..."
    rm -f trae-solo-cn_*.uab
    ll-builder export 2>&1 | tail -n 3
    UAB="$(ls -t trae-solo-cn_*_x86_64_main.uab 2>/dev/null | head -n 1 || true)"
    [[ -n "${UAB}" ]] || die "导出失败：未生成 uab 文件"
    UAB="$(realpath "${UAB}")"
    cd "${SCRIPT_DIR}"
    step "产物: ${UAB} ($(du -h "${UAB}" | cut -f1))"
}

# ============================================================================
# 安装（收尾，不属 5 个构建阶段）
# ============================================================================
stage_install() {
    log "安装"
    if [[ "${DO_DEB}" -eq 1 ]]; then
        step "安装 deb 版 ..."
        sudo dpkg -i "${DEB_FILE}" 2>&1 | tail -n 3
    fi
    if [[ "${DO_LL}" -eq 1 && -n "${UAB}" ]]; then
        step "安装玲珑版 ..."
        ll-cli uninstall trae-solo-cn >/dev/null 2>&1 || true
        ll-cli install "${UAB}" 2>&1 | tail -n 1
        step "安装完成，可从开始菜单或 'll-cli run trae-solo-cn' 启动"
    fi
}

# ============================================================================
# 主流程
# ============================================================================
if [[ "${DO_EXTRACT}" -eq 1 ]]; then
    stage_extract
fi
# 精简：--slim 时执行（作用于 deb-pkg，故必须在打包前）
if [[ "${DO_SLIM}" -eq 1 ]]; then
    stage_slim
fi
# 桌面集成：必须在 stage_deb 之前——stage_deb 只是打包，而图标生成、
# 启动脚本 chmod 755 都作用于 deb-pkg 源目录；尤其 --skip-extract 时
# stage_extract（含其 chmod）被跳过，若不在此修权限，打包出的启动脚本
# 会是 644，导致菜单点击无反应
if [[ "${DO_DEB}" -eq 1 ]]; then
    stage_desktop
    stage_deb
elif [[ "${DO_LL}" -eq 1 ]]; then
    locate_latest_deb
fi
if [[ "${DO_LL}" -eq 1 ]]; then
    stage_ll
fi
if [[ "${DO_INSTALL}" -eq 1 ]]; then
    stage_install
fi

echo ""
echo "======================================================================"
echo " 完成！当前版本："
if [[ "${DO_DEB}" -eq 1 ]]; then
    echo "   deb 版 : $(basename "${DEB_FILE}")   (入口: TRAE SOLO CN, 运行 /opt/trae-solo-cn/trae-solo-cn)"
fi
if [[ "${DO_LL}" -eq 1 && -n "${UAB}" ]]; then
    echo "   玲珑版 : $(basename "${UAB}")   (入口: TRAE SOLO CN (玲珑版), 运行 ll-cli run trae-solo-cn)"
fi
if [[ "${DO_INSTALL}" -ne 1 ]]; then
    echo "   （--no-install：未安装，产物已生成）"
fi
echo "======================================================================"
