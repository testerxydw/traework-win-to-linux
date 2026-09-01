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
├── build.sh              # 唯一构建入口：拆包 → deb → 玲珑 → 安装
├── scripts/
│   └── fix-linglong-yaml.py   # 玲珑 linglong.yaml 适配修复助手（由 build.sh 调用）
├── deb-pkg/              # 打包目录
│   ├── DEBIAN/           # control/postinst/prerm/postrm（入库）
│   ├── opt/.../trae-solo-cn   # 启动脚本（入库）
│   └── opt/.../其余内容        # 由 build.sh 拆包阶段生成（不入库）
├── pica-work/            # 玲珑构建工作目录（build.sh 自动生成，不入库）
├── docs/                 # 设计文档与实施计划
└── README-功能说明.md     # 功能可用/不可用清单
```

## 一键构建（deb + 玲珑）

前置：下载 `TraeWork_CN-Setup-x64.exe`（放项目目录会被自动发现），并安装（或下载）`TraeCode_CN-linux-x64.deb`。

> ℹ️ 0.1.58 起的安装包为 Inno Setup 6.4 格式，需要 innoextract ≥ 1.10（发行版自带的 1.9 无法解析）。
> build.sh 会优先使用本目录 `.innoextract-src/build/innoextract`（自编译版）：
> ```bash
> git clone --depth 1 https://github.com/dscharrer/innoextract.git .innoextract-src
> cmake -S .innoextract-src -B .innoextract-src/build && cmake --build .innoextract-src/build -j$(nproc)
> ```
> 0.1.54 及更早的 NSIS 格式安装包则仍用 7z 解压。

```bash
# 完整流水线：拆包 → 构建 deb → 转制玲珑 → 安装两个版本
bash build.sh

# 常用变体
bash build.sh /path/TraeWork_CN-Setup-x64.exe   # 指定安装包
bash build.sh --extracted <解压目录>            # 复用已解压的 code$GetDestDir
bash build.sh --skip-extract                    # 跳过拆包，用现有 deb-pkg 直接构建
bash build.sh --deb-only                        # 只到 deb（不转玲珑）
bash build.sh --ll-only                         # 只用最新 deb 转玲珑
bash build.sh --no-install                      # 全部构建但都不安装
bash build.sh --install-deps                    # 一键装齐依赖（apt 包 + 自编译 innoextract）
```

新机器首次使用：先 `bash build.sh --install-deps` 自动安装 7zip、linglong 工具链、
python3-yaml 等 apt 包，并 clone + 编译 innoextract ≥ 1.10（发行版仓库只有 1.9，
不支持 Inno Setup 6.4，无法用 apt 解决）；之后直接 `bash build.sh` 即可。

启动：桌面菜单 `TRAE SOLO CN`（deb）/ `TRAE SOLO CN (玲珑版)`，或 `/opt/trae-solo-cn/trae-solo-cn`。


## 玲珑包说明（如意玲珑 / uab）

`build.sh` 的玲珑阶段自动完成：ll-pica 转换 → 适配修复（应用主体复制、
--no-sandbox、桌面入口 PATH 包装脚本等）→ ll-builder build/export。

产物：`pica-work/package/trae-solo-cn/trae-solo-cn_<版本>_x86_64_main.uab`

**版本同步规则**：玲珑版本号 = deb 主版本 + 修订号转点分
（`0.1.58-5` → `0.1.58.5`），确保每次 deb 更新，玲珑包也随之更新且可区分。

玲珑版特性：沙箱隔离、无需 `--no-sandbox` 手动参数（已内置）、自带全部依赖。


## 与 deb 版共存

玲珑版与 deb 版可同时安装、互不干扰，方便 A/B 测试：

| 项目 | deb 版 | 玲珑版 |
|------|--------|--------|
| 桌面入口 | `TRAE SOLO CN` | `TRAE SOLO CN (玲珑版)` |
| desktop 文件 | `trae-solo-cn.desktop` | `trae-solo-cn-linglong.desktop` |
| 应用文件 | `/opt/trae-solo-cn` | 沙箱 `/opt/apps/trae-solo-cn/files` |
| 启动命令 | `/opt/trae-solo-cn/trae-solo-cn` | `ll-cli run trae-solo-cn` |

- **窗口类隔离**：玲珑版启动时注入 `--class=trae-solo-cn-linglong`，任务栏图标各自归组，不与 deb 版混用。
- **用户数据共用** `~/.config/TRAE SOLO CN`（登录、配置、扩展一致）。
- **不要同时运行**两个版本：共用用户数据触发 Electron 单实例锁，后启动者会退出。
- 如需同时对比，可给其中一个指定独立数据目录：
  `ll-cli run trae-solo-cn -- /opt/apps/trae-solo-cn/files/bin/trae-solo-cn --user-data-dir ~/.config/TRAE-SOLO-linglong-test`


## 功能状态（真实测试 2026-08-26）

- ✅ **可用**: solo-lite UI、AI Agent、CKG、插件市场、Git 集成、API 连通
- ⚠️ **有异常**: 飞书 Token 刷新、计费状态、自动更新（无）
- ❌ **不可用**: 积分、企业模型、专家模式等（产品功能开关关闭）

详见 [README-功能说明.md](README-功能说明.md)。

## 相关资源

- [English README](README.en.md)
- 设计文档: [docs/superpowers/specs/](docs/superpowers/specs/)
- 实施计划: [docs/superpowers/plans/](docs/superpowers/plans/)
- 拆包重打包技能手册（CodeBuddy 技能，含 symlink / main.js / 标题栏陷阱）: [docs/skills/traework-deb-repack/SKILL.md](docs/skills/traework-deb-repack/SKILL.md)

## 镜像仓库

- GitHub: https://github.com/testerxydw/traework-win-to-linux
- Gitee: https://gitee.com/xiyidaiwa/traework-win-to-linux

## 下载

- **WorkBuddy 5.3.14-4**（Linux 移植版，Electron 39.2.7；修复退出后进程残留、托盘右键菜单、桌面图标为纯 WorkBuddy logo）：
  GitHub Release → https://github.com/testerxydw/traework-win-to-linux/releases/tag/workbuddy-5.3.14-4
- 历史版本见各 `workbuddy-*` tag 的 Release 附件
