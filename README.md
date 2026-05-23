# Claude Code 定时刷新工具

这个项目用于在 macOS 上按指定时间点自动执行一次 Claude Code：

```bash
claude -p "Hi"
```

用途是按你的时间安排开启/刷新 Claude 的 5 小时使用窗口。它使用用户级 `LaunchAgent`，不会申请 root 权限，也不会安装系统级服务。

## 使用方式

### 1. 修改刷新时间

编辑 `config.env`：

```bash
SCHEDULE_TIMES="08:30,14:00,19:10"
```

多个时间点用英文逗号分隔，格式为 `HH:MM`。时间使用本机当前时区。

### 2. 安装或更新定时任务

```bash
./manage.sh install
```

每次修改 `config.env` 后，都需要重新运行一次 `./manage.sh install`，这样新的时间点才会写入 macOS LaunchAgent。

### 3. 立即测试一次

```bash
./manage.sh test-now
```

这会跳过随机延迟，直接执行一次 `claude -p`。

### 4. 查看状态和日志

```bash
./manage.sh status
./manage.sh logs
./manage.sh errlogs
```

### 5. 卸载

```bash
./manage.sh uninstall
```

卸载会移除：

- `~/Library/LaunchAgents/com.jiaweili.claude-autostart.plist`
- `~/.claude-autostart`

## 配置项

```bash
SCHEDULE_TIMES="08:30,14:00,19:10"
MAX_RANDOM_DELAY_SECS=300
REFRESH_MESSAGE="Hi"
TARGET_WORKSPACE="$HOME/.claude-autostart"
ENABLE_NOTIFICATIONS=true
```

- `SCHEDULE_TIMES`: 定时执行点。
- `MAX_RANDOM_DELAY_SECS`: 到点后的随机延迟上限。设为 `0` 表示不延迟。
- `REFRESH_MESSAGE`: 发送给 Claude 的最短提示，建议保持简短以减少额度消耗。
- `TARGET_WORKSPACE`: Claude 执行时所在目录，默认使用 `~/.claude-autostart`。
- `ENABLE_NOTIFICATIONS`: 是否在发送刷新消息、刷新成功/失败时向 macOS 通知中心推送通知。`true` 启用，`false` 关闭。

## 通知功能

启用后，每次定时刷新都会向 macOS 通知中心推送通知：

- 发送刷新消息时：提示「正在向 Claude 发送刷新消息...」
- 收到结果时：提示刷新成功或失败。

通知发送方式（自动选择，无需额外配置）：

1. 如果系统装有 `terminal-notifier`，优先用它发送（注册为正规通知 App，后台运行最稳定）。
2. 否则回退到 macOS 自带的 `osascript`。

> **重要：改完 `config.env` 或脚本后，必须重新运行 `./manage.sh install`。**
> 定时任务实际执行的是同步到 `~/.claude-autostart` 的副本，不是项目目录里的文件。
> 如果只改了项目里的文件却没重新 `install`，通知设置不会生效——这也是通知中心收不到通知的最常见原因。

### 测试通知

不想等定时点也能单独测通知：

```bash
./manage.sh notify-test
```

这会立即发送一条测试通知。如果通知中心仍然看不到，请检查：

- **系统设置 → 通知**：找到 `Script Editor`（或 `osascript` / `terminal-notifier`），确认「允许通知」已开启。
- 确认没有开启「专注模式 / 勿扰模式」。
- 用 `./manage.sh logs` 查看日志中 `[Notify]` 开头的记录，确认发送结果。

## 安全说明

这个工具只做三件事：

- 把 `autostart.sh` 和 `config.env` 同步到 `~/.claude-autostart`
- 生成用户级 LaunchAgent 定时任务
- 到点执行一次 `claude -p "$REFRESH_MESSAGE"`

安全改动：

- 不再用 `source config.env`，配置文件只按白名单键值读取，避免配置文件里夹带 shell 命令被执行。
- `~/.claude-autostart` 权限设为 `700`，`config.env` 和日志设为 `600`。
- 增加运行锁，避免同一时间重复触发导致多个 Claude 进程并发。
- 安装时根据 `SCHEDULE_TIMES` 生成 LaunchAgent，配置里的时间会真正生效。

注意：这不是 macOS 系统级沙箱。任务仍然以你的当前用户身份运行，因此只建议在你信任并能控制的机器上使用。
