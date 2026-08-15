# Codex Notify

面向 Linux 和 Windows 桌面的 Codex 回复完成通知工具。当 Codex 完成一轮回复后，它会
发送桌面通知，方便你在处理其他事情时及时回来查看结果。

## 安装

### 在线一键安装

Windows 10/11 使用系统自带的 Windows PowerShell 5.1，不需要 Python或第三方模块：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Huffer342-WSH/Codex-Notify/refs/heads/main/install.ps1 | iex"
```

Linux 需要 Python 3，以及 `curl` 或 `wget`：

```bash
curl -LsSf https://raw.githubusercontent.com/Huffer342-WSH/Codex-Notify/refs/heads/main/install.sh | sh
```

在线安装器会自动下载主程序，无需克隆仓库或手动指定下载地址：

- Windows：`https://raw.githubusercontent.com/Huffer342-WSH/Codex-Notify/refs/heads/main/codex-notify.ps1`
- Linux：`https://raw.githubusercontent.com/Huffer342-WSH/Codex-Notify/refs/heads/main/codex-notify.py`

安装完成后重新启动 Codex 客户端，使通知配置生效。

### 安装位置

Windows 默认安装到：

```text
%LOCALAPPDATA%\CodexNotify\codex-notify.ps1
```

安装器会备份 `%USERPROFILE%\.codex\config.toml`，更新顶层 `notify` 配置，并注册当前
用户级 `codex-notify://` 激活协议。如果现有通知命令使用 `--previous-notify` 包装其他
回调，安装器只替换内层通知命令，保留外层回调。

Linux 默认安装到：

```text
~/.local/bin/codex-notify
```

安装器会备份 `~/.codex/config.toml`，并且只管理顶层 `notify` 设置，不修改其他 Codex
配置。

### 从仓库安装

Windows：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Linux：

```bash
./install.sh
```

本地安装优先使用安装器旁边的 `codex-notify.ps1` 或 `codex-notify.py`；主程序不存在时，
安装器自动回退到官方 Raw URL。

### 安装选项

安装到其他目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir D:\Tools\CodexNotify
```

```bash
./install.sh --install-dir ~/bin
```

只安装文件而不修改 Codex 配置：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -NoConfig
```

```bash
./install.sh --no-config
```

卸载：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

```bash
./install.sh --uninstall
```

## 功能

- 标题显示会话名称和当前工作目录。
- 正文显示上一条问题和本轮回复摘要，过长内容会自动省略。
- 点击通知可返回原来的 VS Code、Codex 编辑器或终端窗口。
- 支持 VS Code、VSCodium、Cursor、Windsurf、Windows Terminal、GNOME Terminal、
  Ghostty、Konsole、Kitty、Alacritty 和 WezTerm 等常见应用。
- Windows 优先使用 WinRT Toast，通过 Windows Script Host 隐藏处理点击激活，不会
  闪现命令行窗口。
- Linux 使用 FreeDesktop Notifications，并根据桌面主题生成深色或浅色 SVG 图标。
- Windows 只依赖系统自带的 Windows PowerShell、.NET 和 Windows API；Linux 主程序和
  图标数据包含在单个 Python 文件中。

### Windows

Windows 版本请求 `duration="long"` 的 WinRT Toast；通知横幅消失后仍可在通知中心
（`Win+N`）查看。点击通知时，脚本通过安装器注册的 `codex-notify://` 协议恢复来源窗口。
协议不可用或 WinRT 发送失败时，脚本回退到 `System.Windows.Forms.NotifyIcon`。

Toast 正文左侧使用脚本内嵌并缓存到 `%LOCALAPPDATA%\CodexNotify` 的 Codex SVG 图标。
脚本读取 Windows 应用主题，深色主题使用浅色图标，浅色主题使用深色图标。Windows 11
顶部归属区域的应用图标由 PowerShell AppID 决定，不能通过 Toast XML 覆盖，因此顶部
仍可能同时显示 PowerShell 图标。

Windows 最终决定横幅停留时间。`NotifyIcon.ShowBalloonTip()` 的毫秒参数在现代 Windows
中不是持续时间保证。如需延长横幅，请在“设置 → 辅助功能 → 视觉效果 → 在此时间后关闭
通知”中调整。安装器只显示警告，不修改这项系统全局设置。

### Linux

Linux 需要实现 `org.freedesktop.Notifications` 的桌面通知服务。Ubuntu/Debian 推荐：

```bash
sudo apt install python3-gi libnotify-bin x11-utils
```

可选组件：

- `python3-gi`：持久 D-Bus 连接和点击动作。
- `notify-send`：PyGObject 缺失时的回退。
- `xprop` 和 `libX11`：X11 下定位并激活窗口。
- `xdotool` 或 `wmctrl`：额外的 X11 窗口激活回退。

当前重点验证环境为 Ubuntu 22.04、GNOME、X11、VS Code Codex 插件、GNOME Terminal
和 Ghostty。Wayland 通常限制后台进程激活其他应用，因此基础通知仍可使用，但精确返回
某个终端窗口取决于合成器和终端实现。

### 隐私

通知正文会显示部分用户问题和 Codex 回复。共享屏幕或锁屏通知可能暴露这些内容；可在
脚本中降低 `QUESTION_PREVIEW_LIMIT`、`ANSWER_PREVIEW_LIMIT`，或关闭系统锁屏通知
预览。

## 开发

### 手动测试

Windows：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CodexNotify\codex-notify.ps1" '{"type":"agent-turn-complete","thread-id":"test-thread","turn-id":"test-turn","cwd":"C:\\Projects\\example-project","input-messages":["测试 Windows 桌面通知"],"last-assistant-message":"通知脚本工作正常。"}'
```

Linux：

```bash
~/.local/bin/codex-notify '{
  "type": "agent-turn-complete",
  "thread-id": "test-thread",
  "turn-id": "test-turn",
  "cwd": "/tmp/example-project",
  "input-messages": ["测试 Linux 桌面通知"],
  "last-assistant-message": "通知脚本工作正常。"
}'
```

手动测试会发送一条真实桌面通知。

### Codex 通知接口

Codex 在回合完成时执行顶层 `notify` 配置的程序，并将事件作为单个 JSON 参数传入。脚本
只处理 `agent-turn-complete`：

| 字段 | 用途 |
| --- | --- |
| `thread-id` | 查询会话标题，并作为通知同步标识 |
| `cwd` | 显示工作目录，并辅助识别编辑器窗口 |
| `input-messages` | 从末尾向前选择最后一条非空问题 |
| `last-assistant-message` | 生成本轮回复摘要 |

Linux 配置示例：

```toml
notify = ["/home/用户名/.local/bin/codex-notify"]
```

Windows 配置示例：

```toml
notify = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\Users\\用户名\\AppData\\Local\\CodexNotify\\codex-notify.ps1"]
```

### Windows 实现

Windows 入口进程解析通知内容、识别来源窗口，然后直接发送 WinRT Toast。只有协议未
安装或 WinRT 发送失败时，才启动隐藏的 `-Serve` 子进程并使用 `NotifyIcon` 回退。

脚本通过 `Get-StartApps` 读取实际注册的 Windows PowerShell AppID。Toast 将来源窗口
信息编码进 `codex-notify://` URI，点击后由 `wscript.exe` 隐藏启动 PowerShell，解码并
激活窗口。会话标题通过 Windows 自带的 `winsqlite3.dll` 只读查询 VS Code 系编辑器的
`state.vscdb` 和 Codex 的 `state_*.sqlite`。

### Linux 实现

Linux 入口进程记录父进程链，再使用 `start_new_session=True` 启动独立的 `--serve`
子进程。主路径通过 PyGObject 的 `Gio` 调用 FreeDesktop Notifications D-Bus 接口；
PyGObject 不可用时回退到 `notify-send`。

点击通知后依次尝试 `WINDOWID`/`xdotool`、`libX11` EWMH 消息、`xprop` 窗口匹配、
编辑器 `--reuse-window`，最后使用 `wmctrl`。这些精确激活路径主要适用于 X11。

### 标题、正文与图标

会话标题优先读取通知载荷中的标题字段，然后查询 VS Code 系编辑器的 `state.vscdb` 和
Codex 的 `state_*.sqlite`，失败时使用“未命名会话”。Linux 标题格式为
`《会话名称》 @ 目录`，Windows 使用 `[会话名称] @ 目录`。

正文会压缩换行和连续空白，并根据脚本顶部的长度常量截断。Linux 的 SVG path 数据直接
内嵌在 Python 文件中，运行时根据 GTK、KDE、GNOME 和终端主题信息选择前景色，然后缓存
到 `/tmp/codex-notify-<uid>/`。

### 兼容性边界

通知外观、停留时间、动作支持和窗口激活能力最终由操作系统、桌面通知服务以及
X11/Wayland 决定。所有增强功能均采用可选依赖和逐级回退设计。
