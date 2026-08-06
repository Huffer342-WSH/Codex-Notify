# Codex Notify

面向 Linux 桌面的 Codex 回合完成通知脚本。它通过 FreeDesktop Notifications
D-Bus 发送通知，显示会话名称、工作目录、上一问和回复摘要，并在桌面支持时提供
点击通知返回原编辑器或终端窗口的能力。

脚本为单文件实现，Codex SVG 图标已内嵌，无需额外复制图片资源。

## 通知格式

标题：

```text
《会话名称》 @ 工作目录最后一级
```

正文：

```text
上一问 —— 回复摘要
```

- 只显示本轮最后一条用户问题，不拼接历史问题。
- 问题和回复各保留最多 300 个字符，超出后以 `…` 省略。
- 通知请求显示 30 秒，点击动作监听 120 秒；桌面通知服务可能调整实际时长。

## 功能

- 读取 Codex 通知载荷中的工作目录、问题和回复。
- 从 Codex 本地状态库读取会话标题。
- 在 VS Code、VSCodium、Cursor 和 Windsurf 中优先读取编辑器显示的会话名称。
- VS Code 场景保留 `desktop-entry=code` 通知归属。
- 点击通知后聚焦原有编辑器窗口，不打开或替换工作区目录。
- 在 X11 下根据窗口 ID 或父进程定位并聚焦原终端窗口。
- 识别 GNOME Terminal、Ghostty、Konsole、Kitty、Alacritty、WezTerm、
  XFCE Terminal、MATE Terminal、Tilix、Terminator、Foot、XTerm 等常见终端。
- 自动检测 GNOME、KDE 和 GTK 深浅主题，并生成相应颜色的内嵌 SVG 图标。
- PyGObject 不可用时回退到 `notify-send`。

## 环境要求

基础要求：

- Linux
- Python 3
- 实现 `org.freedesktop.Notifications` 的桌面通知服务

Ubuntu/Debian 推荐安装：

```bash
sudo apt install python3-gi libnotify-bin x11-utils
```

可选工具：

- `python3-gi`：支持持久 D-Bus 连接和点击动作。
- `notify-send`：PyGObject 缺失时的通知回退。
- `xprop` 和 `libX11`：X11 下按进程定位、激活窗口。
- `xdotool` 或 `wmctrl`：额外的 X11 窗口激活回退。

## 安装

将脚本复制到固定位置并添加执行权限：

```bash
mkdir -p ~/.local/bin
cp codex-notify.py ~/.local/bin/codex-notify
chmod 755 ~/.local/bin/codex-notify
```

编辑 `~/.codex/config.toml`：

```toml
notify = ["/home/你的用户名/.local/bin/codex-notify"]
```

重新启动 Codex 客户端，使配置生效。

## 手动测试

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

手动测试会额外发送一条通知。Codex 正常回合结束时会自动调用脚本，不需要手动执行。

## 桌面兼容性

通知发送使用 FreeDesktop 标准，通常可用于 GNOME、KDE Plasma、XFCE、Cinnamon、
MATE、LXQt 等桌面。不同通知服务可能忽略请求的显示时间、动作按钮或部分提示字段。

当前重点验证路径：

- Ubuntu 22.04 + GNOME + X11
- VS Code Codex 插件
- GNOME Terminal
- Ghostty

X11 允许应用通过标准窗口管理协议激活已有窗口。Wayland 出于安全考虑通常不允许任意
应用精确激活其他窗口，因此编辑器可使用自身 CLI 作为回退，普通终端的点击跳转能力则
取决于桌面环境和终端实现。

## 隐私

通知正文会显示部分用户问题和 Codex 回复。共享屏幕或锁屏通知可能暴露这些内容；如有
隐私要求，可在脚本中降低 `QUESTION_PREVIEW_LIMIT`、`ANSWER_PREVIEW_LIMIT`，或关闭
系统锁屏通知预览。
