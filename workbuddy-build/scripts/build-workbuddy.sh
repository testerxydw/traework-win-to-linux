#!/usr/bin/env bash
# ============================================================================
# WorkBuddy → Linux 一键构建脚本（仅产 deb）
#
# 流水线：拆包 Windows 安装包 → 拆包社区 Electron 运行时 → 组装 deb-pkg → 构建 deb
#
# 用法：
#   bash build-workbuddy.sh
#       # 自动查找当前目录下的 WorkBuddy-win32-x64-user-*.exe 与
#       # cn.workbuddy.otohime_*.deb（社区移植版，提供 Electron 39.2.7 运行时）
#   bash build-workbuddy.sh <Windows安装包.exe> <社区移植版.deb>
#   bash build-workbuddy.sh --extracted <已解包的WorkBuddy目录> <社区移植版.deb>
#       # 复用已解包的 WorkBuddy（含 resources/app.asar 与 app.asar.unpacked）
#   bash build-workbuddy.sh --skip-extract
#       # 跳过拆包，直接基于现有 wb_pkg 重新构建 deb（重算 md5sums/Installed-Size）
#   bash build-workbuddy.sh --no-install
#       # 构建但不安装
#   bash build-workbuddy.sh --install-deps
#       # 仅安装构建所需系统依赖后退出
#   bash build-workbuddy.sh -h | --help
#
# 源材料（需自行准备，置于项目根目录或显式指定）：
#   1. WorkBuddy Windows 安装包（NSIS/7z 自解压，如 WorkBuddy-win32-x64-user-*.exe）
#   2. 社区移植版 deb（cn.workbuddy.otohime_*.deb）—— 提供 **Electron 39.2.7** 运行时
#      ★ 必须用此版本运行时：WorkBuddy 5.3.14 的原生模块 ABI 与 Electron 39 匹配；
#        跨大版本（如 CodeBuddy 的 Electron 37）会导致 daemon 子进程 SIGSEGV。
#
# 产物：
#   workbuddy_<版本>_amd64.deb  （如 workbuddy_5.3.14-1_amd64.deb）
#   安装后入口：workbuddy（/opt/workbuddy/workbuddy），桌面文件 WorkBuddy
#
# 重要适配点（已在打包目录固化，脚本保持透明）：
#   - 启动脚本已带 --title-bar-style=custom（让自绘标题栏三键正常显示）
#   - 默认 --no-sandbox（Linux 沙箱受限，可用 WORKBUDDY_ENABLE_SANDBOX=1 开启）
#   - 社区原生模块（含 qimei-node Linux 版）整体复用，避免 ABI 冲突
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"          # workbuddy-build 目录（wb_pkg 与产物默认放这里）
SRC_DIR="$(cd "${ROOT_DIR}/.." && pwd)"             # 项目根目录（源材料 .exe/.deb 默认放这里）
WORK_DIR="${SRC_DIR}"                               # 源材料 / 解包产物默认在项目根
PKG_DIR="${ROOT_DIR}/wb_pkg"
APP_DIR="${PKG_DIR}/opt/workbuddy"
RES_DIR="${APP_DIR}/resources"
CONTROL_FILE="${PKG_DIR}/DEBIAN/control"
DEB_ARCH="amd64"

# 兼容部分构建环境 PATH 不完整的问题（追加，不覆盖）
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

die()  { echo "错误: $*" >&2; exit 1; }
log()  { echo ""; echo "==================================================================="; echo "==> $*"; echo "==================================================================="; }
step() { echo ">>> $*"; }

usage() {
    grep -E '^#   ' "$0" | sed 's/^#   //'
    exit 1
}

# ---------- 依赖安装 ----------
install_deps() {
    log "安装构建依赖（仅装缺失项）"
    command -v sudo >/dev/null 2>&1 || die "缺少 sudo，无法自动安装依赖"

    local apt_pkgs=()
    local cmd pkg
    for pair in \
        "7z:7zip" \
        "rsync:rsync" \
        "python3:python3" \
        "dpkg-deb:dpkg" \
        "jq:jq" \
        "innoextract:innoextract" \
        "dpkg-deb:dpkg"; do
        cmd="${pair%%:*}"; pkg="${pair##*:}"
        command -v "$cmd" >/dev/null 2>&1 || apt_pkgs+=("$pkg")
    done

    # 去重
    if [[ ${#apt_pkgs[@]} -gt 0 ]]; then
        local uniq
        uniq="$(printf '%s\n' "${apt_pkgs[@]}" | awk '!seen[$0]++' | tr '\n' ' ')"
        step "apt 安装: ${uniq}"
        sudo apt-get update -qq || step "apt update 失败，继续尝试安装"
        # shellcheck disable=SC2086
        sudo apt-get install -y --no-install-recommends ${uniq} || die "apt 安装失败，请手动安装以上包"
    else
        step "apt 包均已就绪"
    fi
    step "依赖安装完成，可重新执行构建命令"
}

# ---------- 参数解析 ----------
WIN_EXE=""
COMMUNITY_DEB=""
EXTRACTED_DIR=""
DO_EXTRACT=1
DO_INSTALL=1
RUN_INSTALL_DEPS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --extracted)    EXTRACTED_DIR="$2"; shift 2 ;;
        --skip-extract) DO_EXTRACT=0; shift ;;
        --no-install)   DO_INSTALL=0; shift ;;
        --install-deps) RUN_INSTALL_DEPS=1; shift ;;
        -h|--help)      usage ;;
        *.exe)          [[ -z "$WIN_EXE" ]] && WIN_EXE="$1"; shift ;;
        *.deb)          [[ -z "$COMMUNITY_DEB" ]] && COMMUNITY_DEB="$1"; shift ;;
        *) echo "未知参数: $1" >&2; usage ;;
    esac
done

if [[ "${RUN_INSTALL_DEPS}" -eq 1 ]]; then
    install_deps
    exit 0
fi

# ---------- 依赖检查 ----------
for tool in rsync python3 dpkg-deb sed grep md5sum chmod 7z; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少依赖: $tool（可运行 bash $0 --install-deps 自动安装）"
done

# ============================================================================
# 阶段 1/N：拆包 + 组装 wb_pkg
# ============================================================================
stage_extract() {
    log "阶段 1：拆包 WorkBuddy 与社区 Electron 运行时并组装 wb_pkg"

    # ---------- 定位源材料 ----------
    if [[ -z "$WIN_EXE" && -z "$EXTRACTED_DIR" ]]; then
        WIN_EXE="$(ls -t "${WORK_DIR}"/WorkBuddy-win32-x64-user-*.exe 2>/dev/null | head -n 1 || true)"
    fi
    if [[ -z "$COMMUNITY_DEB" ]]; then
        COMMUNITY_DEB="$(ls -t "${WORK_DIR}"/cn.workbuddy.otohime_*.deb 2>/dev/null | head -n 1 || true)"
    fi
    [[ -n "$COMMUNITY_DEB" ]] || die "未找到社区移植版 deb（cn.workbuddy.otohime_*.deb），请放置到 ${WORK_DIR} 或显式指定"
    [[ -f "$COMMUNITY_DEB" ]] || die "社区 deb 不存在: $COMMUNITY_DEB"

    # ---------- 1. 拆包 WorkBuddy（得到 app.asar + app.asar.unpacked） ----------
    local WBSRC=""
    if [[ -n "$EXTRACTED_DIR" ]]; then
        [[ -d "$EXTRACTED_DIR" ]] || die "解包目录不存在: $EXTRACTED_DIR"
        WBSRC="$EXTRACTED_DIR"
    else
        [[ -n "$WIN_EXE" ]] || die "未找到 Windows 安装包（WorkBuddy-win32-x64-user-*.exe）"
        [[ -f "$WIN_EXE" ]] || die "安装包不存在: $WIN_EXE"
        local WB_EXTRACT="${ROOT_DIR}/wb_extract"
        rm -rf "$WB_EXTRACT" && mkdir -p "$WB_EXTRACT"
        step "解压 WorkBuddy 安装包 (NSIS 自解压, 7z) ..."
        7z x -y -o"$WB_EXTRACT" "$WIN_EXE" >/dev/null
        # NSIS 包结构：应用主体嵌套在 $PLUGINSDIR/app-64.7z 内，二次解压得到
        # WorkBuddy.exe + resources/app.asar + resources/app.asar.unpacked
        local APP7Z
        APP7Z="$(find "$WB_EXTRACT" -name 'app-64.7z' 2>/dev/null | head -n 1)"
        if [[ -n "$APP7Z" ]]; then
            step "二次解压 app-64.7z ..."
            local WB_INNER="${WB_EXTRACT}/app64"
            mkdir -p "$WB_INNER"
            7z x -y -o"$WB_INNER" "$APP7Z" >/dev/null
            WBSRC="$WB_INNER"
        else
            # 退化：直接找 resources/app.asar
            WBSRC="$WB_EXTRACT"
            [[ -f "$WBSRC/resources/app.asar" ]] || WBSRC="$WB_EXTRACT/resources"
        fi
        [[ -f "$WBSRC/resources/app.asar" ]] || die "解包后未找到 resources/app.asar"
    fi
    step "WorkBuddy 源: $WBSRC"

    # ---------- 2. 拆包社区 deb（得到 Electron 39.2.7 运行时 + 完整原生模块） ----------
    local COMM_EXTRACT="${ROOT_DIR}/community_extract"
    rm -rf "$COMM_EXTRACT" && mkdir -p "$COMM_EXTRACT"
    step "解包社区移植版 deb ..."
    dpkg-deb -x "$COMMUNITY_DEB" "$COMM_EXTRACT" >/dev/null

    # 社区版结构为玲珑导出：运行时在 files/workbuddy，原生模块在
    # files/resources/app.asar.unpacked/node_modules。
    local COMM_BIN COMM_UNPACKED
    COMM_BIN="$(find "$COMM_EXTRACT" -type f -name 'workbuddy' -path '*files/*' 2>/dev/null | head -n 1)"
    COMM_UNPACKED="$(find "$COMM_EXTRACT" -type d -name 'app.asar.unpacked' -path '*files/resources/*' 2>/dev/null | head -n 1)"
    [[ -n "$COMM_BIN" ]] || die "社区 deb 内未找到 files/workbuddy 运行时"
    [[ -n "$COMM_UNPACKED" ]] || die "社区 deb 内未找到 files/resources/app.asar.unpacked"

    # ---------- 3. 组装 wb_pkg ----------
    step "组装 wb_pkg ..."
    mkdir -p "$APP_DIR" "$RES_DIR"

    # 3a. Electron 运行时二进制
    cp -f "$COMM_BIN" "$APP_DIR/workbuddy-bin"
    chmod 755 "$APP_DIR/workbuddy-bin"

    # 3b. Chromium 运行时配套文件（.pak/.so/dat/.bin/icd/version/sandbox/crashpad）
    local f
    for f in chrome_100_percent.pak chrome_200_percent.pak resources.pak icudtl.dat \
             snapshot_blob.bin v8_context_snapshot.bin vk_swiftshader_icd.json version \
             chrome-sandbox chrome_crashpad_handler LICENSE; do
        cp -f "$(dirname "$COMM_BIN")/$f" "$APP_DIR/" 2>/dev/null || true
    done
    cp -f "$(dirname "$COMM_BIN")"/*.so "$APP_DIR/" 2>/dev/null || true
    cp -f "$(dirname "$COMM_BIN")"/libvulkan.so.* "$APP_DIR/" 2>/dev/null || true
    # locales
    if [[ -d "$(dirname "$COMM_BIN")/locales" ]]; then
        rsync -a --delete "$(dirname "$COMM_BIN")/locales/" "$APP_DIR/locales/"
    fi

    # 3c. 应用代码（官方 Windows app.asar）
    cp -f "$WBSRC/resources/app.asar" "$RES_DIR/"
    # 3d. 原生模块整体复用社区版（ABI 与 Electron 39 一致，含 qimei-node Linux 版）
    if [[ -d "$COMM_UNPACKED" ]]; then
        rsync -a --delete "$COMM_UNPACKED/" "$RES_DIR/app.asar.unpacked/"
    fi

    # 3e. 启动脚本（已内建 --title-bar-style=custom 与 --no-sandbox 逻辑）
    if [[ ! -f "$APP_DIR/workbuddy" ]]; then
        cat > "$APP_DIR/workbuddy" <<'LAUNCHER'
#!/usr/bin/env bash
# WorkBuddy for Linux 启动脚本
set -euo pipefail
APP_DIR="/opt/workbuddy"
ELECTRON="${APP_DIR}/workbuddy-bin"
[[ -x "${ELECTRON}" ]] || { echo "错误：未找到 Electron 运行时 ${ELECTRON}" >&2; exit 1; }
SANDBOX_ARG="--no-sandbox"
[[ "${WORKBUDDY_ENABLE_SANDBOX:-0}" == "1" ]] && SANDBOX_ARG=""
exec "${ELECTRON}" ${SANDBOX_ARG:+$SANDBOX_ARG} --disable-dev-shm-usage --title-bar-style=custom "$@"
LAUNCHER
    fi
    chmod 755 "$APP_DIR/workbuddy"

    # 3f. desktop / 图标（优先复用社区版，其次 Windows 自带）
    local COMM_DESKTOP COMM_ICON WBSRC_ICON
    COMM_DESKTOP="$(find "$COMM_EXTRACT" -name '*.desktop' 2>/dev/null | head -n 1)"
    COMM_ICON="$(find "$COMM_EXTRACT" \( -name '*.png' -o -name '*.svg' \) 2>/dev/null | head -n 1)"
    WBSRC_ICON="$WBSRC/resources/app.asar.unpacked/resources/icon.png"
    mkdir -p "$PKG_DIR/usr/share/applications" "$PKG_DIR/usr/share/icons/hicolor/256x256/apps"
    if [[ -n "$COMM_DESKTOP" ]]; then
        cp -f "$COMM_DESKTOP" "$PKG_DIR/usr/share/applications/workbuddy.desktop"
    fi
    if [[ -n "$COMM_ICON" ]]; then
        cp -f "$COMM_ICON" "$PKG_DIR/usr/share/icons/hicolor/256x256/apps/workbuddy.png" 2>/dev/null || true
    elif [[ -f "$WBSRC_ICON" ]]; then
        cp -f "$WBSRC_ICON" "$PKG_DIR/usr/share/icons/hicolor/256x256/apps/workbuddy.png"
    fi
    # desktop 中 Exec 统一指向 /usr/bin/workbuddy（postinst 建 symlink）
    if [[ -f "$PKG_DIR/usr/share/applications/workbuddy.desktop" ]]; then
        sed -i -E 's/^Exec=.*/Exec=workbuddy/' "$PKG_DIR/usr/share/applications/workbuddy.desktop"
        sed -i -E 's/^Icon=.*/Icon=workbuddy/' "$PKG_DIR/usr/share/applications/workbuddy.desktop"
    fi

    # 3g. 维护脚本（postinst 设置权限 + 刷新桌面数据库；postrm 清理）
    mkdir -p "$PKG_DIR/DEBIAN"
    cat > "$PKG_DIR/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ -e /opt/workbuddy/chrome-sandbox ]; then
    chown root:root /opt/workbuddy/chrome-sandbox || true
    chmod 4755 /opt/workbuddy/chrome-sandbox || true
fi
chmod 755 /opt/workbuddy/workbuddy /opt/workbuddy/workbuddy-bin || true
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
fi
exit 0
POSTINST
    cat > "$PKG_DIR/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
exit 0
PRERM
    cat > "$PKG_DIR/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
fi
exit 0
POSTRM
    chmod 755 "$PKG_DIR/DEBIAN"/postinst "$PKG_DIR/DEBIAN"/prerm "$PKG_DIR/DEBIAN"/postrm

    # 3h. 确保 /usr/bin 入口（postinst 安装时建 symlink；此处仅占位提示）
    mkdir -p "$PKG_DIR/usr/bin"
    ln -sf /opt/workbuddy/workbuddy "$PKG_DIR/usr/bin/workbuddy" 2>/dev/null || true

    step "wb_pkg 组装完成"
}

# ============================================================================
# 阶段 2：构建 deb
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
    log "阶段 2：构建 deb 包"
    [[ -f "${CONTROL_FILE}" ]] || die "未找到 ${CONTROL_FILE}"
    [[ -d "${PKG_DIR}/opt" ]] || die "未找到 ${PKG_DIR}/opt，打包目录结构不完整"

    # 初次构建若无 control，自动生成最小 control
    if [[ ! -f "${CONTROL_FILE}" ]]; then
        local ver
        ver="$(strings "$RES_DIR/app.asar" 2>/dev/null | grep -oE 'WorkBuddy[^"]*5\.[0-9.]+' | head -n1 | grep -oE '5\.[0-9.]+' || true)"
        [[ -n "$ver" ]] || ver="5.3.14"
        cat > "${CONTROL_FILE}" <<CTRL
Package: workbuddy
Version: ${ver}-1
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Local Porter <local@localhost>
Homepage: https://www.codebuddy.ai
Depends: libc6 (>= 2.28), libstdc++6, libgtk-3-0 | libgtk-4-1, libnss3, libxss1, libxtst6, libasound2 | libasound2t64, libgbm1, libdrm2, libatk-bridge2.0-0 | libatk-bridge2.0-0t64, libatk1.0-0 | libatk1.0-0t64, libatspi2.0-0 | libatspi2.0-0t64, libcairo2, libpango-1.0-0 | libpango-1.0-0t64, libx11-6, libxcb1, libxcomposite1 | libxcomposite1t64, libxdamage1 | libxdamage1t64, libxext6 | libxext6t64, libxfixes3 | libxfixes3t64, libxkbcommon0, libxkbfile1 | libxkbfile1t64, libxrandr2 | libxrandr2t64, libglib2.0-0 | libglib2.0-0t64, libnspr4, libudev1, xdg-utils
Recommends: git, python3
Description: WorkBuddy - AI Agent 桌面工作台 (Linux 移植版)
 WorkBuddy 是腾讯推出的 AI Agent 桌面应用。本包为 Linux 移植版：
 应用代码取自官方 Windows 版安装包，Electron 运行时采用社区移植版
 （Electron 39.2.7，ABI 与 WorkBuddy 5.3.14 原生模块匹配）。
 .
 已知限制：受平台差异影响，部分依赖 Windows 原生能力的特性不可用，
 例如微信消息解码（wechat-copydata-decoder）缺失自动降级。
 .
 非官方移植，仅供学习交流。
CTRL
    fi

    local old_version new_version
    old_version="$(grep -E '^Version: ' "${CONTROL_FILE}" | head -n 1 | sed -E 's/^Version:[[:space:]]+//')"
    [[ -n "${old_version}" ]] || die "无法解析 ${CONTROL_FILE} 的 Version"
    new_version="$(bump_version "${old_version}")"
    sed -i "s/^Version: .*/Version: ${new_version}/" "${CONTROL_FILE}"
    step "版本: ${old_version} -> ${new_version}"

    # 重算 Installed-Size（KiB，排除 DEBIAN）
    local installed_size
    installed_size="$(du -s --block-size=1K --exclude=DEBIAN "${PKG_DIR}" | cut -f1)"
    if grep -qE '^Installed-Size: ' "${CONTROL_FILE}"; then
        sed -i "s/^Installed-Size: .*/Installed-Size: ${installed_size}/" "${CONTROL_FILE}"
    else
        sed -i "/^Version: /a Installed-Size: ${installed_size}" "${CONTROL_FILE}"
    fi
    step "Installed-Size 重算: ${installed_size} KiB ($(awk -v k="${installed_size}" 'BEGIN{printf "%.2f GiB", k/1024/1024}'))"

    # 递归生成 md5sums（排除 DEBIAN，路径去 ./ 前缀）
    (
        cd "${PKG_DIR}"
        find . -path ./DEBIAN -prune -o -type f -print0 | xargs -0 md5sum | sed 's| \./| |'
    ) > "${PKG_DIR}/DEBIAN/md5sums"
    step "md5sums 已重新生成: $(wc -l < "${PKG_DIR}/DEBIAN/md5sums") 个文件"

    DEB_FILE="${ROOT_DIR}/workbuddy_${new_version}_${DEB_ARCH}.deb"
    dpkg-deb --build --root-owner-group "${PKG_DIR}" "${DEB_FILE}"
    step "产物: ${DEB_FILE} ($(du -h "${DEB_FILE}" | cut -f1))"
}

# ============================================================================
# 阶段 3：安装
# ============================================================================
stage_install() {
    log "阶段 3：安装"
    step "sudo dpkg -i ${DEB_FILE} ..."
    sudo dpkg -i "${DEB_FILE}" 2>&1 | tail -n 3
    step "安装完成，可从开始菜单或命令行 'workbuddy' 启动"
}

# ============================================================================
# 主流程
# ============================================================================
if [[ "${DO_EXTRACT}" -eq 1 ]]; then
    stage_extract
fi
stage_deb
if [[ "${DO_INSTALL}" -eq 1 ]]; then
    stage_install
fi

echo ""
echo "======================================================================"
echo " 完成！"
echo "   deb : $(basename "${DEB_FILE}")"
echo "   入口: workbuddy (运行 /opt/workbuddy/workbuddy)"
[[ "${DO_INSTALL}" -ne 1 ]] && echo "   （--no-install：未安装，产物已生成）"
echo "======================================================================"
