#!/bin/zsh

# ==============================================================================
# Claude Code 定时刷新脚本
# ==============================================================================

if [ -n "${ZSH_VERSION:-}" ]; then
    emulate -R sh
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
LOCK_DIR="$SCRIPT_DIR/.run.lock"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "[Error] $*" >&2
    exit 1
}

notify_user() {
    local title="$1"
    local message="$2"
    [ "${ENABLE_NOTIFICATIONS:-}" = "true" ] || return 0

    # 优先使用 terminal-notifier：它注册为正规通知 App，在 launchd 后台运行时最稳定。
    if command -v terminal-notifier >/dev/null 2>&1; then
        if terminal-notifier -title "$title" -message "$message" >/dev/null 2>&1; then
            log "[Notify] 已通过 terminal-notifier 发送通知。"
            return 0
        fi
        log "[Notify] [Warning] terminal-notifier 发送失败，改用 osascript。"
    fi

    # 回退到 macOS 自带 osascript。使用裸 display notification，不去控制 Finder，
    # 因此不需要“自动化/Apple 事件”授权，在后台 launchd 环境下更可靠。
    # 先转义反斜杠，再转义双引号，避免 AppleScript 语法被破坏。
    local escaped_title
    escaped_title=$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')
    local escaped_message
    escaped_message=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')

    local notify_err
    if notify_err=$(osascript -e "display notification \"$escaped_message\" with title \"$escaped_title\"" 2>&1); then
        log "[Notify] 已通过 osascript 发送通知。"
    else
        log "[Notify] [Warning] osascript 通知发送失败：$notify_err"
    fi
    return 0
}

trim_value() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

strip_optional_quotes() {
    VALUE="$1"
    case "$VALUE" in
        \"*\")
            VALUE="${VALUE#\"}"
            VALUE="${VALUE%\"}"
            ;;
        \'*\')
            VALUE="${VALUE#\'}"
            VALUE="${VALUE%\'}"
            ;;
    esac
    printf '%s' "$VALUE"
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

load_config() {
    [ -f "$CONFIG_FILE" ] || fail "config.env file not found in $SCRIPT_DIR"

    while IFS= read -r RAW_LINE || [ -n "$RAW_LINE" ]; do
        LINE="$(trim_value "$RAW_LINE")"
        case "$LINE" in
            ''|\#*) continue ;;
        esac

        case "$LINE" in
            *=*) ;;
            *) fail "Invalid config line: $RAW_LINE" ;;
        esac

        KEY="$(trim_value "${LINE%%=*}")"
        VALUE="$(trim_value "${LINE#*=}")"
        VALUE="$(strip_optional_quotes "$VALUE")"

        case "$KEY" in
            MAX_RANDOM_DELAY_SECS)
                is_uint "$VALUE" || fail "MAX_RANDOM_DELAY_SECS must be a non-negative integer"
                MAX_RANDOM_DELAY_SECS="$VALUE"
                ;;
            REFRESH_MESSAGE|GREETING_MESSAGE)
                REFRESH_MESSAGE="$VALUE"
                ;;
            TARGET_WORKSPACE)
                TARGET_WORKSPACE="$VALUE"
                ;;
            ENABLE_NOTIFICATIONS)
                ENABLE_NOTIFICATIONS="$VALUE"
                ;;
            SCHEDULE_TIMES|SCHEDULE_TIME_1_HOUR|SCHEDULE_TIME_1_MINUTE|SCHEDULE_TIME_2_HOUR|SCHEDULE_TIME_2_MINUTE|SCHEDULE_TIME_3_HOUR|SCHEDULE_TIME_3_MINUTE)
                # These values are consumed by manage.sh when generating the LaunchAgent.
                ;;
            *)
                fail "Unsupported config key: $KEY"
                ;;
        esac
    done < "$CONFIG_FILE"
}


acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
        return 0
    fi

    log "[Warning] Another refresh run is already active; skipping this trigger."
    exit 0
}

load_config

# 仅测试通知：强制启用通知、发送一条测试消息后退出，不触发 Claude 刷新。
if [ "${1:-}" = "--notify-test" ]; then
    ENABLE_NOTIFICATIONS=true
    log "[Notify] 发送测试通知。"
    notify_user "Claude 自动刷新 · 测试" "如果你在通知中心看到这条，说明通知功能已正常工作。"
    log "[Notify] 测试通知已发送，请查看通知中心。"
    exit 0
fi

acquire_lock

SKIP_DELAY=false
if [ "$1" = "--no-delay" ]; then
    SKIP_DELAY=true
fi

MAX_RANDOM_DELAY_SECS="${MAX_RANDOM_DELAY_SECS:-0}"
if [ "$SKIP_DELAY" = "false" ] && [ "$MAX_RANDOM_DELAY_SECS" -gt 0 ]; then
    DELAY=$((RANDOM % (MAX_RANDOM_DELAY_SECS + 1)))
    log "[Delay] Sleeping for ${DELAY}s before refreshing Claude Code."
    sleep "$DELAY"
else
    log "[Delay] Skipping random delay."
fi

# launchd does not inherit the interactive shell PATH, so include common install paths.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [ -n "$TARGET_WORKSPACE" ]; then
    # Expand ~ and $HOME to absolute paths
    TARGET_WORKSPACE="${TARGET_WORKSPACE/#\~/$HOME}"
    TARGET_WORKSPACE="${TARGET_WORKSPACE//\$HOME/$HOME}"

    if [ -d "$TARGET_WORKSPACE" ]; then
        log "[Workspace] Using target workspace: $TARGET_WORKSPACE"
        cd "$TARGET_WORKSPACE"
    else
        log "[Workspace] [Warning] TARGET_WORKSPACE '$TARGET_WORKSPACE' is not a directory; using $SCRIPT_DIR"
        cd "$SCRIPT_DIR"
    fi
else
    log "[Workspace] TARGET_WORKSPACE not configured; using $SCRIPT_DIR"
    cd "$SCRIPT_DIR"
fi

if ! command -v claude >/dev/null 2>&1; then
    notify_user "Claude 自动刷新 · 错误" "未找到 claude 命令行。请运行：npm install -g @anthropic-ai/claude-code"
    fail "'claude' CLI not found in PATH. Please install it using: npm install -g @anthropic-ai/claude-code\nCurrent PATH: $PATH"
fi

CLAUDE_BIN="$(command -v claude)"
CLAUDE_VERSION="$("$CLAUDE_BIN" --version 2>&1 | tr '\n' ' ')"
REFRESH_MESSAGE="${REFRESH_MESSAGE:-Hi}"

log "[Env] Using Claude Code: $CLAUDE_BIN"
log "[Env] Claude version: $CLAUDE_VERSION"
log "[Claude] Starting one non-interactive refresh request."

notify_user "Claude 自动刷新" "正在向 Claude 发送刷新消息..."

set +e
"$CLAUDE_BIN" -p "$REFRESH_MESSAGE" < /dev/null
CLAUDE_EXIT_CODE=$?
set -e

if [ "$CLAUDE_EXIT_CODE" -eq 0 ]; then
    log "[Claude] [Success] Claude Code refresh completed."
    notify_user "Claude 自动刷新" "刷新成功！已成功回复并刷新 5 小时窗口。"
else
    log "[Claude] [Error] Claude Code exited with code $CLAUDE_EXIT_CODE" >&2
    notify_user "Claude 自动刷新" "刷新失败，错误代码: $CLAUDE_EXIT_CODE"
fi

exit "$CLAUDE_EXIT_CODE"

