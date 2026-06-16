// c11-notify.js — c11 notification + status bridge for OpenCode.
//
// Auto-installed by `c11 skill install --tool opencode` into
// ~/.config/opencode/plugins/. OpenCode auto-loads plugins from that
// directory at startup — no opencode.json edit required.
//
// Mirrors the Claude Code hook contract:
//   session.idle       → c11 notify "Waiting for input"  (idle_prompt equivalent)
//   permission.asked   → c11 notify "Approval needed"     (permission_prompt equivalent)
//   session.error      → c11 notify "Session error"       (bonus, no Claude equivalent)
//   session.status     → c11 set-metadata status=<value>  (sidebar chip)
//
// The plugin is dependency-free and silently no-ops when c11 is not on
// PATH or the socket is unavailable (e.g. OpenCode running outside c11).

export const C11NotifyPlugin = async ({ $ }) => {
  const c11 = async (args) => {
    try {
      await $`c11 ${args}`;
    } catch {
      // c11 not on PATH, not running, or socket unavailable — no-op.
    }
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
        case "session.status":
          // event.properties.status is the source of truth for the sidebar chip.
          if (event.properties?.status) {
            await c11(["set-metadata", "--key", "status", "--value", event.properties.status]);
          }
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
