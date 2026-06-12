# Codex Computer Use Restore Skill

一个用于修复 Windows 版 Codex 中 **Computer Use / @Computer / 电脑操控** 插件注册和缓存异常的 Codex Skill。

这个 skill 主要解决这类现象：

- Codex 设置页显示 `Computer Use 插件不可用`
- `@Computer` / `@电脑` 入口缺失或提示未注册
- 切换官方/第三方 Provider、更新 Codex、重启后，Computer Use 状态异常
- 设置页反复弹出 `插件安装失败`
- `codex plugin list` 显示 `computer-use@openai-bundled not installed`
- WindowsApps 里的 bundled 插件更新了，但 `.codex` 插件缓存仍指向旧版本
- Computer Use 已注册，但运行时报 `Package subpath ... computer_use_client_base.js is not defined by "exports"`

## 安装

把本仓库作为 skill 放到 Codex skill 目录：

```powershell
git clone https://github.com/TyrEamon/Codex-computer-use-restore-skill.git "$env:USERPROFILE\.codex\skills\restore-computer-use"
```

如果目录已经存在，可以先备份或删除旧目录：

```powershell
Rename-Item "$env:USERPROFILE\.codex\skills\restore-computer-use" "restore-computer-use.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
git clone https://github.com/TyrEamon/Codex-computer-use-restore-skill.git "$env:USERPROFILE\.codex\skills\restore-computer-use"
```

## 使用

在 Codex 里直接说：

```text
用 restore-computer-use 修复 Computer Use
```

也可以手动运行脚本。

轻量修复入口注册：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\restore-computer-use\scripts\restore-computer-use.ps1" -OpenSettings
```

深度修复插件安装缓存、Chrome native host、`@oai/sky` runtime export：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\restore-computer-use\scripts\repair-bundled-plugin-installs.ps1"
```

如果你想先看计划、不修改任何配置：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\restore-computer-use\scripts\repair-bundled-plugin-installs.ps1" -DryRun
```

如果自动找不到 Codex bundled 插件源，可以手动指定 `openai-bundled` 目录：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\restore-computer-use\scripts\repair-bundled-plugin-installs.ps1" `
  -Source "C:\Program Files\WindowsApps\OpenAI.Codex_<version>_x64__2p2nqsd0c76g0\app\resources\plugins\openai-bundled"
```

## 它会修什么

- 刷新 `$env:USERPROFILE\.codex\config.toml` 里的 `[marketplaces.openai-bundled]`
- 启用 `[plugins."computer-use@openai-bundled"]`
- 启用 `[plugins."chrome@openai-bundled"]`
- 修复 `computer-use/latest`、`chrome/latest` 插件缓存
- 避免用 junction 伪装 `computer-use/latest`，因为某些 Codex 版本不会把 junction 当作已安装插件
- 处理 WindowsApps AppX `Application Protected` / 加密文件复制失败问题
- 重装 Chrome native messaging host manifest
- 修复 `@oai/sky` 的 `package.json exports` 漏项导致的 Computer Use runtime 报错
- 支持 `-DryRun` 只读诊断
- 支持 `-Source` 手动指定 bundled 插件源
- 修复前备份 `config.toml` 和 `codex-global-state.json`

## 和其他修复方案的关系

这个 skill 吸收了社区里“把 WindowsApps 里的 bundled 插件源复制到用户目录，再注册/安装”的经验，但没有完全照搬。

保留并增强的点：

- 使用 byte-copy 读取受保护 AppX 文件，避免普通复制遇到 `os error 6000` 或加密属性失败
- 支持手动 `-Source` 指定 `app\resources\plugins\openai-bundled`
- 支持 `-DryRun` 先诊断
- 备份用户 Codex 配置和全局状态

额外覆盖的坑：

- `computer-use/latest` 是 junction 时 Codex 可能仍判定为未安装，所以这里会构建真实目录副本
- Chrome 插件需要真实可写副本，因为 native host 安装脚本会写入插件目录
- 更新后 Chrome native host 可能还指向旧 runtime，这里会重新安装 HKCU native messaging manifest
- Computer Use 注册成功但运行时报 `Package subpath ... computer_use_client_base.js is not defined by "exports"` 时，这里会修复本地 `@oai/sky` runtime metadata

## 为什么不直接改 WindowsApps 权限？

不要改。

`C:\Program Files\WindowsApps` 是 Windows 受保护的应用包目录。Codex 的 Microsoft Store / AppX 安装内容也在这里，文件可能带有 AppX 保护、加密属性或应用包完整性约束。强行接管权限、改 ACL、删除加密属性，短期看也许能复制文件，但容易引入额外问题：

- 破坏应用包完整性，导致 Codex 更新、修复或卸载异常
- 让 WindowsApps 权限状态变脏，后续 Store/App Installer 更新更难判断
- 把一次插件缓存问题扩大成系统目录权限问题
- 后续 Codex 更新仍可能覆盖或重新生成包目录，手改结果不可持续

这个 skill 采用更稳妥的方式：只把 Codex bundled 插件源作为只读源，复制一份到用户目录 `.codex` 下，再让 Codex 使用这份用户可写的镜像。这样既避开 WindowsApps 的保护机制，也不会污染系统应用包目录。

## 验证

运行：

```powershell
codex plugin list
```

正常时应看到：

```text
computer-use@openai-bundled  installed, enabled  latest
chrome@openai-bundled        installed, enabled  latest
```

如果 `codex.exe` 因 WindowsApps 受保护路径报 `Access is denied`，可以使用本地 runtime 里的 `codex.exe`：

```powershell
$codex = Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\bin" -Recurse -File -Filter codex.exe |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
& $codex.FullName plugin list
```

## 注意

- 这个 skill 不会修改 `C:\Program Files\WindowsApps` 里的 Codex 安装文件，只读取 bundled 插件作为源。
- 脚本会在修改 `config.toml` 前创建时间戳备份。
- 如果 Chrome 仍显示未连接，可能是 Chrome Web Store 扩展本身没有安装/启用，不是 Codex 插件缓存问题。
- 如果 Codex 更新后再次异常，重新运行深度修复脚本即可。

## 文件结构

```text
.
├── SKILL.md
├── README.md
├── agents/
│   └── openai.yaml
└── scripts/
    ├── restore-computer-use.ps1
    └── repair-bundled-plugin-installs.ps1
```
