#!/usr/bin/env python3
"""Portable Linux desktop notifications for completed Codex turns."""

from __future__ import annotations

import glob
import html
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import ctypes
import tempfile
import configparser
from pathlib import Path

try:
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib
except (ImportError, ValueError):
    Gio = None
    GLib = None


APP_NAME = "Codex"
EXPIRE_MS = 30_000
WATCH_SECONDS = 120
SESSION_PREVIEW_LIMIT = 40
DIRECTORY_PREVIEW_LIMIT = 24
TITLE_PREVIEW_LIMIT = 72
QUESTION_PREVIEW_LIMIT = 300
ANSWER_PREVIEW_LIMIT = 300
CODEX_ICON_PATH_DATA = (
    "M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 "
    "3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 "
    "4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 "
    "3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 "
    "1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 "
    "2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 "
    "6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 "
    "1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 "
    "2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 "
    "00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 "
    "01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 "
    "7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 "
    "00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 "
    "01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 "
    "6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 "
    "0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 "
    "8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 "
    "2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 "
    "0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 "
    "1.695h4.848a.849.849 0 000-1.696h-4.848z"
)


def compact(value: object, limit: int) -> str:
    """Turn arbitrary notification content into a short single-line preview."""
    if isinstance(value, str):
        text = value
    elif value is None:
        text = ""
    else:
        text = json.dumps(value, ensure_ascii=False)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)].rstrip() + "…"


def codex_home() -> Path:
    configured = os.environ.get("CODEX_HOME")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".codex"


def prefers_dark_theme() -> bool:
    """Detect dark themes across GNOME, KDE, GTK, and common environments."""
    environment_hints = " ".join(
        os.environ.get(name, "")
        for name in ("GTK_THEME", "QT_STYLE_OVERRIDE", "COLOR_SCHEME")
    ).casefold()
    if "dark" in environment_hints:
        return True

    config_home = Path(
        os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
    )
    for settings_path in (
        config_home / "gtk-3.0/settings.ini",
        config_home / "gtk-4.0/settings.ini",
        config_home / "kdeglobals",
    ):
        try:
            parser = configparser.ConfigParser()
            parser.read(settings_path)
            values = " ".join(
                value
                for section in parser.sections()
                for _key, value in parser.items(section)
            ).casefold()
            if "dark" in values:
                return True
            if parser.getboolean(
                "Settings", "gtk-application-prefer-dark-theme", fallback=False
            ):
                return True
        except (OSError, configparser.Error, ValueError):
            continue

    for command in ("kreadconfig6", "kreadconfig5"):
        executable = shutil.which(command)
        if not executable:
            continue
        try:
            value = subprocess.run(
                [executable, "--group", "General", "--key", "ColorScheme"],
                check=False,
                capture_output=True,
                text=True,
                timeout=2,
            ).stdout.casefold()
            if "dark" in value:
                return True
        except (OSError, subprocess.SubprocessError):
            pass

    gsettings = shutil.which("gsettings")
    if gsettings:
        for key in ("color-scheme", "gtk-theme"):
            try:
                value = subprocess.run(
                    [gsettings, "get", "org.gnome.desktop.interface", key],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=2,
                ).stdout.strip().strip("'").casefold()
            except (OSError, subprocess.SubprocessError):
                continue
            if value == "prefer-dark" or "dark" in value:
                return True

    colorfgbg = os.environ.get("COLORFGBG", "")
    match = re.search(r"(?:^|;)(\d+)$", colorfgbg)
    if match and int(match.group(1)) < 8:
        return True
    return False


def notification_icon() -> str:
    """Materialize the embedded SVG using a theme-appropriate foreground."""
    theme = "dark" if prefers_dark_theme() else "light"
    color = "#F7F7F8" if theme == "dark" else "#202123"
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
        f'width="64" height="64" fill="{color}" fill-rule="evenodd">'
        '<title>Codex</title>'
        f'<path clip-rule="evenodd" d="{CODEX_ICON_PATH_DATA}"/>'
        "</svg>"
    )
    cache_directory = (
        Path(tempfile.gettempdir()) / f"codex-notify-{os.getuid()}"
    )
    icon_path = cache_directory / f"codex-{theme}.svg"
    try:
        cache_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if not icon_path.is_file() or icon_path.read_text() != svg:
            icon_path.write_text(svg)
            icon_path.chmod(0o600)
    except OSError:
        return "dialog-information"
    return str(icon_path)


def vscode_session_name(thread_id: str) -> str:
    """Read the label shown by VS Code's Codex session list."""
    if not thread_id:
        return ""
    config_home = Path(
        os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
    )
    storage_roots = tuple(
        config_home / product / "User/workspaceStorage"
        for product in (
            "Code",
            "Code - Insiders",
            "VSCodium",
            "Cursor",
            "Windsurf",
        )
    )
    databases: list[Path] = []
    for root in storage_roots:
        databases.extend(root.glob("*/state.vscdb"))
    databases.sort(key=lambda item: item.stat().st_mtime, reverse=True)

    resource_suffix = f"/{thread_id}"
    for database in databases:
        try:
            uri = database.resolve().as_uri() + "?mode=ro"
            with sqlite3.connect(uri, uri=True, timeout=1) as connection:
                row = connection.execute(
                    "SELECT value FROM ItemTable "
                    "WHERE key = 'agentSessions.model.cache'"
                ).fetchone()
            if not row or not row[0]:
                continue
            sessions = json.loads(row[0])
            for session in sessions if isinstance(sessions, list) else ():
                if not isinstance(session, dict):
                    continue
                resource = str(session.get("resource") or "")
                if resource.endswith(resource_suffix):
                    label = compact(session.get("label"), SESSION_PREVIEW_LIMIT)
                    if label:
                        return label
        except (OSError, sqlite3.Error, json.JSONDecodeError):
            continue
    return ""


def session_name(thread_id: str, cwd: str) -> str:
    """Look up the user/auto-generated thread name, with a project fallback."""
    vscode_name = vscode_session_name(thread_id)
    if vscode_name:
        return vscode_name
    if thread_id:
        databases = sorted(
            glob.glob(str(codex_home() / "state_*.sqlite")),
            key=lambda item: os.path.getmtime(item),
            reverse=True,
        )
        for database in databases:
            try:
                uri = Path(database).resolve().as_uri() + "?mode=ro"
                with sqlite3.connect(uri, uri=True, timeout=1) as connection:
                    row = connection.execute(
                        "SELECT name, title FROM threads WHERE id = ?", (thread_id,)
                    ).fetchone()
                if row:
                    name = compact(row[0] or row[1], SESSION_PREVIEW_LIMIT)
                    if name:
                        return name
            except (OSError, sqlite3.Error):
                continue
    return "未命名会话"


def user_preview(messages: object) -> str:
    if isinstance(messages, list):
        # Codex may include multiple input messages in the payload. A desktop
        # banner should show only the latest user question, not their history.
        for item in reversed(messages):
            preview = compact(item, QUESTION_PREVIEW_LIMIT)
            if preview:
                return preview
        return ""
    return compact(messages, QUESTION_PREVIEW_LIMIT)


def source_context() -> tuple[str, list[int], str, str, str]:
    """Identify the editor or terminal that owns Codex before detaching."""
    pids: list[int] = []
    commands: list[str] = []
    pid = os.getppid()
    while pid > 1 and pid not in pids:
        pids.append(pid)
        try:
            command = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ")
            command_text = command.decode(errors="replace").lower()
            if any(
                boundary in command_text
                for boundary in (
                    "gnome-shell",
                    "plasmashell",
                    "xfdesktop",
                    "cinnamon --replace",
                    "mate-panel",
                    "lxqt-panel",
                    "systemd --user",
                )
            ):
                pids.pop()
                break
            commands.append(command_text)
            status = Path(f"/proc/{pid}/status").read_text(errors="replace")
            match = re.search(r"^PPid:\s+(\d+)$", status, re.MULTILINE)
            if not match:
                break
            pid = int(match.group(1))
        except (OSError, ValueError):
            break

    ancestry = "\n".join(commands)
    editor_rules = (
        ("cursor", "cursor", "cursor", "cursor"),
        ("windsurf", "windsurf", "windsurf", "windsurf"),
        ("codium", "codium", "codium", "codium"),
        ("code-insiders", "code-insiders", "code-insiders", "code-insiders"),
    )
    for identifier, command, desktop_entry, wm_class in editor_rules:
        if identifier in ancestry:
            return "editor", pids, wm_class, command, desktop_entry
    if (
        os.environ.get("TERM_PROGRAM") == "vscode"
        or "/.vscode/extensions/" in ancestry
        or re.search(r"(?:^|[/ ])code(?:\s|$)", ancestry)
    ):
        return "editor", pids, "code", "code", "code"

    terminal_rules = (
        ("gnome-terminal", "gnome-terminal-server"),
        ("org.gnome.console", "org.gnome.Console"),
        ("/kgx", "org.gnome.Console"),
        ("konsole", "konsole"),
        ("xfce4-terminal", "xfce4-terminal"),
        ("mate-terminal", "mate-terminal"),
        ("lxterminal", "lxterminal"),
        ("qterminal", "qterminal"),
        ("terminator", "terminator"),
        ("tilix", "tilix"),
        ("ghostty", "com.mitchellh.ghostty"),
        ("kitty", "kitty"),
        ("alacritty", "Alacritty"),
        ("wezterm", "org.wezfurlong.wezterm"),
        ("foot", "foot"),
        ("urxvt", "URxvt"),
        ("xterm", "XTerm"),
    )
    for identifier, wm_class in terminal_rules:
        if identifier in ancestry:
            return "terminal", pids, wm_class, "", ""
    return "unknown", pids, "", "", ""


def activate_x11_window(window_id: int) -> bool:
    """Ask the X11 window manager to activate a top-level window."""
    if not window_id or not os.environ.get("DISPLAY"):
        return False

    class ClientMessageData(ctypes.Union):
        _fields_ = [
            ("b", ctypes.c_char * 20),
            ("s", ctypes.c_short * 10),
            ("l", ctypes.c_long * 5),
        ]

    class XClientMessageEvent(ctypes.Structure):
        _fields_ = [
            ("type", ctypes.c_int),
            ("serial", ctypes.c_ulong),
            ("send_event", ctypes.c_int),
            ("display", ctypes.c_void_p),
            ("window", ctypes.c_ulong),
            ("message_type", ctypes.c_ulong),
            ("format", ctypes.c_int),
            ("data", ClientMessageData),
        ]

    class XEvent(ctypes.Union):
        _fields_ = [
            ("type", ctypes.c_int),
            ("xclient", XClientMessageEvent),
            ("padding", ctypes.c_long * 24),
        ]

    try:
        xlib = ctypes.CDLL("libX11.so.6")
        xlib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        xlib.XOpenDisplay.restype = ctypes.c_void_p
        xlib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        xlib.XDefaultRootWindow.restype = ctypes.c_ulong
        xlib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        xlib.XInternAtom.restype = ctypes.c_ulong
        xlib.XSendEvent.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.c_int,
            ctypes.c_long,
            ctypes.POINTER(XEvent),
        ]
        xlib.XSendEvent.restype = ctypes.c_int
        xlib.XMapRaised.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        xlib.XMapRaised.restype = ctypes.c_int
        xlib.XFlush.argtypes = [ctypes.c_void_p]
        xlib.XFlush.restype = ctypes.c_int
        xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        xlib.XCloseDisplay.restype = ctypes.c_int
        display = xlib.XOpenDisplay(None)
        if not display:
            return False
        root = xlib.XDefaultRootWindow(display)
        active_atom = xlib.XInternAtom(display, b"_NET_ACTIVE_WINDOW", 0)
        event = XEvent()
        event.xclient.type = 33  # ClientMessage
        event.xclient.send_event = 1
        event.xclient.display = display
        event.xclient.window = window_id
        event.xclient.message_type = active_atom
        event.xclient.format = 32
        event.xclient.data.l[0] = 2  # pager/window-switcher request
        event.xclient.data.l[1] = 0
        mask = (1 << 20) | (1 << 19)  # SubstructureRedirect/NotifyMask
        sent = bool(xlib.XSendEvent(display, root, 0, mask, ctypes.byref(event)))
        xlib.XMapRaised(display, window_id)
        xlib.XFlush(display)
        xlib.XCloseDisplay(display)
        return sent
    except (OSError, AttributeError):
        return False


def window_for_processes(
    pids: set[int], preferred_title: str = ""
) -> int | None:
    """Find the top-most X11 client window owned by one of the source processes."""
    xprop = shutil.which("xprop")
    if not xprop or not pids or not os.environ.get("DISPLAY"):
        return None
    try:
        clients = subprocess.run(
            [xprop, "-root", "_NET_CLIENT_LIST_STACKING"],
            check=True,
            capture_output=True,
            text=True,
            timeout=3,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None

    fallback: int | None = None
    preferred_title = preferred_title.casefold()
    # The stacking list is bottom-to-top. Prefer a window whose title contains
    # the workspace directory; otherwise retain the most recently raised match.
    for raw_window in reversed(re.findall(r"0x[0-9a-fA-F]+", clients)):
        try:
            properties = subprocess.run(
                [xprop, "-id", raw_window, "_NET_WM_PID", "_NET_WM_NAME"],
                check=False,
                capture_output=True,
                text=True,
                timeout=1,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        match = re.search(r"=\s*(\d+)", properties)
        if match and int(match.group(1)) in pids:
            candidate = int(raw_window, 16)
            if fallback is None:
                fallback = candidate
            if preferred_title and preferred_title in properties.casefold():
                return candidate
    return fallback


def send_fallback(title: str, body: str, cwd: str = "") -> bool:
    """Use libnotify when PyGObject is unavailable; enable actions if supported."""
    notify_send = shutil.which("notify-send")
    if not notify_send:
        return False
    command = [
        notify_send,
        "--app-name=Codex",
        f"--icon={notification_icon()}",
        "--urgency=normal",
        f"--expire-time={EXPIRE_MS}",
    ]
    supports_actions = False
    if cwd:
        try:
            help_text = subprocess.run(
                [notify_send, "--help"],
                check=False,
                capture_output=True,
                text=True,
                timeout=2,
            ).stdout
            supports_actions = "--action" in help_text and "--wait" in help_text
        except (OSError, subprocess.SubprocessError):
            pass
    if supports_actions:
        command.extend(("--wait", "--action=open-window=打开窗口"))
    command.extend((title, body))
    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=supports_actions,
            text=supports_actions,
            timeout=WATCH_SECONDS + 5 if supports_actions else 5,
        )
        if supports_actions and result.stdout.strip() == "open-window":
            activate_window(cwd)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def activate_window(cwd: str) -> None:
    window_id = os.environ.get("WINDOWID", "")
    xdotool = shutil.which("xdotool")
    if window_id and xdotool:
        try:
            subprocess.Popen(
                [xdotool, "windowactivate", "--sync", window_id],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return
        except OSError:
            pass

    if window_id:
        try:
            if activate_x11_window(int(window_id, 0)):
                return
        except ValueError:
            pass

    source_kind = os.environ.get("CODEX_NOTIFY_SOURCE_KIND", "unknown")
    try:
        source_pids = {
            int(item)
            for item in os.environ.get("CODEX_NOTIFY_SOURCE_PIDS", "").split(",")
            if item
        }
    except ValueError:
        source_pids = set()

    preferred_title = Path(cwd).name if source_kind == "editor" else ""
    source_window = window_for_processes(source_pids, preferred_title)
    if source_window and activate_x11_window(source_window):
        return

    # On non-X11 systems, ask VS Code to reuse an existing window without
    # passing cwd. Passing cwd here would open/replace the workspace folder.
    editor_command = os.environ.get("CODEX_NOTIFY_EDITOR_COMMAND", "")
    editor = shutil.which(editor_command) if editor_command else None
    if editor and source_kind == "editor":
        try:
            subprocess.Popen(
                [editor, "--reuse-window"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return
        except OSError:
            pass

    # Best-effort fallbacks for other terminal emulators.
    wmctrl = shutil.which("wmctrl")
    terminal_class = os.environ.get("CODEX_NOTIFY_WM_CLASS", "")
    if wmctrl and terminal_class:
        try:
            subprocess.Popen(
                [wmctrl, "-xa", terminal_class],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return
        except OSError:
            pass


def serve_desktop_notification(title: str, body: str, thread_id: str, cwd: str) -> int:
    """Use the standard FreeDesktop service and keep its click connection alive."""
    if Gio is None or GLib is None or not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        return 0 if send_fallback(title, body, cwd) else 1

    destination = "org.freedesktop.Notifications"
    object_path = "/org/freedesktop/Notifications"
    interface = "org.freedesktop.Notifications"
    loop = GLib.MainLoop()
    notification_id = 0

    try:
        connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except GLib.Error:
        return 0 if send_fallback(title, body, cwd) else 1

    actions_supported = True
    try:
        capabilities = connection.call_sync(
            destination,
            object_path,
            interface,
            "GetCapabilities",
            None,
            GLib.VariantType.new("(as)"),
            Gio.DBusCallFlags.NONE,
            3_000,
            None,
        ).unpack()[0]
        actions_supported = "actions" in capabilities
    except GLib.Error:
        # Preserve the proven GNOME path when an older daemon cannot report
        # capabilities; unsupported action arrays are normally ignored.
        pass

    def action_invoked(
        _connection: object,
        _sender: str,
        _path: str,
        _interface: str,
        _signal: str,
        parameters: object,
        _data: object,
    ) -> None:
        clicked_id, action = parameters.unpack()
        if clicked_id == notification_id and action in {"default", "open-window"}:
            activate_window(cwd)
            loop.quit()

    def notification_closed(
        _connection: object,
        _sender: str,
        _path: str,
        _interface: str,
        _signal: str,
        parameters: object,
        _data: object,
    ) -> None:
        closed_id, _reason = parameters.unpack()
        if closed_id == notification_id:
            loop.quit()

    action_subscription = connection.signal_subscribe(
        destination,
        interface,
        "ActionInvoked",
        object_path,
        None,
        Gio.DBusSignalFlags.NONE,
        action_invoked,
        None,
    )
    close_subscription = connection.signal_subscribe(
        destination,
        interface,
        "NotificationClosed",
        object_path,
        None,
        Gio.DBusSignalFlags.NONE,
        notification_closed,
        None,
    )

    sync_key = compact(thread_id, 120) or "codex"
    hints = {
        "x-canonical-private-synchronous": GLib.Variant("s", f"codex-{sync_key}"),
    }
    desktop_entry = os.environ.get("CODEX_NOTIFY_DESKTOP_ENTRY", "")
    if desktop_entry:
        hints["desktop-entry"] = GLib.Variant("s", desktop_entry)
    actions = (
        ["default", "打开会话", "open-window", "打开窗口"]
        if actions_supported
        else []
    )
    arguments = GLib.Variant(
        "(susssasa{sv}i)",
        (
            APP_NAME,
            0,
            notification_icon(),
            title,
            body,
            actions,
            hints,
            EXPIRE_MS,
        ),
    )
    try:
        result = connection.call_sync(
            destination,
            object_path,
            interface,
            "Notify",
            arguments,
            GLib.VariantType.new("(u)"),
            Gio.DBusCallFlags.NONE,
            5_000,
            None,
        )
        notification_id = result.unpack()[0]
        GLib.timeout_add_seconds(WATCH_SECONDS, lambda: (loop.quit(), False)[1])
        loop.run()
    except GLib.Error:
        send_fallback(title, body, cwd)
    finally:
        connection.signal_unsubscribe(action_subscription)
        connection.signal_unsubscribe(close_subscription)
    return 0


def notification_content(payload: dict[str, object]) -> tuple[str, str, str, str]:
    if payload.get("type") != "agent-turn-complete":
        return "", "", "", ""

    thread_id = compact(payload.get("thread-id"), 160)
    cwd = str(payload.get("cwd") or "")
    name = session_name(thread_id, cwd)
    question = user_preview(payload.get("input-messages")) or "（无问题摘要）"
    answer = (
        compact(payload.get("last-assistant-message"), ANSWER_PREVIEW_LIMIT)
        or "任务已完成"
    )

    directory = Path(cwd).name if cwd else "未知目录"
    directory = compact(directory, DIRECTORY_PREVIEW_LIMIT)
    title_content = compact(
        f"《{name}》 @ {directory}", TITLE_PREVIEW_LIMIT
    )
    title = title_content
    body = f"{html.escape(question)} —— {html.escape(answer)}"

    return title, body, thread_id, cwd


def notification_python() -> str:
    """Prefer an interpreter with PyGObject, then fall back to this Python."""
    if Gio is not None and GLib is not None:
        return sys.executable
    candidates = (shutil.which("python3"), "/usr/bin/python3")
    for candidate in dict.fromkeys(item for item in candidates if item):
        try:
            subprocess.run(
                [
                    candidate,
                    "-c",
                    "import gi; gi.require_version('Gio','2.0'); "
                    "from gi.repository import Gio, GLib",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=3,
            )
            return candidate
        except (OSError, subprocess.SubprocessError):
            continue
    return sys.executable


def notify(payload: dict[str, object]) -> int:
    title, body, _thread_id, _cwd = notification_content(payload)
    if not title:
        return 0

    source_kind, source_pids, wm_class, editor_command, desktop_entry = source_context()
    child_environment = os.environ.copy()
    child_environment["CODEX_NOTIFY_SOURCE_KIND"] = source_kind
    child_environment["CODEX_NOTIFY_SOURCE_PIDS"] = ",".join(
        str(pid) for pid in source_pids
    )
    child_environment["CODEX_NOTIFY_WM_CLASS"] = wm_class
    child_environment["CODEX_NOTIFY_EDITOR_COMMAND"] = editor_command
    child_environment["CODEX_NOTIFY_DESKTOP_ENTRY"] = desktop_entry

    try:
        subprocess.Popen(
            [
                notification_python(),
                str(Path(__file__).resolve()),
                "--serve",
                json.dumps(payload, ensure_ascii=False),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            env=child_environment,
        )
    except OSError:
        os.environ.update(
            {
                "CODEX_NOTIFY_SOURCE_KIND": source_kind,
                "CODEX_NOTIFY_SOURCE_PIDS": child_environment[
                    "CODEX_NOTIFY_SOURCE_PIDS"
                ],
                "CODEX_NOTIFY_WM_CLASS": wm_class,
                "CODEX_NOTIFY_EDITOR_COMMAND": editor_command,
                "CODEX_NOTIFY_DESKTOP_ENTRY": desktop_entry,
            }
        )
        return serve_desktop_notification(title, body, _thread_id, _cwd)
    return 0


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--serve":
        try:
            payload = json.loads(sys.argv[2])
        except json.JSONDecodeError:
            return 2
        if not isinstance(payload, dict):
            return 2
        title, body, thread_id, cwd = notification_content(payload)
        return serve_desktop_notification(title, body, thread_id, cwd) if title else 0

    if len(sys.argv) != 2:
        print("usage: codex-notify '<json-payload>'", file=sys.stderr)
        return 2
    try:
        payload = json.loads(sys.argv[1])
    except json.JSONDecodeError as error:
        print(f"codex-notify: invalid JSON: {error}", file=sys.stderr)
        return 2
    if not isinstance(payload, dict):
        return 2
    return notify(payload)


if __name__ == "__main__":
    raise SystemExit(main())
