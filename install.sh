#!/bin/sh

set -eu

PROGRAM_NAME="codex-notify"
DEFAULT_SOURCE_URL="https://raw.githubusercontent.com/Huffer342-WSH/Codex-Notify/refs/heads/main/codex-notify.py"
INSTALL_DIR="${CODEX_NOTIFY_INSTALL_DIR:-${HOME}/.local/bin}"
INSTALL_PATH="${INSTALL_DIR}/${PROGRAM_NAME}"
CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
CONFIG_PATH="${CODEX_DIR}/config.toml"
SOURCE_URL="${CODEX_NOTIFY_SOURCE_URL:-}"
UNINSTALL=0
SKIP_CONFIG=0

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --source-url URL  Download codex-notify.py from a custom URL
  --install-dir DIR Install the executable in DIR (default: ~/.local/bin)
  --no-config       Install the executable without changing Codex config.toml
  --uninstall       Remove the executable and its Codex notify configuration
  -h, --help        Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-url)
            [ "$#" -ge 2 ] || { echo "error: --source-url requires a URL" >&2; exit 2; }
            SOURCE_URL=$2
            shift 2
            ;;
        --install-dir)
            [ "$#" -ge 2 ] || { echo "error: --install-dir requires a directory" >&2; exit 2; }
            INSTALL_DIR=$2
            INSTALL_PATH="${INSTALL_DIR}/${PROGRAM_NAME}"
            shift 2
            ;;
        --no-config)
            SKIP_CONFIG=1
            shift
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

command -v python3 >/dev/null 2>&1 || {
    echo "error: Python 3 is required" >&2
    exit 1
}

update_codex_config() {
    mode=$1
    mkdir -p "$CODEX_DIR"

    if [ -f "$CONFIG_PATH" ]; then
        cp -p "$CONFIG_PATH" "${CONFIG_PATH}.codex-notify.bak"
    fi

    python3 - "$CONFIG_PATH" "$INSTALL_PATH" "$mode" <<'PY'
import json
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
install_path = sys.argv[2]
mode = sys.argv[3]
text = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
lines = text.splitlines(keepends=True)

# Codex's notify key is a top-level TOML setting. Replace only that setting and
# leave tables, comments, and all unrelated configuration untouched.
notify_line = re.compile(r"^notify\s*=")
first_table = next(
    (index for index, line in enumerate(lines) if line.lstrip().startswith("[")),
    len(lines),
)
top_level_matches = [
    index for index, line in enumerate(lines[:first_table]) if notify_line.match(line)
]

if mode == "install":
    replacement = f"notify = [{json.dumps(install_path)}]\n"
    if top_level_matches:
        lines[top_level_matches[0]] = replacement
        for index in reversed(top_level_matches[1:]):
            del lines[index]
    else:
        insert_at = first_table
        if insert_at and lines[insert_at - 1].strip():
            replacement += "\n"
        lines.insert(insert_at, replacement)
else:
    expected = re.compile(
        r"^notify\s*=\s*\[\s*" + re.escape(json.dumps(install_path)) + r"\s*\]\s*(?:#.*)?$"
    )
    lines = [line for line in lines if not expected.match(line.rstrip("\r\n"))]

config_path.write_text("".join(lines), encoding="utf-8")
PY
}

if [ "$UNINSTALL" -eq 1 ]; then
    if [ "$SKIP_CONFIG" -eq 0 ]; then
        update_codex_config uninstall
    fi
    if [ -f "$INSTALL_PATH" ]; then
        rm -f "$INSTALL_PATH"
    fi
    echo "Removed ${PROGRAM_NAME} from ${INSTALL_PATH}"
    echo "Restart Codex to apply the change."
    exit 0
fi

mkdir -p "$INSTALL_DIR"
temp_file="${INSTALL_PATH}.tmp.$$"
trap 'rm -f "$temp_file"' EXIT HUP INT TERM

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)
local_source="${script_dir}/codex-notify.py"

if [ -n "$SOURCE_URL" ]; then
    case "$SOURCE_URL" in
        https://*|http://*) ;;
        *) echo "error: --source-url must use http:// or https://" >&2; exit 2 ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location "$SOURCE_URL" -o "$temp_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$temp_file" "$SOURCE_URL"
    else
        echo "error: curl or wget is required for remote installation" >&2
        exit 1
    fi
elif [ -n "$script_dir" ] && [ -f "$local_source" ]; then
    cp "$local_source" "$temp_file"
else
    SOURCE_URL=$DEFAULT_SOURCE_URL
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location "$SOURCE_URL" -o "$temp_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$temp_file" "$SOURCE_URL"
    else
        echo "error: curl or wget is required for remote installation" >&2
        exit 1
    fi
fi

python3 - "$temp_file" <<'PY'
import ast
import sys
from pathlib import Path

ast.parse(Path(sys.argv[1]).read_text(encoding="utf-8"))
PY
chmod 755 "$temp_file"
mv "$temp_file" "$INSTALL_PATH"
trap - EXIT HUP INT TERM

if [ "$SKIP_CONFIG" -eq 0 ]; then
    update_codex_config install
fi

echo "Installed ${PROGRAM_NAME} to ${INSTALL_PATH}"
if [ "$SKIP_CONFIG" -eq 0 ]; then
    echo "Configured Codex notify in ${CONFIG_PATH}"
    [ ! -f "${CONFIG_PATH}.codex-notify.bak" ] || \
        echo "Backup: ${CONFIG_PATH}.codex-notify.bak"
fi
echo "Restart Codex to apply the change."
