# CS2 无禁言 Demo 启动器

这个启动器接受本地 `.dem` 或只包含一个 `.dem` 的 `.zip`，生成一个独立的、尽力解除已记录静音/监听限制的实验性副本，并通过 Steam 启动 CS2 播放。

它不仅设置 `tv_listen_voice_indices`，还先改写 demo 内记录的通信静音标志、VoiceMask、每个语音包的 `audible_mask`，并一致地替换玩家身份，避免 CS2 根据原 Steam ID 再次应用全局或本地静音。

## 最简单的用法

以下两种方式任选其一：

1. 将 `.dem` 或 `.zip` 拖到 `Watch-CS2DemoUnmuted.cmd` 上。
2. 双击 `Watch-CS2DemoUnmuted.cmd`，然后粘贴文件路径。

第一次运行会从 GitHub 下载固定版本 `OdyCSUnmuter v0.1.0-beta.1`。脚本会同时校验发布 ZIP 和其中 EXE 的固定 SHA-256；校验不一致时不会执行。

如果 CS2 尚未运行，脚本会通过 Steam 自动启动，并执行生成的播放配置。如果 CS2 已经打开，Steam 无法可靠地向现有进程转发启动参数，脚本会把下面这条命令复制到剪贴板：

```text
exec cs2_demo_unmuted_<哈希>.cfg
```

脚本会把当前 demo 对应的完整命令复制好，将它粘贴到 CS2 控制台即可。

每次执行播放配置时，脚本会在播放 demo 前设置 `cl_demo_predict 0`，默认关闭“启用实况回放”（TrueView）。如有需要，可以在回放界面手动重新勾选。

但首次测试处理后的副本时，建议完整退出 CS2，再运行启动器。若明确接受脚本结束当前 CS2 进程，可使用下面的 `-RestartIfRunning`；普通双击/拖放模式绝不会强制关闭游戏。

## PowerShell 用法

```powershell
pwsh -NoProfile -File .\Watch-CS2DemoUnmuted.ps1 -DemoPath 'C:\path\match.dem'
```

只处理和验证、不启动 CS2：

```powershell
pwsh -NoProfile -File .\Watch-CS2DemoUnmuted.ps1 -DemoPath 'C:\path\match.zip' -NoLaunch
```

忽略已有缓存并重新处理：

```powershell
pwsh -NoProfile -File .\Watch-CS2DemoUnmuted.ps1 -DemoPath 'C:\path\match.dem' -ForceReprocess
```

若 CS2 已运行，请求游戏正常退出并重启后播放（请先保存或结束当前对局/回放）：

```powershell
pwsh -NoProfile -File .\Watch-CS2DemoUnmuted.ps1 -DemoPath 'C:\path\match.dem' -RestartIfRunning
```

## 文件位置

- 原始 `.dem`/`.zip`：永不覆盖。
- 处理后的 demo：`<CS2>\game\csgo\demos\CS2DemoUnmutedLauncher\`。
- 播放配置：`<CS2>\game\csgo\cfg\cs2_demo_unmuted_<哈希>.cfg`。
- 工具缓存、语音报告和完整性清单：`%LOCALAPPDATA%\CS2DemoUnmutedLauncher\`。

## 清理启动器生成的本地 Demo

双击 `Clear-CS2LocalDemos.cmd` 即可。脚本会先列出目标、文件数和占用空间，再要求输入 `DELETE`；默认把文件送入 Windows 回收站。

默认清理范围严格限定为：

- `<CS2>\game\csgo\demos\CS2DemoUnmutedLauncher\` 中符合启动器精确命名规则的处理结果；
- `<CS2>\game\csgo\cfg\cs2_demo_unmuted_*.cfg`。

它不会清理 `csgo\replays`、`csgo` 根目录中的原始 `.dem`，也不会触碰 Wmpvp 的 ZIP。补丁工具缓存和语音报告默认同样保留，避免下次重新下载工具。脚本会动态定位 Steam 和 CS2；如果待删文件、它的父目录或显式清理的缓存树包含重解析点（链接或联接），或者 CS2/本启动器仍在运行，实际清理会被拒绝。

只列出目标，不作任何修改：

```powershell
pwsh -NoProfile -File .\Clear-CS2LocalDemos.ps1 -ListOnly
```

用 PowerShell 的预演模式查看每个将执行的操作：

```powershell
pwsh -NoProfile -File .\Clear-CS2LocalDemos.ps1 -WhatIf
```

跳过第一层 `DELETE` 确认、送入回收站：

```powershell
pwsh -NoProfile -File .\Clear-CS2LocalDemos.ps1 -Yes
```

如果还要一并清除 `%LOCALAPPDATA%\CS2DemoUnmutedLauncher\` 中的补丁工具缓存、语音报告和完整性清单，显式添加 `-IncludeCache`：

```powershell
pwsh -NoProfile -File .\Clear-CS2LocalDemos.ps1 -IncludeCache
```

只有显式添加 `-Permanent` 才会绕过回收站。永久删除始终还要手动输入第二重确认 `PERMANENT DELETE`；即使同时使用 `-Yes`，这层确认也不会跳过：

```powershell
pwsh -NoProfile -File .\Clear-CS2LocalDemos.ps1 -Permanent
```

## 限制与安全说明

- demo 必须原本就包含语音包；脚本不能恢复服务器从未录制的声音。
- `Ready` 只表示 demo 中存在某些语音；脚本不知道你关注的是哪一名玩家。请在语音报告中确认目标姓名对应的 `Audio bytes` 大于 0。
- 处理会放开所有已录制语音的监听限制，并非只解除某一名玩家。
- 为防止异常 ZIP 填满磁盘并遵守 PBDEMS2 的 32 位尾部偏移，单个解压后 demo 上限约为 4 GB；首次处理还需要约三份 demo 大小的可用空间。
- 启动器会扫描并回填 `DemFileInfo` 与 `DemSpawnGroups` 的真实尾部偏移；这是避免改写后卡在“扫描转移中”的必要兼容修复。
- 输出副本中的 Steam ID 会改成合成 ID，因此头像和资料链接可能不再对应；玩家名称和已录制语音保留。
- 语音报告会记录玩家名称、原 Steam ID、合成 ID 与音频字节数；它和处理后的 demo 都应按敏感文件对待。
- 输出可能暴露原监听限制之外的队内语音，请勿在未经参与者许可时公开传播。
- 这只是有限字段的身份重映射，不是匿名化；姓名、声音以及未覆盖字段仍可能识别玩家。
- 当前 Beta 覆盖主要静音字段；含 `CSVCMsg_PeerList` 的其他来源 demo 仍可能存在兼容风险，需要按具体回放验证。
- 使用固定的实验性第三方 Beta；它是开源软件，但 Windows 发布版未签名。脚本固定校验：
  - 发布 ZIP：`AC2BA60F93B1B498A71CBD7A6EFB9C25D6B89D2D6BF761CF1351DF1E15537A66`
  - EXE：`5EB05E1F597B5509FB2A9A886D1014512D15419E48426932CF903114AB6DB475`
- 脚本不安装插件、不注入 DLL、不修改账号处罚，也不需要 `-insecure`。
- 播放配置会执行 `voice_modenable 1`；这是 CS2 的持久设置。如果你原先主动关闭了所有语音，观看后可在控制台运行 `voice_modenable 0` 恢复。

第三方项目与源码：<https://github.com/OdyCS/OdyCSUnmuter>
