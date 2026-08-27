#!/usr/bin/env bash
# ============================================================================
# TRAE SOLO CN Linux 打包脚本
# 功能：自动递增版本号(upstream-revision)、重新生成 md5sums、构建 deb 包
# 用法：bash build.sh
# 产物：trae-solo-cn_<版本>_amd64.deb（与 deb-pkg/ 同目录）
# ============================================================================
set -euo pipefail

# 定位脚本所在目录（兼容任意 cwd 调用）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/deb-pkg"
CONTROL_FILE="${PKG_DIR}/DEBIAN/control"
DEB_ARCH="amd64"

# 兼容部分构建环境 PATH 不完整的问题（在原 PATH 基础上追加，不覆盖）
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# 输出错误并退出
die() {
    echo "错误: $*" >&2
    exit 1
}

# 检查依赖命令
check_tools() {
    local tool
    for tool in grep sed md5sum dpkg-deb chmod head cut; do
        command -v "${tool}" >/dev/null 2>&1 || die "缺少必需命令: ${tool}"
    done
}

# 读取 control 当前 Version 行
read_version() {
    local line
    line="$(grep -E '^Version: ' "${CONTROL_FILE}" | head -n 1)"
    [[ "${line}" =~ ^Version:[[:space:]]+([^ ]+) ]] && echo "${BASH_REMATCH[1]}" || die "无法解析 ${CONTROL_FILE} 的 Version"
}

# 版本号自增：形式为 <主版本>[-<修订号>]，修订号不存在时从 1 开始
bump_version() {
    local current base rev
    current="$1"
    if [[ "${current}" =~ ^([0-9]+(\.[0-9]+)+)-([0-9]+)$ ]]; then
        base="${BASH_REMATCH[1]}"
        rev="${BASH_REMATCH[3]}"
        rev=$((rev + 1))
        echo "${base}-${rev}"
    elif [[ "${current}" =~ ^([0-9]+(\.[0-9]+)+)$ ]]; then
        echo "${current}-1"
    else
        die "无法自增版本号: ${current}"
    fi
}

# 写回新版本号到 control
write_version() {
    local new_version="$1"
    sed -i "s/^Version: .*/Version: ${new_version}/" "${CONTROL_FILE}"
    echo "版本: ${old_version} -> ${new_version}"
}

# 递归生成数据文件 md5sums（排除 DEBIAN 元数据目录，路径去掉 ./ 前缀）
regenerate_md5sums() {
    : > "${PKG_DIR}/DEBIAN/md5sums"
    (
        cd "${PKG_DIR}"
        find . -path ./DEBIAN -prune -o -type f -print0 | xargs -0 md5sum | sed 's| \./| |'
    ) > "${PKG_DIR}/DEBIAN/md5sums"
    echo "md5sums 已重新生成: $(wc -l < "${PKG_DIR}/DEBIAN/md5sums") 个文件"
}

main() {
    local old_version new_version deb_file
    check_tools
    [[ -f "${CONTROL_FILE}" ]] || die "未找到 ${CONTROL_FILE}，请确认 deb-pkg/ 目录结构正确"
    [[ -d "${PKG_DIR}/opt" ]] || die "未找到 ${PKG_DIR}/opt，打包目录结构不完整"

    old_version="$(read_version)"
    new_version="$(bump_version "${old_version}")"
    write_version "${new_version}"

    # 维护脚本权限
    chmod 755 "${PKG_DIR}/DEBIAN/postinst" "${PKG_DIR}/DEBIAN/prerm" "${PKG_DIR}/DEBIAN/postrm"

    # 重新生成完整性校验
    regenerate_md5sums

    # 构建 deb（root 属主）
    deb_file="${SCRIPT_DIR}/trae-solo-cn_${new_version}_${DEB_ARCH}.deb"
    dpkg-deb --build --root-owner-group "${PKG_DIR}" "${deb_file}"

    echo ""
    echo "=== 构建成功 ==="
    dpkg-deb --info "${deb_file}" | head -n 8
    echo "产物: ${deb_file}"
    ls -lh "${deb_file}"
}

main "$@"