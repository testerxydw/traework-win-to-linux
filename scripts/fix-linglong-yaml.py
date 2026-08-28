#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
修复 ll-pica 自动生成的 linglong.yaml，使其适配 TRAE SOLO CN（Electron 应用）。

ll-pica 的自动转换存在以下无法正确处理的问题，本脚本统一修复：
  1. command 指向容器内不存在的路径（/opt/trae-solo-cn/...）→ 改为 $PREFIX/bin 包装脚本
  2. base 使用 25.2.1.3 / 带 DTK runtime → 改为 org.deepin.base/25.2.2，去掉 runtime（Electron 非 Qt 应用，参考官方 Edge 玲珑包）
  3. 构建脚本只复制 usr/*，遗漏应用主体 opt/trae-solo-cn（1.7GB）→ 追加复制到 $PREFIX/lib/trae-solo-cn
  4. Electron 需要 --no-sandbox → 修改启动脚本
  5. 桌面入口 Exec 使用容器内 PATH 找不到的命令 → 在 $PREFIX/bin 创建包装脚本

用法: python3 fix-linglong-yaml.py <linglong.yaml>
"""
import re
import sys

# 玲珑安装后的容器内 $PREFIX 绝对路径（由 appid 决定）
APP_PREFIX = "/opt/apps/trae-solo-cn/files"
BIN_WRAPPER = f"{APP_PREFIX}/bin/trae-solo-cn"
LIB_LAUNCHER = f"{APP_PREFIX}/lib/trae-solo-cn/trae-solo-cn"


def fix(path: str, version: str | None = None) -> None:
    with open(path, encoding="utf-8") as f:
        text = f.read()

    # ---------- 0. 同步 package.version（由 deb 修订号映射，如 0.1.54-14 -> 0.1.54.14） ----------
    if version:
        text = re.sub(r"^  version: .*$", f"  version: {version}", text, flags=re.M)
        print(f"[fix-linglong-yaml]   版本    = {version}")

    # ---------- 1. base / runtime ----------
    text = re.sub(r"^base: .*$", "base: org.deepin.base/25.2.2", text, flags=re.M)
    text = re.sub(r"^runtime: .*$\n?", "", text, flags=re.M)

    # ---------- 2. command -> $PREFIX/bin 包装脚本 ----------
    text = re.sub(
        r"^command:\n(?:  - .*\n)+",
        f'command:\n  - "{BIN_WRAPPER}"\n',
        text,
        flags=re.M,
    )

    # ---------- 3. build 中 desktop Exec 的绝对路径 -> 容器内可用路径 ----------
    #     （替换 pica 生成的 "/opt/trae-solo-cn/trae-solo-cn" 桌面入口路径）
    text = text.replace(
        "/opt/trae-solo-cn/trae-solo-cn", BIN_WRAPPER
    )

    # ---------- 4. 在 build 末尾追加本项目的适配步骤 ----------
    extra = f"""  # ---- linglong 适配（build-linglong.sh 自动追加，请勿手改）----
  # 复制应用主体 opt/trae-solo-cn -> $PREFIX/lib/trae-solo-cn
  install -d $PREFIX/lib/trae-solo-cn
  cp -a $EXTERNAL_DEB_SOURCES/trae-solo-cn/opt/trae-solo-cn/. $PREFIX/lib/trae-solo-cn/
  # 启动脚本：在玲珑沙箱内追加 --no-sandbox
  sed -i 's#exec "$ELECTRON" "$@"#exec "$ELECTRON" --no-sandbox --class=trae-solo-cn-linglong "$@"#' $PREFIX/lib/trae-solo-cn/trae-solo-cn
  chmod +x $PREFIX/lib/trae-solo-cn/trae-solo-cn $PREFIX/lib/trae-solo-cn/trae-solo-cn-bin
  # 移除 usr/bin 中指向 /opt 的失效软链
  rm -f $PREFIX/bin/trae-solo-cn
  # 创建容器 PATH 内可用的启动包装脚本（供桌面 Exec / ll-cli 使用）
  cat > $PREFIX/bin/trae-solo-cn <<'WRAPPER'
  #!/bin/bash
  exec {LIB_LAUNCHER} "$@"
  WRAPPER
  chmod +x $PREFIX/bin/trae-solo-cn
  # 桌面入口隔离：改名 + 应用名后缀，避免与 deb 版同名 desktop 冲突
  # （两个版本共存，菜单/桌面各显示一个图标）
  if [ -f $PREFIX/share/applications/trae-solo-cn.desktop ]; then
      sed -i 's/^Name=.*/Name=TRAE SOLO CN (玲珑版)/' $PREFIX/share/applications/trae-solo-cn.desktop
      sed -i 's/^StartupWMClass=.*/StartupWMClass=trae-solo-cn-linglong/' $PREFIX/share/applications/trae-solo-cn.desktop
      mv $PREFIX/share/applications/trae-solo-cn.desktop $PREFIX/share/applications/trae-solo-cn-linglong.desktop
  fi
"""
    marker = "#>>> auto generate by ll-pica end"
    if marker in text:
        text = text.replace(marker, extra.rstrip() + "\n" + marker, 1)
    else:
        # 标记不存在时，追加到 build: 块末尾（最后一个顶层键之前）
        text = text.rstrip() + "\n" + extra + "\n"

    with open(path, "w", encoding="utf-8") as f:
        f.write(text)

    print(f"[fix-linglong-yaml] 已修复: {path}")
    print(f"[fix-linglong-yaml]   base     = org.deepin.base/25.2.2 (无 runtime)")
    print(f"[fix-linglong-yaml]   command  = {BIN_WRAPPER}")


if __name__ == "__main__":
    args = sys.argv[1:]
    version = None
    if "--version" in args:
        i = args.index("--version")
        version = args[i + 1] if i + 1 < len(args) else None
        del args[i : i + 2]
    if len(args) != 1:
        print(__doc__)
        sys.exit(1)
    fix(args[0], version)
