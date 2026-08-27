# TraeWork CN → Linux deb 重打包

将 Windows 版 **TraeWork CN**（TRAE SOLO）拆解后重新打包为 Linux deb 包。

> ⚠️ 本项目为非官方移植，仅供学习交流。所有软件版权归原开发方（ByteDance）所有。

## 原理

TraeWork 与 TraeCode 同源（VS Code 1.107.1 内核），但使用不同的 UI 变体：

| 组件 | 来源 | 作用 |
|------|------|------|
| Electron 二进制 + 原生 `.so` | TraeCode CN **Linux** deb | Chromium 运行时、AI Agent、CKG 模块 |
| JS 资源 `out/` + `product.json` | TraeWork CN **Windows** 安装包 | solo-lite AI 工作台 UI |
| `@byted-icube/solo-lite/dist/` | TraeWork CN **Windows** 安装包 | UI 核心模块（TraeCode 没有此文件） |

## 文件结构

```
├── setup.sh              # 源文件提取脚本（重建 deb-pkg 大文件）
├── build.sh              # deb 构建脚本（版本自增 + md5sums + dpkg-deb）
├── deb-pkg/              # 打包目录
│   ├── DEBIAN/           # control/postinst/prerm/postrm（入库）
│   ├── opt/.../trae-solo-cn   # 启动脚本（入库）
│   └── opt/.../其余内容        # 由 setup.sh 生成（不入库）
├── pica-work/            # deepin pica 打包配置
├── docs/                 # 设计文档与实施计划
└── README-功能说明.md     # 功能可用/不可用清单
```

## 快速构建

前置：下载 `TraeWork_CN-Setup-x64.exe`，并安装（或下载）`TraeCode_CN-linux-x64.deb`。

```bash
# 1. 提取源文件，重建打包目录
bash setup.sh /path/to/TraeWork_CN-Setup-x64.exe

# 2. 构建 deb（版本自动递增）
bash build.sh

# 3. 安装
sudo dpkg -i trae-solo-cn_*_amd64.deb

# 4. 启动（桌面菜单 "TRAE SOLO CN"，或）
/opt/trae-solo-cn/trae-solo-cn --no-sandbox
```


## 玲珑包构建（如意玲珑 / uab）

在 deb 构建完成后，可用脚本一键转换为如意玲珑 uab 包（自动完成依赖解析、
Electron 沙箱适配、桌面入口修复等）：

```bash
# 1. 构建 deb（可选，若已有 trae-solo-cn_*_amd64.deb 可跳过）
bash build.sh

# 2. 转换并打包为玲珑 uab（自动选择最新 deb）
bash build-linglong.sh

# 3. 构建并安装到系统
bash build-linglong.sh --install

# 仅生成/修复 linglong.yaml（不构建，用于调试）
bash build-linglong.sh --skip-build
```

产物：`pica-work/package/trae-solo-cn/trae-solo-cn_<版本>_x86_64_main.uab`

脚本组成：
- `build-linglong.sh`       # 主流程：ll-pica 转换 → 修复 → ll-builder build/export
- `scripts/fix-linglong-yaml.py`  # 应用本项目已验证的适配修复

玲珑版特性：沙箱隔离、无需 `--no-sandbox` 手动参数（已内置）、自带全部依赖。

## 功能状态（真实测试 2026-08-26）

- ✅ **可用**: solo-lite UI、AI Agent、CKG、插件市场、Git 集成、API 连通
- ⚠️ **有异常**: 飞书 Token 刷新、计费状态、自动更新（无）
- ❌ **不可用**: 积分、企业模型、专家模式等（产品功能开关关闭）

详见 [README-功能说明.md](README-功能说明.md)。

## 相关资源

- [English README](README.en.md)
- 设计文档: [docs/superpowers/specs/](docs/superpowers/specs/)
- 实施计划: [docs/superpowers/plans/](docs/superpowers/plans/)

## 镜像仓库

- GitHub: https://github.com/testerxydw/traework-win-to-linux
- Gitee: https://gitee.com/xiyidaiwa/traework-win-to-linux
