# TraeWork CN Windows → Linux deb 重打包设计

## 概述

将 TraeWork CN（TRAE SOLO CN）Windows 安装包（Inno Setup 6.4.0.1）解包分析后，替换 Windows Electron 运行时为 Linux 版本，重新打包为 deb 安装包。

## 源包信息

- **应用名称**: TraeWork CN (TRAE SOLO CN)
- **版本**: 0.1.54 (VS Code 基础: 1.107.1)
- **开发商**: 北京银猫弹射科技有限公司 (ByteDance)
- **安装包类型**: Inno Setup 6.4.0.1
- **安装包大小**: ~412MB
- **构建 Commit**: 2c00292c18e2323abdb829d53fcd2d408a14796e
- **buildPlatform**: win32 → 需改为 linux

## 架构

```
VSCode 1.107.1 Linux x64 .tar.gz
         ↓ 提取 Electron 运行时
    ┌───────────────────────────────────┐
    │  Linux Electron 运行时             │  code 二进制, .pak, icudtl.dat 等
    │  + TraeWork 应用资源 (跨平台)       │  resources/app/{out,extensions,modules,node_modules}
    │  + 字节跳动专有 DLL (保留/备用)     │  aha_*.dll, metasecml.dll 等
    │  + Linux 替代工具                   │  ffmpeg/fetch 用系统替代
    └───────────────────────────────────┘
         ↓ dpkg-deb 打包
    trae-solo-cn_0.1.54_amd64.deb
```

## 文件分类处理

### 完全替换（来自 Linux Electron）

| 文件 | 说明 |
|------|------|
| `TRAE SOLO CN.exe` (214M) | Windows Electron 二进制 → Linux `code` 二进制 |
| `d3dcompiler_47.dll` | DirectX 编译器 |
| `dxcompiler.dll`, `dxil.dll` | DirectX 着色器编译 |
| `ffmpeg.dll` | 媒体编解码 |
| `libEGL.dll`, `libGLESv2.dll` | OpenGL ES |
| `vk_swiftshader.dll`, `vulkan-1.dll` | Vulkan |
| `concrt140.dll`, `msvcp140.dll`, `vcruntime140*.dll`, `vcomp140.dll` | MSVC 运行时 |
| `snapshot_blob.bin`, `v8_context_snapshot.bin`, `icudtl.dat` | V8/ICU 数据 |
| `chrome_100_percent.pak`, `chrome_200_percent.pak`, `resources.pak` | Chromium 资源包 |

### 跨平台保留（纯 JS/TS）

| 路径 | 大小 | 说明 |
|------|------|------|
| `resources/app/out/` | 50M | 编译后核心代码 |
| `resources/app/extensions/` | 87M | 内置扩展 |
| `resources/app/modules/` | 665M | 依赖模块 |
| `resources/app/node_modules/` | 263M | Node 模块 |
| `resources/app/product.json` | - | 产品配置（修改 buildPlatform） |
| `resources/app/package.json` | - | 包配置 |
| `locales/` | - | 语言包 |

### 保留但功能受限（Windows 专有 DLL）

| DLL | 功能 | 处理方式 |
|-----|------|----------|
| `aha_net.dll` | TTNet 网络层 | 保留在 win-dlls/，静默降级 |
| `sscronet.dll` | Cronet 网络 | 保留在 win-dlls/，静默降级 |
| `metasecml.dll` | 安全模块 | 保留在 win-dlls/，静默降级 |
| `aha_kit_wer.dll` | 错误上报 | 保留在 win-dlls/，静默降级 |
| `doctor_sdk.dll` | 诊断 SDK | 保留在 win-dlls/，静默降级 |
| `simplelog.dll` | 日志 | 保留在 win-dlls/，静默降级 |
| `logifier_retrieval.dll` | 日志检索 | 保留在 win-dlls/，静默降级 |
| `innoplugin.dll` | 插件系统 | 保留在 win-dlls/，静默降级 |
| `TTNetDownloaderCrossPlatform.dll` | 下载器 | 保留在 win-dlls/，静默降级 |

### 替换为 Linux 等效工具

| Windows 文件 | Linux 替代 | 方式 |
|-------------|-----------|------|
| `resources/app/bin/fetch.exe` | `curl` | shell 包装脚本 |
| `resources/app/bin/ffmpeg.exe` | 系统 `ffmpeg` | 符号链接或 shell 脚本 |
| `resources/app/bin/ffprobe.exe` | 系统 `ffprobe` | 符号链接或 shell 脚本 |
| `resources/app/bin/libwinpthread-1.dll` | 不需要 | 移除 |

### 完全移除

| 文件 | 说明 |
|------|------|
| `app/tools/inno_updater.exe` | Windows 更新器，由 apt 替代 |
| `app/tools/set-env.ps1` | Windows 环境变量脚本 |
| `app/tools/remove-env.ps1` | Windows 环境变量脚本 |
| `app/tools/vcruntime140.dll` | MSVC 运行时 |
| `aha_doctor/` 目录 | Windows 诊断工具（创建占位脚本） |

## deb 包结构

```
/opt/trae-solo-cn/
├── trae-solo-cn              # 启动脚本 (shell)
├── code                      # Linux Electron 二进制（从 VSCode 提取）
├── *.pak                     # Linux Chromium 资源包
├── icudtl.dat                # ICU 数据
├── snapshot_blob.bin         # V8 快照
├── v8_context_snapshot.bin   # V8 上下文快照
├── locales/                  # 语言包
├── resources/
│   └── app/
│       ├── out/              # 核心编译代码
│       ├── extensions/       # 内置扩展
│       ├── modules/          # 依赖模块
│       ├── node_modules/     # Node 模块
│       ├── product.json      # buildPlatform 改为 "linux"
│       ├── package.json
│       ├── bin/              # Linux 工具包装脚本
│       │   ├── fetch         # → curl 包装
│       │   ├── ffmpeg        # → 系统 ffmpeg 包装
│       │   └── ffprobe       # → 系统 ffprobe 包装
│       └── licenses/
├── win-dlls/                 # 保留的 Windows DLL（备用）
│   ├── aha_kit_wer.dll
│   ├── aha_net.dll
│   ├── doctor_sdk.dll
│   ├── innoplugin.dll
│   ├── logifier_retrieval.dll
│   ├── metasecml.dll
│   ├── simplelog.dll
│   ├── sscronet.dll
│   └── TTNetDownloaderCrossPlatform.dll
└── aha_doctor/               # 占位脚本
    └── aha_doctor            # shell 脚本，提示 Linux 不可用

/usr/share/applications/
└── trae-solo-cn.desktop      # 桌面快捷方式

/usr/share/icons/hicolor/512x512/apps/
└── trae-solo-cn.png          # 应用图标

/usr/bin/
└── trae-solo-cn → /opt/trae-solo-cn/trae-solo-cn  # PATH 符号链接
```

## deb 控制文件

```
Package: trae-solo-cn
Version: 0.1.54
Section: editors
Priority: optional
Architecture: amd64
Maintainer: TraeWork CN Linux Packager
Description: TRAE SOLO CN - AI-powered code editor (Linux port)
 TraeWork CN is an AI-powered code editor based on VS Code.
 This is a Linux port repackaged from the Windows installer.
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0, libsecret-1-0
Recommends: ffmpeg
```

## 关键修改

1. `product.json`: `buildPlatform` 从 `"win32"` 改为 `"linux"`
2. 启动脚本: 适配 Linux 路径和 Electron 二进制名称
3. `.desktop` 文件: 创建标准 freedesktop 桌面入口
4. 工具包装脚本: 桥接 Windows 工具到 Linux 原生工具

## 资源来源

- **VSCode Linux 下载 URL**: `https://update.code.visualstudio.com/1.107.1/linux-x64/stable`（重定向到 Microsoft CDN tar.gz）
- **应用图标**: 从 `TRAE SOLO CN.exe` 的 PE 资源中提取（RT_GROUP_ICON, 256x256 PNG），已提取为 `trae-icon-256.png`
- **innoextract**: 从源码编译（apt 版本 1.9 不支持 Inno Setup 6.4.0.1），源码: github.com/dscharrer/innoextract

## 已知限制

1. **字节跳动专有 DLL**: 遥测、网络（TTNet）、安全、诊断等 DLL 在 Linux 上无法加载，相关功能静默降级
2. **aha_doctor**: Windows 诊断工具不可用，提供占位脚本
3. **自动更新**: Inno Setup 更新器不可用，通过 apt upgrade 更新
4. **网络层**: 如果核心 API 通信依赖 TTNet（aha_net.dll/sscronet.dll），部分在线功能可能受影响

## 构建流程

1. 用 innoextract 提取 Windows 安装包
2. 下载 VSCode 1.107.1 Linux x64 .tar.gz
3. 从 VSCode 提取 Linux Electron 运行时文件
4. 组装 deb 包目录结构
5. 修改 product.json
6. 创建启动脚本、包装脚本、.desktop 文件
7. 提取应用图标
8. 用 dpkg-deb 构建 .deb 包
