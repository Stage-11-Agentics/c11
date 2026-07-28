// c11-notify.js — c11 notification + status bridge for OpenCode.
//
// Runtime-loaded by c11's PATH-scoped OpenCode wrapper. Older c11 installs
// may also have a copied plugin under ~/.config/opencode/plugins/; keeping this
// module idempotent preserves compatibility without requiring tenant writes.
//
// Mirrors the Claude Code hook contract:
//   session.idle       → c11 notify "Waiting for input"  (idle_prompt equivalent)
//   permission.asked   → c11 notify "Approval needed"     (permission_prompt equivalent)
//   session.error      → c11 notify "Session error"       (bonus, no Claude equivalent)
//   session.status     → c11 activity + status metadata
//
// The plugin is dependency-free and silently no-ops when c11 is not on
// PATH or the socket is unavailable (e.g. OpenCode running outside c11).

export const C11NotifyPlugin = async ({ $ }) => {
  const loadedKey = Symbol.for("com.stage11.c11.opencode-notify.loaded");
  if (globalThis[loadedKey]) return {};
  globalThis[loadedKey] = true;

  const childSessions = new Set();
  const c11Bin = process.env.C11_AGENT_HOOK_CLI || "c11";

  const c11 = async (args) => {
    try {
      await $`${c11Bin} ${args}`.quiet();
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

  const sessionIDFrom = (properties) =>
    typeof properties?.sessionID === "string" ? properties.sessionID : undefined;

  const statusTypeFrom = (status) => {
    if (typeof status === "string") return status.toLowerCase();
    if (typeof status?.type === "string") return status.type.toLowerCase();
    return undefined;
  };

  const reportActivity = (activity) => c11(["agent-hook", activity]);

  return {
    "chat.message": async ({ sessionID }) => {
      if (!sessionID || !childSessions.has(sessionID)) {
        await reportActivity("working");
      }
    },
    event: async ({ event }) => {
      const properties = event.properties ?? {};
      const sessionID = sessionIDFrom(properties);
      const info = properties.info;
      if (info?.id && info.parentID) {
        childSessions.add(info.id);
      }
      if (sessionID && childSessions.has(sessionID)) {
        return;
      }

      switch (event.type) {
        case "session.created": {
          // Exact-session resume rail (C11-151). Push the new opencode
          // session id to c11's conversation store so a quit+relaunch
          // re-attaches the surface to THIS session via `opencode -s <id>`.
          // Root sessions only — a sub-agent session (parentID set) must
          // not clobber the surface's primary conversation id. opencode
          // session ids are `ses_` + 26-char base62; the c11 CLI
          // revalidates the grammar before storing.
          if (info?.id && !info.parentID) {
            const args = [
              "conversation", "push",
              "--kind", "opencode",
              "--id", info.id,
              "--source", "hook",
              "--state", "alive",
            ];
            if (info.directory) {
              args.push("--cwd", info.directory);
            }
            await c11(args);
          }
          break;
        }
        case "session.idle":
          await reportActivity("idle");
          await notify("OpenCode", "Waiting for input");
          await c11(["set-metadata", "--key", "status", "--value", "idle"]);
          break;
        case "session.status": {
          const status = statusTypeFrom(properties.status);
          if (status) {
            await c11(["set-metadata", "--key", "status", "--value", status]);
          }
          if (status === "idle") {
            await reportActivity("idle");
          } else if (status === "busy" || status === "retry") {
            await reportActivity("working");
          }
          break;
        }
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
