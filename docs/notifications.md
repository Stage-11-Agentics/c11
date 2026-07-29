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

# Notify specific tab/panel
c11 notify --title "Done" --tab 0 --panel 1
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

c11 ships a bundled OpenCode plugin that bridges `session.idle`, `permission.asked`, and `session.error` events into c11 notifications. This gives OpenCode the same "blue ring + tab highlight + Cmd+Shift+U jump-to-unread" workflow that Claude Code and Codex have.

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
| `session.idle` | `c11 notify "Waiting for input"` + `clear-metadata status` | `idle_prompt` matcher |
| `permission.asked` | `c11 notify "Approval needed"` + `set-metadata status="Needs input"` | `permission_prompt` matcher |
| `session.error` | `c11 notify "Session error"` | (no equivalent) |

The sidebar's live state comes from c11's own derived `activity`, which tracks
the surface continuously. The plugin writes the `status` key only for "Needs
input" — a state c11 cannot see from the outside — and clears it on idle. It
deliberately does not mirror OpenCode's `session.status` event: that fires only
at turn boundaries, so a mid-turn surface would read `activity = working`
beside a contradicting `status = idle`.

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
    // `.quiet()` keeps the CLI's stdout out of the PTY, where it would
    // interleave with OpenCode's TUI render and garble the frame.
    try { await $`c11 ${args}`.quiet(); } catch {}
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
          await c11(["clear-metadata", "--key", "status"]);
          break;
        case "permission.asked":
          await notify("OpenCode", "Approval needed", "Permission");
          await c11(["set-metadata", "--key", "status", "--value", "Needs input"]);
          break;
        case "session.error":
          await notify("OpenCode", "Session error", "Error");
          break;
      }
    },
  };
};
```

## Environment Variables

c11 sets these in child shells:

| Variable | Description |
|----------|-------------|
| `C11_SOCKET_PATH` | Path to control socket |
| `C11_TAB_ID` | UUID of the current tab |
| `C11_PANEL_ID` | UUID of the current panel |
| `C11_SURFACE_ID` | UUID of the current surface |

> **Backwards compatibility:** `CMUX_SOCKET_PATH`, `CMUX_TAB_ID`, `CMUX_PANEL_ID`, and `CMUX_SURFACE_ID` are also accepted as aliases. c11 mirrors both env var namespaces at startup.

## CLI Commands

```
c11 notify --title <text> [--subtitle <text>] [--body <text>] [--tab <id|index>] [--panel <id|index>]
c11 list-notifications
c11 clear-notifications
c11 ping
```

## Best Practices

1. **Always check availability first** - Use `command -v c11` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
