# Codex Notify

面向 Linux 桌面的 Codex 回复完成通知脚本。当 Codex 完成一轮回复后，它会发送桌面
通知，方便你在处理其他事情时及时回来查看结果。

## 功能

- 标题显示会话名称和当前工作目录。
- 正文显示上一条问题和本轮回复摘要，过长内容会自动省略。
- 点击通知可返回原来的 VS Code、Codex 编辑器或终端窗口（取决于桌面支持）。
- 支持 GNOME Terminal、Ghostty、Konsole、Kitty、Alacritty、WezTerm 等常见终端。
- 通知图标会适配系统的深色或浅色主题。
- 脚本和图标均包含在一个 Python 文件中，便于安装和迁移。

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

### 一条命令安装

仓库发布到 GitHub、GitLab 或其他可提供 Raw 文件的服务后，可直接运行：

```bash
BASE_URL="https://raw.githubusercontent.com/你的用户名/codex-notify/main"; curl -fsSL "$BASE_URL/install.sh" | sh -s -- --source-url "$BASE_URL/codex-notify.py"
```

这条命令会下载脚本到 `~/.local/bin/codex-notify`，检查 Python 语法，备份现有
Codex 配置，然后自动写入 `~/.codex/config.toml`。用户不需要克隆仓库。

> 将示例中的 Raw URL 换成此仓库发布后的真实地址。当前本地仓库尚未配置远程地址，
> 因此不能提前给出可直接访问的公网 URL。

### 从仓库安装

克隆仓库后运行：

```bash
./install.sh
```

也可以继续手动安装：

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

安装到其他目录：

```bash
./install.sh --install-dir ~/bin
```

只安装文件而不修改 Codex 配置：

```bash
./install.sh --no-config
```

卸载：

```bash
./install.sh --uninstall
```

安装器修改配置前会保存 `~/.codex/config.toml.codex-notify.bak`。它只管理顶层
`notify` 设置，不修改其他 Codex 配置。Codex 的 `notify` 接口会在回合完成后调用该
程序，并将通知数据作为一个 JSON 参数传入。

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

## 面向开发者的实现说明

### Codex 通知接口

安装器在 `~/.codex/config.toml` 中配置 Codex 的顶层 `notify` 项：

```toml
notify = ["/home/用户名/.local/bin/codex-notify"]
```

Codex 在回合完成时执行该程序，并把通知事件作为单个 JSON 命令行参数传入。脚本只处理
`agent-turn-complete` 事件，当前使用的主要字段如下：

| 字段 | 用途 |
| --- | --- |
| `thread-id` | 查询会话标题，并作为通知同步标识 |
| `cwd` | 显示工作目录，以及辅助识别编辑器窗口 |
| `input-messages` | 从末尾向前选择最后一条非空问题 |
| `last-assistant-message` | 生成本轮回复摘要 |

入口进程首先生成通知内容并记录其父进程链，然后使用 `start_new_session=True` 启动独立的
`--serve` 子进程。这样 Codex 的通知回调可以立即返回，而子进程仍可继续监听最长 120 秒
的点击和关闭事件。

### 标题和正文生成

会话标题按照以下优先级读取：

1. 只读查询 VS Code、VSCodium、Cursor 或 Windsurf 的 `state.vscdb`，取得编辑器中展示
   的会话标签。
2. 使用 `thread-id` 只读查询 `CODEX_HOME` 下的 `state_*.sqlite`，取得 Codex 保存的
   `name` 或 `title`。
3. 查询失败时使用“未命名会话”。

标题格式为 `《会话名称》 @ 目录最后一级`，正文格式为 `上一问 —— 回复摘要`。
`compact()` 会把换行和连续空白压缩成单个空格，并分别按照文件开头的长度常量截断内容。
正文经过 HTML 转义，避免通知服务把问题或回复中的标记解释为富文本。

### 通知发送

主路径通过 PyGObject 的 `Gio` 连接会话 D-Bus，调用
`org.freedesktop.Notifications.Notify`。发送前会调用 `GetCapabilities` 判断通知服务
是否支持动作；支持时注册默认点击动作和“打开窗口”动作，并监听 `ActionInvoked` 与
`NotificationClosed` 信号。

通知使用 `thread-id` 构造 `x-canonical-private-synchronous` 提示，以便兼容的通知服务
合并同一会话的重复通知。在 VS Code 场景中还会附加 `desktop-entry=code`，让通知尽可能
归属于 VS Code。通知服务不一定遵守脚本请求的 30 秒显示时间，实际样式、停留时间和展开
行为由桌面环境决定。

如果 PyGObject 或会话 D-Bus 不可用，脚本回退到 `notify-send`。新版 `notify-send` 若
同时支持 `--action` 和 `--wait`，回退路径仍会监听点击动作；更旧的版本则只发送普通
通知。

### 点击通知后的窗口激活

脚本在脱离 Codex 进程前遍历 `/proc/<pid>` 父进程链，用它判断调用来源是编辑器、终端
还是未知程序，并保存相关 PID、窗口类、编辑器命令和 Desktop Entry。

用户点击通知后按以下顺序尝试返回原窗口：

1. 使用 `WINDOWID` 和 `xdotool` 激活原窗口。
2. 通过 `libX11` 发送 EWMH `_NET_ACTIVE_WINDOW` 消息。
3. 使用 `xprop` 遍历 `_NET_CLIENT_LIST_STACKING`，按父进程 PID 和工作区标题寻找窗口，
   再通过 `libX11` 激活。
4. 编辑器场景调用 `code`、`codium`、`cursor` 或 `windsurf --reuse-window`。这里有意不
   传入工作目录，防止点击通知时打开文件夹或替换当前工作区。
5. 终端场景最后使用 `wmctrl -xa <WM_CLASS>` 进行尽力而为的激活。

前三种路径主要服务于 X11。Wayland 通常限制后台进程任意激活其他应用窗口，因此在
Wayland 下基础通知仍可工作，但精确返回某个终端窗口取决于合成器和终端自身能力。

### 图标与主题检测

Codex 图标的 SVG path 数据直接内嵌在 Python 文件中。运行时依次检查环境变量、GTK
配置、KDE `kdeglobals`/`kreadconfig`、GNOME `gsettings` 和终端 `COLORFGBG`，选择深色
或浅色前景色，然后把生成的 SVG 缓存在 `/tmp/codex-notify-<uid>/`。缓存目录权限为
`0700`、图标文件权限为 `0600`；创建失败时使用系统的 `dialog-information` 图标。

### 兼容性边界

基础通知依赖 FreeDesktop Notifications 标准，因此发行版之间的主要差别通常只是软件
包名称。通知外观、动作支持以及点击后能否返回窗口，更多取决于桌面通知服务和
X11/Wayland。所有增强能力都采用可选依赖和逐级回退设计，缺少 PyGObject、`xprop`、
`xdotool` 或 `wmctrl` 不会影响脚本解析 Codex 事件；至少需要 Python 3，以及可用的
PyGObject 会话 D-Bus 路径或 `notify-send` 之一。
