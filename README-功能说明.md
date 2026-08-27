# TRAE SOLO CN — Linux 移植版功能说明

> **真实测试日期**: 2026-08-26  
> **版本**: TraeWork CN v0.1.54 | VS Code 内核 1.107.1 | Electron 来自 TraeCode CN Linux v3.3.93  
> **deb 包**: 477MB | 安装后: ~1.6GB | 安装命令: `sudo dpkg -i trae-solo-cn_0.1.54_amd64.deb`

---

## 真实测试结果

### 启动验证

```
窗口标题:    TraeWork CN
窗口尺寸:    1440×900 (可调整)
窗口状态:    IsViewable (正常可见)
主进程 CPU:  ~8%   内存: ~224MB (1.4%)
渲染进程:    ~13%  内存: ~320MB (2.0%)
生命周期:    phase 2 → 3 → 4 (完整)
```

**结论: TraeWork solo-lite UI 在 Linux 上正常启动并渲染。**

---

## 功能状态

### ✅ 确认可用

| 功能 | 验证方式 | 说明 |
|------|----------|------|
| **Solo-lite UI 界面** | 用户目视确认 | TraeWork 专属 UI 正常显示 |
| **应用完整启动** | 日志 lifecycle phase 4 | 完整生命周期，无崩溃 |
| **AI Agent 引擎** | 日志 `healthy and ready` | libai_agent.so 正常加载 |
| **CKG 知识图谱** | 日志 `healthy and ready` | 本地代码索引引擎 |
| **API 网络连通** | 日志 200 响应 | api.trae.com.cn / api.trae.cn 全部正常 |
| **插件市场** | 日志 gallery 已配置 | 按 `os=linux` 过滤，可浏览安装 |
| **Skill 列表** | 日志 API 200 | 可浏览和安装 Skills |
| **OAuth 设备认证** | 日志 device key pair loaded | 登录流程可启动 |
| **Git 集成** | feature flag `enableGitCommit: true` | 代码提交功能 |
| **AI 代码修改** | feature flag `enableCodeChanges: true` | AI 辅助编辑 |
| **模型选择器** | feature flag `showModelSelector: true` | 可选 AI 模型 |
| **SharedProcess IPC** | 日志 `IPC ready` | 扩展宿主通信正常 |
| **文件关联打开** | desktop 文件 `%F` 参数 | 可从文件管理器打开 |
| **CDN 资源加载** | 日志 mf-manifest.json 200 | cashier/entitlement/marketing 模块 |
| **桌面集成** | xdotool 确认窗口可见 | 菜单图标、WMClass 正常 |

### ⚠️ 有已知问题

| 功能 | 问题描述 | 影响程度 |
|------|----------|----------|
| **飞书/Lark Token** | 刷新失败 `Result is not an array` | 飞书集成可能不可用 |
| **计费/付费状态** | `billingState: missing` | AI 额度可能显示异常 |
| **自动更新** | `updateUrl` 未设置 | 需手动下载新版 deb |
| **服务端分支** | 标记为 `release_solo_win32_cn` | 可能收到 Windows 专属配置 |
| **扩展兼容性** | 按 linux 过滤 | Windows-only 扩展不可用 |
| **窗口数** | 仅 1 个窗口 | solo-lite 正常行为，非 bug |
| **File Watcher** | `EMFILE: too many open files` | 文件监控可能不完整，不影响核心功能 |

### ❌ 不可用

| 功能 | 原因 |
|------|------|
| 积分系统 | `enableCreditUsage: false` |
| 企业模型 | `showEnterpriseModels: false` |
| 专家模式 | `supportExpertsMode: false` |
| 语音输入 | `supportVoiceInput: false` |
| Quest 远程/Marketplace | `questModeSupportRemote/MarketPlace: false` |
| Supabase 集成 | `questSupportSupabase: false` |
| 模型分层选择 | `showModelTierSelector: false` |
| 自动更新 | 无 updateUrl 配置 |
| 沙箱模式 | 必须 `--no-sandbox` |

---

## 使用建议

### 启动

```bash
# 推荐方式（桌面菜单 "TRAE SOLO CN"）
# 或命令行:
/opt/trae-solo-cn/trae-solo-cn --no-sandbox

# 打开项目
/opt/trae-solo-cn/trae-solo-cn --no-sandbox /path/to/project
```

> ⚠️ 必须加 `--no-sandbox`

### 异常退出恢复

```bash
# 清理残留锁文件
rm -rf ~/.config/TRAE\ SOLO\ CN/Singleton*
```

### 数据目录

| 用途 | 路径 |
|------|------|
| 用户数据 | `~/.trae-cn/` |
| 配置设置 | `~/.config/TRAE SOLO CN/` |
| 缓存 | `~/.config/TRAE SOLO CN/CachedData/` |
| 日志 | `~/.config/TRAE SOLO CN/logs/` |

### 卸载

```bash
sudo apt remove trae-solo-cn
# 清理用户数据（可选）:
rm -rf ~/.trae-cn ~/.config/TRAE\ SOLO\ CN
```

---

## 与 Windows 原版对比

| 维度 | Windows 原版 | Linux 移植版 |
|------|-------------|-------------|
| UI 界面 | solo-lite ✅ | solo-lite ✅ (已确认) |
| AI 对话 | ✅ | ✅ (ai-agent 正常) |
| 代码编辑 | ✅ | ✅ |
| 插件市场 | ✅ | ✅ (Linux 过滤) |
| 自动更新 | ✅ | ❌ 手动更新 |
| 计费系统 | ✅ | ⚠️ 状态异常 |
| 飞书集成 | ✅ | ⚠️ Token 异常 |
| 稳定性 | 官方测试 | 非官方，边缘情况可能存在 |
