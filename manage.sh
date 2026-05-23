#!/bin/zsh

# ==============================================================================
# Claude Code 定时刷新管理工具
# ==============================================================================

if [ -n "${ZSH_VERSION:-}" ]; then
    emulate -R sh
fi

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECURE_DIR="$HOME/.claude-autostart"

LABEL="com.jiaweili.claude-autostart"
PLIST_NAME="$LABEL.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
SERVICE_DOMAIN="gui/$(id -u)"

LOG_FILE="$SECURE_DIR/autostart.log"
ERR_FILE="$SECURE_DIR/autostart.err.log"

show_help() {
    echo "=========================================================="
    echo " Claude Code 定时刷新管理工具"
    echo "=========================================================="
    echo "用法: ./manage.sh [命令]"
    echo ""
    echo "可用命令:"
    echo "  install        安装/更新定时刷新任务"
    echo "  uninstall      卸载定时任务并清理运行目录"
    echo "  test-now       立即执行一次刷新，不等待随机延迟"
    echo "  run            前台执行一次刷新，包含随机延迟"
    echo "  notify-test    只发送一条测试通知，用于排查通知中心是否能收到"
    echo "  start-service  通过 launchd 立即触发一次后台刷新"
    echo "  stop-service   停止当前正在执行的后台刷新"
    echo "  logs           查看最近输出日志"
    echo "  errlogs        查看最近错误日志"
    echo "  status         查看 launchd 加载状态"
    echo "=========================================================="
}

fail() {
    echo "[Error] $*" >&2
    exit 1
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

normalize_uint() {
    VALUE="$1"
    while [ "$VALUE" != "0" ] && [ "${VALUE#0}" != "$VALUE" ]; do
        VALUE="${VALUE#0}"
    done
    [ -n "$VALUE" ] || VALUE=0
    printf '%s' "$VALUE"
}

pad2() {
    if [ "$1" -lt 10 ]; then
        printf '0%s' "$1"
    else
        printf '%s' "$1"
    fi
}

reset_config() {
    SCHEDULE_TIMES=""
    SCHEDULE_TIME_1_HOUR=""
    SCHEDULE_TIME_1_MINUTE=""
    SCHEDULE_TIME_2_HOUR=""
    SCHEDULE_TIME_2_MINUTE=""
    SCHEDULE_TIME_3_HOUR=""
    SCHEDULE_TIME_3_MINUTE=""
    MAX_RANDOM_DELAY_SECS=""
    REFRESH_MESSAGE=""
    TARGET_WORKSPACE=""
    ENABLE_NOTIFICATIONS=""
}

load_config() {
    CONFIG_FILE="$1"
    [ -f "$CONFIG_FILE" ] || fail "找不到配置文件: $CONFIG_FILE"

    reset_config

    while IFS= read -r RAW_LINE || [ -n "$RAW_LINE" ]; do
        LINE="$(trim_value "$RAW_LINE")"
        case "$LINE" in
            ''|\#*) continue ;;
        esac

        case "$LINE" in
            *=*) ;;
            *) fail "配置格式错误: $RAW_LINE" ;;
        esac

        KEY="$(trim_value "${LINE%%=*}")"
        VALUE="$(trim_value "${LINE#*=}")"
        VALUE="$(strip_optional_quotes "$VALUE")"

        case "$KEY" in
            SCHEDULE_TIMES)
                SCHEDULE_TIMES="$VALUE"
                ;;
            SCHEDULE_TIME_1_HOUR)
                SCHEDULE_TIME_1_HOUR="$VALUE"
                ;;
            SCHEDULE_TIME_1_MINUTE)
                SCHEDULE_TIME_1_MINUTE="$VALUE"
                ;;
            SCHEDULE_TIME_2_HOUR)
                SCHEDULE_TIME_2_HOUR="$VALUE"
                ;;
            SCHEDULE_TIME_2_MINUTE)
                SCHEDULE_TIME_2_MINUTE="$VALUE"
                ;;
            SCHEDULE_TIME_3_HOUR)
                SCHEDULE_TIME_3_HOUR="$VALUE"
                ;;
            SCHEDULE_TIME_3_MINUTE)
                SCHEDULE_TIME_3_MINUTE="$VALUE"
                ;;
            MAX_RANDOM_DELAY_SECS)
                is_uint "$VALUE" || fail "MAX_RANDOM_DELAY_SECS 必须是非负整数"
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
            *)
                fail "不支持的配置项: $KEY"
                ;;
        esac
    done < "$CONFIG_FILE"
}

add_schedule() {
    RAW_HOUR="$(trim_value "$1")"
    RAW_MINUTE="$(trim_value "$2")"

    is_uint "$RAW_HOUR" || fail "定时小时必须是 0-23 的整数: $RAW_HOUR"
    is_uint "$RAW_MINUTE" || fail "定时分钟必须是 0-59 的整数: $RAW_MINUTE"

    HOUR_VALUE="$(normalize_uint "$RAW_HOUR")"
    MINUTE_VALUE="$(normalize_uint "$RAW_MINUTE")"

    [ "$HOUR_VALUE" -ge 0 ] && [ "$HOUR_VALUE" -le 23 ] || fail "定时小时超出范围: $RAW_HOUR"
    [ "$MINUTE_VALUE" -ge 0 ] && [ "$MINUTE_VALUE" -le 59 ] || fail "定时分钟超出范围: $RAW_MINUTE"

    TIME_LABEL="$(pad2 "$HOUR_VALUE"):$(pad2 "$MINUTE_VALUE")"
    if [ -z "$SCHEDULE_SUMMARY" ]; then
        SCHEDULE_SUMMARY="$TIME_LABEL"
    else
        SCHEDULE_SUMMARY="$SCHEDULE_SUMMARY, $TIME_LABEL"
    fi

    PLIST_INTERVALS="${PLIST_INTERVALS}        <dict>
            <key>Hour</key>
            <integer>$HOUR_VALUE</integer>
            <key>Minute</key>
            <integer>$MINUTE_VALUE</integer>
        </dict>
"
}

build_schedule_config() {
    PLIST_INTERVALS=""
    SCHEDULE_SUMMARY=""

    if [ -n "$SCHEDULE_TIMES" ]; then
        OLD_IFS="$IFS"
        IFS=','
        for TIME_ITEM in $SCHEDULE_TIMES; do
            IFS="$OLD_IFS"
            TIME_ITEM="$(trim_value "$TIME_ITEM")"
            [ -n "$TIME_ITEM" ] || continue
            case "$TIME_ITEM" in
                *:*) add_schedule "${TIME_ITEM%%:*}" "${TIME_ITEM#*:}" ;;
                *) fail "SCHEDULE_TIMES 格式应为 08:30,14:00,19:10: $TIME_ITEM" ;;
            esac
            IFS=','
        done
        IFS="$OLD_IFS"
    else
        if [ -n "$SCHEDULE_TIME_1_HOUR" ] || [ -n "$SCHEDULE_TIME_1_MINUTE" ]; then
            [ -n "$SCHEDULE_TIME_1_HOUR" ] && [ -n "$SCHEDULE_TIME_1_MINUTE" ] || fail "SCHEDULE_TIME_1_HOUR/MINUTE 必须成对配置"
            add_schedule "$SCHEDULE_TIME_1_HOUR" "$SCHEDULE_TIME_1_MINUTE"
        fi
        if [ -n "$SCHEDULE_TIME_2_HOUR" ] || [ -n "$SCHEDULE_TIME_2_MINUTE" ]; then
            [ -n "$SCHEDULE_TIME_2_HOUR" ] && [ -n "$SCHEDULE_TIME_2_MINUTE" ] || fail "SCHEDULE_TIME_2_HOUR/MINUTE 必须成对配置"
            add_schedule "$SCHEDULE_TIME_2_HOUR" "$SCHEDULE_TIME_2_MINUTE"
        fi
        if [ -n "$SCHEDULE_TIME_3_HOUR" ] || [ -n "$SCHEDULE_TIME_3_MINUTE" ]; then
            [ -n "$SCHEDULE_TIME_3_HOUR" ] && [ -n "$SCHEDULE_TIME_3_MINUTE" ] || fail "SCHEDULE_TIME_3_HOUR/MINUTE 必须成对配置"
            add_schedule "$SCHEDULE_TIME_3_HOUR" "$SCHEDULE_TIME_3_MINUTE"
        fi
    fi

    [ -n "$SCHEDULE_SUMMARY" ] || fail "至少需要配置一个定时点"
}

check_sources() {
    [ -f "$PROJECT_DIR/autostart.sh" ] || fail "找不到主运行脚本: $PROJECT_DIR/autostart.sh"
    if [ ! -f "$PROJECT_DIR/config.env" ]; then
        if [ -f "$PROJECT_DIR/config.env.example" ]; then
            echo "[Info] 未找到 config.env，已自动从 config.env.example 复制默认配置。"
            cp "$PROJECT_DIR/config.env.example" "$PROJECT_DIR/config.env"
        else
            fail "找不到配置文件: $PROJECT_DIR/config.env"
        fi
    fi
}

generate_plist() {
    PLIST_TMP="$PLIST_DEST.tmp.$$"

    cat > "$PLIST_TMP" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$SECURE_DIR/autostart.sh</string>
    </array>

    <key>StartCalendarInterval</key>
    <array>
$PLIST_INTERVALS    </array>

    <key>WorkingDirectory</key>
    <string>$SECURE_DIR</string>

    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$ERR_FILE</string>

    <key>ExitTimeOut</key>
    <integer>30</integer>
</dict>
</plist>
EOF

    plutil -lint "$PLIST_TMP" >/dev/null
    mv "$PLIST_TMP" "$PLIST_DEST"
}

check_claude_installed() {
    # 临时补充常见 Homebrew/Node 路径以进行检测
    local TMP_PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    if ! PATH="$TMP_PATH" command -v claude >/dev/null 2>&1; then
        echo "=========================================================="
        echo "⚠️  [警告] 检测到系统尚未安装 Claude Code 命令行工具！"
        echo "=========================================================="
        echo "定时任务需要依赖 'claude' 命令行才能正常运行。"
        echo "请先在终端中运行以下命令进行安装："
        echo ""
        echo "    npm install -g @anthropic-ai/claude-code"
        echo ""
        echo "安装完成后，请务必先运行一次 'claude' 完成首次登录授权。"
        echo "=========================================================="
        echo ""
    fi
}

service_loaded() {
    launchctl print "$SERVICE_DOMAIN/$LABEL" >/dev/null 2>&1
}

unload_service() {
    launchctl bootout "$SERVICE_DOMAIN" "$PLIST_DEST" >/dev/null 2>&1 || launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
}

load_service() {
    launchctl bootstrap "$SERVICE_DOMAIN" "$PLIST_DEST" >/dev/null 2>&1 || launchctl load "$PLIST_DEST"
}

start_service() {
    launchctl kickstart -k "$SERVICE_DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl start "$LABEL"
}

stop_service() {
    launchctl kill TERM "$SERVICE_DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl stop "$LABEL" >/dev/null 2>&1 || true
}

case "$1" in
    install)
        check_claude_installed
        check_sources
        load_config "$PROJECT_DIR/config.env"
        build_schedule_config

        echo "正在安装 Claude Code 定时刷新任务..."
        mkdir -p "$SECURE_DIR"
        mkdir -p "$HOME/Library/LaunchAgents"
        chmod 700 "$SECURE_DIR"

        cp "$PROJECT_DIR/autostart.sh" "$SECURE_DIR/autostart.sh"
        cp "$PROJECT_DIR/config.env" "$SECURE_DIR/config.env"
        chmod 755 "$SECURE_DIR/autostart.sh"
        chmod 600 "$SECURE_DIR/config.env"
        touch "$LOG_FILE" "$ERR_FILE"
        chmod 600 "$LOG_FILE" "$ERR_FILE"

        unload_service
        generate_plist
        load_service

        echo "安装完成。"
        echo "定时刷新点: $SCHEDULE_SUMMARY"
        echo "随机延迟上限: ${MAX_RANDOM_DELAY_SECS:-0} 秒"
        echo "运行目录: $SECURE_DIR"
        echo "日志: $LOG_FILE"
        ;;

    uninstall)
        echo "正在卸载 Claude Code 定时刷新任务..."
        unload_service

        if [ -f "$PLIST_DEST" ]; then
            rm -f "$PLIST_DEST"
            echo "已移除 LaunchAgent: $PLIST_DEST"
        fi

        if [ "$SECURE_DIR" = "$HOME/.claude-autostart" ] && [ -d "$SECURE_DIR" ]; then
            rm -rf "$SECURE_DIR"
            echo "已移除运行目录: $SECURE_DIR"
        fi

        echo "卸载完成。"
        ;;

    test-now)
        [ -f "$SECURE_DIR/autostart.sh" ] || fail "尚未安装，请先运行 ./manage.sh install"
        "$SECURE_DIR/autostart.sh" --no-delay
        ;;

    run)
        [ -f "$SECURE_DIR/autostart.sh" ] || fail "尚未安装，请先运行 ./manage.sh install"
        "$SECURE_DIR/autostart.sh"
        ;;

    notify-test)
        [ -f "$PROJECT_DIR/autostart.sh" ] || fail "找不到主运行脚本: $PROJECT_DIR/autostart.sh"
        echo "正在发送测试通知（使用项目目录中的最新脚本）..."
        /bin/zsh "$PROJECT_DIR/autostart.sh" --notify-test
        echo ""
        echo "如果通知中心没有出现通知，请检查："
        echo "  1. 系统设置 → 通知：找到 Script Editor（或 osascript / terminal-notifier），确认“允许通知”已开启。"
        echo "  2. 确认未开启“专注模式 / 勿扰模式”。"
        ;;

    start-service)
        if ! service_loaded; then
            echo "服务尚未加载，正在先安装..."
            "$0" install
        fi
        start_service
        echo "已通过 launchd 触发一次后台刷新。"
        echo "可用 ./manage.sh logs 查看输出。"
        ;;

    stop-service)
        stop_service
        echo "停止信号已发送。"
        ;;

    logs)
        if [ -f "$LOG_FILE" ]; then
            echo "=== 最近 50 行输出日志 ($LOG_FILE) ==="
            tail -n 50 "$LOG_FILE"
        else
            echo "尚未产生输出日志。"
        fi
        ;;

    errlogs)
        if [ -f "$ERR_FILE" ]; then
            echo "=== 最近 50 行错误日志 ($ERR_FILE) ==="
            tail -n 50 "$ERR_FILE"
        else
            echo "尚未产生错误日志。"
        fi
        ;;

    status)
        echo "=== LaunchAgent 状态 ==="
        if service_loaded; then
            echo "状态: 已加载"
            launchctl print "$SERVICE_DOMAIN/$LABEL" | sed -n '1,80p'
        else
            echo "状态: 未加载"
            [ -f "$PLIST_DEST" ] && echo "LaunchAgent 文件存在: $PLIST_DEST"
        fi
        ;;

    *)
        show_help
        ;;
esac
