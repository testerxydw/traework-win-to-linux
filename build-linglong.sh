#!/usr/bin/env bash
# ============================================================================
# TRAE SOLO CN 玲珑包构建脚本
#
# 功能：将 deb 包转换为如意玲珑 uab 包，封装 ll-pica + ll-builder 全流程，
#       并自动应用本项目已验证的适配修复（应用主体复制、--no-sandbox、
#       桌面入口 PATH 包装脚本等）。
#
# 用法：
#   bash build-linglong.sh                       # 使用目录下最新 deb 包
#   bash build-linglong.sh <deb文件>             # 指定 deb 包
#   bash build-linglong.sh <deb文件> --install   # 构建后安装到系统
#   bash build-linglong.sh <deb文件> --skip-build# 仅生成并修复 linglong.yaml，不构建
#
# 产物：pica-work/package/trae-solo-cn/trae-solo-cn_<ver>_x86_64_main.uab
#
# 依赖：ll-pica (linglong-pica)、ll-builder (linglong-builder)、
#       ll-cli (linglong-bin)、python3
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}/pica-work"
PKG_DIR="${WORKDIR}/package/trae-solo-cn"
FIX_SCRIPT="${SCRIPT_DIR}/scripts/fix-linglong-yaml.py"
DEB_ARCH="amd64"

# 兼容部分构建环境 PATH 不完整的问题
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

die() { echo "错误: $*" >&2; exit 1; }
log() { echo "==> $*"; }

usage() {
    grep -E '^#   ' "$0" | sed 's/^#   //'
    exit 1
}

# ---------- 参数解析 ----------
DEB_FILE=""
INSTALL=0
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) INSTALL=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) usage ;;
        *.deb) DEB_FILE="$1"; shift ;;
        *) echo "未知参数: $1" >&2; usage ;;
    esac
done

# ---------- 定位 deb 包 ----------
if [[ -z "${DEB_FILE}" ]]; then
    DEB_FILE="$(ls -t "${SCRIPT_DIR}"/trae-solo-cn_*_${DEB_ARCH}.deb 2>/dev/null | head -n 1 || true)"
    [[ -z "${DEB_FILE}" ]] && die "未找到 deb 包，请指定路径或放置 trae-solo-cn_*_${DEB_ARCH}.deb 于项目目录"
fi
[[ -f "${DEB_FILE}" ]] || die "deb 文件不存在: ${DEB_FILE}"
DEB_FILE="$(realpath "${DEB_FILE}")"
log "输入 deb: ${DEB_FILE}"

# ---------- 检查工具 ----------
for tool in ll-pica ll-builder ll-cli python3; do
    command -v "${tool}" >/dev/null 2>&1 || die "缺少必需命令: ${tool}（请安装 linglong-pica / linglong-builder / linglong-bin）"
done
log "工具检查通过: ll-pica / ll-builder / ll-cli / python3"

# ---------- 准备 ll-pica 全局配置 ----------
PICA_CFG="${HOME}/.pica/config.json"
mkdir -p "$(dirname "${PICA_CFG}")"
if [[ ! -f "${PICA_CFG}" ]]; then
    cat > "${PICA_CFG}" <<'CFG'
{"version":"25.2.1.5","base_version":"25.2.1.3","source":"https://ci.deepin.com/repo/deepin/deepin-community/stable","distro_version":"crimson/release","arch":"amd64"}
CFG
    log "已创建 ll-pica 全局配置: ${PICA_CFG}"
fi

# ---------- 转换：deb -> package.yaml + linglong.yaml ----------
log "清理并重建工作目录: ${WORKDIR}"
# ll-builder 的 overlay work 目录权限为 000，删除前先恢复权限
if [[ -d "${WORKDIR}" ]]; then
    find "${WORKDIR}" -type d -perm 000 -exec chmod 700 {} + 2>/dev/null || true
fi
rm -rf "${WORKDIR}"
log "运行 ll-pica convert ..."
ll-pica convert -c "${DEB_FILE}" -w "${WORKDIR}" >/dev/null 2>&1 \
    || ll-pica convert -c "${DEB_FILE}" -w "${WORKDIR}"  # 失败时重跑以显示日志

LINGLONG_YAML="${PKG_DIR}/linglong.yaml"
[[ -f "${LINGLONG_YAML}" ]] || die "转换失败：未生成 ${LINGLONG_YAML}"

# ---------- 应用本项目适配修复 ----------
log "应用玲珑适配修复 (fix-linglong-yaml.py) ..."
python3 "${FIX_SCRIPT}" "${LINGLONG_YAML}"

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

if [[ "${SKIP_BUILD}" -eq 1 ]]; then
    log "已生成并修复 ${LINGLONG_YAML}（--skip-build，未构建）"
    exit 0
fi

# ---------- 构建 ----------
log "ll-builder build ..."
cd "${PKG_DIR}"
ll-builder build 2>&1 | tail -n 5

# ---------- 导出 uab ----------
log "ll-builder export ..."
rm -f trae-solo-cn_*.uab
ll-builder export 2>&1 | tail -n 3
UAB="$(ls -t trae-solo-cn_*_x86_64_main.uab 2>/dev/null | head -n 1)"
[[ -n "${UAB}" ]] || die "导出失败：未生成 uab 文件"
UAB="$(realpath "${UAB}")"

echo ""
echo "======================================================================"
echo " 打包成功！"
echo "   产物: ${UAB}"
echo "   大小: $(du -h "${UAB}" | cut -f1)"
echo "   版本: $(python3 -c "import yaml,sys; print(yaml.safe_load(open('${LINGLONG_YAML}'))['package']['version'])")"
echo " 安装:  ll-cli install ${UAB}"
echo " 运行:  ll-cli run trae-solo-cn"
echo "======================================================================"

# ---------- 可选：安装到系统 ----------
if [[ "${INSTALL}" -eq 1 ]]; then
    log "安装到系统 ..."
    ll-cli uninstall trae-solo-cn >/dev/null 2>&1 || true
    ll-cli install "${UAB}" 2>&1 | tail -n 1
    log "安装完成，可从开始菜单或 'll-cli run trae-solo-cn' 启动"
fi
