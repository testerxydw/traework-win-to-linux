#!/usr/bin/env bash
# ============================================================================
# TRAE SOLO CN 一键构建脚本（唯一入口）
#
# 流水线：拆包 Windows 安装包 → 组装 deb-pkg → 构建 deb → 转制玲珑 uab → 安装
#
# 用法：
#   bash build.sh                                # 完整流水线（自动查找目录下 TraeWork_CN-Setup*.exe）
#   bash build.sh /path/TraeWork_CN-Setup-x64.exe  # 指定 Windows 安装包
#   bash build.sh --extracted <解压目录>           # 复用已解压目录（.../code$GetDestDir）
#   bash build.sh --skip-extract                 # 跳过拆包，复用现有 deb-pkg 直接构建
#   bash build.sh --deb-only                     # 拆包 + 构建 deb + 安装 deb（不转玲珑）
#   bash build.sh --ll-only                      # 仅用现有最新 deb 构建玲珑 + 安装玲珑
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
DO_LL=1
DO_INSTALL=1
RUN_INSTALL_DEPS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --extracted)   EXTRACTED_DIR="$2"; shift 2 ;;
        --skip-extract) DO_EXTRACT=0; shift ;;
        --deb-only)    DO_LL=0; shift ;;
        --ll-only)     DO_EXTRACT=0; DO_DEB=0; shift ;;
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
# 阶段 1/4：拆包 + 组装 deb-pkg（原 setup.sh）
# ============================================================================
stage_extract() {
    log "阶段 1/4：拆包 Windows 安装包并组装 deb-pkg"

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
}

# ============================================================================
# 阶段 2/4：构建 deb（原 build.sh）—— 结果写入全局 DEB_FILE
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
    log "阶段 2/4：构建 deb 包"
    [[ -f "${CONTROL_FILE}" ]] || die "未找到 ${CONTROL_FILE}，请确认 deb-pkg/ 目录结构正确"
    [[ -d "${PKG_DIR}/opt" ]] || die "未找到 ${PKG_DIR}/opt，打包目录结构不完整"

    local old_version new_version
    old_version="$(grep -E '^Version: ' "${CONTROL_FILE}" | head -n 1 | sed -E 's/^Version:[[:space:]]+//')"
    [[ -n "${old_version}" ]] || die "无法解析 ${CONTROL_FILE} 的 Version"
    new_version="$(bump_version "${old_version}")"
    sed -i "s/^Version: .*/Version: ${new_version}/" "${CONTROL_FILE}"
    step "版本: ${old_version} -> ${new_version}"

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
# 阶段 3/4：转制玲珑 uab（原 build-linglong.sh）—— 结果写入全局 UAB
# ============================================================================
UAB=""

stage_ll() {
    log "阶段 3/4：转换玲珑 uab 包"
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
# 阶段 4/4：安装
# ============================================================================
stage_install() {
    log "阶段 4/4：安装"
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
if [[ "${DO_DEB}" -eq 1 ]]; then
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
