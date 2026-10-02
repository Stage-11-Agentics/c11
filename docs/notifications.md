# Notifications

c11 provides a notification panel for AI agents like Claude Code, Codex, and OpenCode. Notifications appear in a dedicated panel and trigger macOS system notifications.

## Quick Start

```bash
# Send a notification (if c11 is available)
command -v c11 &>/dev/null && c11 notify --title "Done" --body "Task complete"

# With fallback to macOS notifications
command -v c11 &>/dev/null && c11 notify --title "Done" --body "Task complete" || osascript -e 'display notification "Task complete" with title "Done"'
```

## Detection

Check if `c11` CLI is available before using it:

```bash
# Shell
if command -v c11 &>/dev/null; then
    c11 notify --title "Hello"
fi

# One-liner with fallback
command -v c11 &>/dev/null && c11 notify --title "Hello" || osascript -e 'display notification "" with title "Hello"'
```

```python
# Python
import shutil
import subprocess

def notify(title: str, body: str = ""):
    if shutil.which("c11"):
        subprocess.run(["c11", "notify", "--title", title, "--body", body])
    else:
        # Fallback to macOS
        subprocess.run(["osascript", "-e", f'display notification "{body}" with title "{title}"'])
```

## CLI Usage

```bash
# Simple notification
c11 notify --title "Build Complete"

# With subtitle and body
c11 notify --title "Claude Code" --subtitle "Permission" --body "Approval needed"

# Notify a specific workspace and tab
c11 notify --title "Done" --workspace 0 --tab 1
```

## Integration Examples

### Claude Code Hooks

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "command -v c11 &>/dev/null && c11 notify --title 'Claude Code' --body 'Waiting for input' || osascript -e 'display notification \"Waiting for input\" with title \"Claude Code\"'"
          }
        ]
      },
      {
        "matcher": "permission_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "command -v c11 &>/dev/null && c11 notify --title 'Claude Code' --subtitle 'Permission' --body 'Approval needed' || osascript -e 'display notification \"Approval needed\" with title \"Claude Code\"'"
          }
        ]
      }
    ]
  }
}
```

### OpenAI Codex

Add to `~/.codex/config.toml`:

```toml
notify = ["bash", "-c", "command -v c11 &>/dev/null && c11 notify --title Codex --body \"$(echo $1 | jq -r '.\"last-assistant-message\" // \"Turn complete\"' 2>/dev/null | head -c 100)\" || osascript -e 'display notification \"Turn complete\" with title \"Codex\"'", "--"]
```

Or create a simple script `~/.local/bin/codex-notify.sh`:

```bash
#!/bin/bash
MSG=$(echo "$1" | jq -r '."last-assistant-message" // "Turn complete"' 2>/dev/null | head -c 100)
command -v c11 &>/dev/null && c11 notify --title "Codex" --body "$MSG" || osascript -e "display notification \"$MSG\" with title \"Codex\""
```

Then use:
```toml
notify = ["bash", "~/.local/bin/codex-notify.sh"]
```

### OpenCode runtime plugin

c11's bundled PATH wrapper loads `c11-notify.js` for interactive OpenCode
processes inside a live c11 terminal. It bridges lifecycle events into c11
notifications, status and exact-session resume without writing tenant config.

| OpenCode event | c11 action |
|---|---|
| `session.idle` | Waiting-for-input notification and idle status |
| `permission.asked` | Approval-needed notification |
| `session.error` | Session-error notification |
| `session.status` | Loop-status update |

The wrapper uses `OPENCODE_CONFIG_CONTENT` when free. If that is already set,
it preserves the value and uses a process-owned `/dev/fd/3` config through
`OPENCODE_CONFIG` when that slot is free. When both slots are occupied, it
preserves both and continues without injecting the bundled plugin. Outside c11,
or when the socket is unreachable, the wrapper transparently executes OpenCode.

`c11 skill install --tool opencode` installs only skills in `~/.opencode/skills/`.
`c11 skill remove --tool opencode` removes only c11-installed skills. Neither
operation creates, updates or deletes `~/.config/opencode/plugins/`.

Older releases may have copied `c11-notify.js` and `c11-notify.c11-plugin.json`
into that directory. These files remain untouched, including operator edits.
An old copy may load alongside the runtime plugin; duplicate loading is not
claimed eliminated. To retire an old copy, the operator can inspect and back up
both files, then manually remove them if appropriate. A filename or marker alone
does not establish that an edited plugin is safe to delete.

## Environment Variables

c11 sets these in child shells:

| Variable | Description |
|----------|-------------|
| `C11_SOCKET_PATH` | Path to control socket |
| `C11_WORKSPACE_ID` | UUID of the current workspace |
| `C11_TAB_ID` | UUID of the current tab |

## CLI Commands

```
c11 notify --title <text> [--subtitle <text>] [--body <text>] [--workspace <id|index>] [--tab <id|index>]
c11 list-notifications
c11 clear-notifications
c11 ping
```

## Best Practices

1. **Always check availability first** - Use `command -v c11` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
