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

### OpenCode Plugin (auto-installed)

c11 ships a bundled OpenCode plugin that bridges `session.idle`, `permission.asked`, `session.error`, and `session.status` events into c11 notifications and sidebar status updates. This gives OpenCode the same "blue ring + tab highlight + Cmd+Shift+U jump-to-unread" workflow that Claude Code and Codex have.

**Install:**

```bash
c11 skill install --tool opencode
```

This copies:
- The c11 skill bundle into `~/.opencode/skills/`
- The notification plugin into `~/.config/opencode/plugins/c11-notify.js`

OpenCode auto-loads plugins from `~/.config/opencode/plugins/` at startup — no `opencode.json` edit required.

**What the plugin does:**

| OpenCode event | c11 action | Claude Code equivalent |
|---|---|---|
| `session.idle` | `c11 notify "Waiting for input"` + `set-metadata status=idle` | `idle_prompt` matcher |
| `permission.asked` | `c11 notify "Approval needed"` + `set-metadata status="Needs input"` | `permission_prompt` matcher |
| `session.error` | `c11 notify "Session error"` | (no equivalent) |
| `session.status` | `c11 set-metadata status=<value>` | (wrapper-emitted status) |

**Uninstall:**

```bash
c11 skill remove --tool opencode
```

Removes both the skill bundle and the plugin file.

**Manual installation (advanced):**

If you prefer not to use `c11 skill install`, you can create `.config/opencode/plugins/c11-notify.js` manually:

```javascript
export const C11NotifyPlugin = async ({ $ }) => {
  const c11 = async (args) => {
    try { await $`c11 ${args}`; } catch {}
  };
  const notify = (title, body, subtitle) => {
    const args = ["notify", "--title", title];
    if (subtitle) args.push("--subtitle", subtitle);
    if (body) args.push("--body", body);
    return c11(args);
  };
  return {
    event: async ({ event }) => {
      switch (event.type) {
        case "session.idle":
          await notify("OpenCode", "Waiting for input");
          await c11(["set-metadata", "--key", "status", "--value", "idle"]);
          break;
        case "permission.asked":
          await notify("OpenCode", "Approval needed", "Permission");
          await c11(["set-metadata", "--key", "status", "--value", "Needs input"]);
          break;
        case "session.error":
          await notify("OpenCode", "Session error", "Error");
          break;
        case "session.status":
          if (event.properties?.status) {
            await c11(["set-metadata", "--key", "status", "--value", event.properties.status]);
          }
          break;
      }
    },
  };
};
```

## Environment Variables

### Notification Command

The Notification Command runs asynchronously after an authorized macOS banner
is scheduled successfully. Disabling or denying banners also prevents command
delivery. Target IDs make a delivered notice addressable; they do not guarantee
external or phone delivery.

| Variable | Value |
|----------|-------|
| `C11_NOTIFICATION_WORKSPACE_ID` | Originating workspace UUID |
| `C11_NOTIFICATION_TAB_ID` | Originating tab UUID, or an empty string for a workspace-only notice |
| `C11_NOTIFICATION_KIND` | `routine` or `flag` |

Each has an equivalent `CMUX_NOTIFICATION_*` alias with the same value. The
existing `CMUX_NOTIFICATION_TITLE`, `CMUX_NOTIFICATION_SUBTITLE`, and
`CMUX_NOTIFICATION_BODY` text variables remain available. An absent tab replaces
any inherited tab value with the empty string.

Flags appear separately in the enabled menu-bar extra, including flags on
suppressed tabs. Lowering a flag removes its row. Routine mark-all-read and
clear-all actions leave flags in place. Suppressed unflagged completions do not
contribute to the menu-bar extra's attention count.

Claude lifecycle clears belong to the originating tab. Prompt submission,
ordinary tool continuation, eligible session end, and stale-PID cleanup preserve
sibling notices. A PID without a known tab association clears no notices. In
bypass-permissions mode, AskUserQuestion publishes waiting from PreToolUse.
ExitPlanMode publishes waiting in plan or bypass-permissions mode: a session
started with bypass permissions enters plan mode before asking for approval.
Neither requires a later Notification hook; a later notification replaces the
same tab's item.

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
