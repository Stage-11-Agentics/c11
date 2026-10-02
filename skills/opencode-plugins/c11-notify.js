import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

// c11-notify.js — c11 notification + status bridge for OpenCode.
//
// Runtime-loaded by c11's PATH-scoped OpenCode wrapper. Older c11 installs
// may also have a copied plugin under ~/.config/opencode/plugins/. New skill
// installs/removals leave those tenant files untouched; operator cleanup is
// optional. An older copy may still load alongside this runtime module.
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

  // Structural append shares the CLI's 250 ms delivery/spool budget. Bodies,
  // directories and process provenance never enter this event.
  const append = async (kind, nativeEvent, sessionID, extra = {}, legacyActivity) => {
    const tab = process.env.C11_TAB_ID || process.env.CMUX_SURFACE_ID;
    const workspace = process.env.C11_WORKSPACE_ID || process.env.CMUX_WORKSPACE_ID;
    const draft = {
      schema_version: 1, event_id: randomUUID(), kind, emitted_at_ms: Date.now(),
      tab_id: tab && workspace ? tab : null, workspace_id: tab && workspace ? workspace : null,
      session_id: sessionID || null, agent_kind: "opencode", source: "plugin",
      adapter: "opencode_plugin", native_event: nativeEvent, ...extra,
    };
    const unsupported = await new Promise((resolve) => {
      const child = spawn(c11Bin, ["agent-event", "append", "--stdin"], { stdio: ["pipe", "ignore", "pipe"] });
      let error = "";
      const timer = setTimeout(() => { child.kill(); resolve(false); }, 750);
      child.stderr.on("data", (chunk) => { if (error.length < 4096) error += chunk.toString(); });
      child.on("error", () => { clearTimeout(timer); resolve(false); });
      child.on("close", () => { clearTimeout(timer); resolve(error.includes("method_not_found")); });
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify(draft));
    });
    if (unsupported && legacyActivity) await c11(["agent-hook", legacyActivity]);
  };

  return {
    "chat.message": async ({ sessionID }) => {
      if (!sessionID || !childSessions.has(sessionID)) {
        await append("agent.turn.started", "chat.message", sessionID, {}, "working");
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
          // re-attaches the tab to THIS session via `opencode -s <id>`.
          // Root sessions only — a sub-agent session (parentID set) must
          // not clobber the tab's primary conversation id. opencode
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
            await append("agent.session.started", "session.created", info.id);
          }
          break;
        }
        case "session.idle":
          await append("agent.turn.completed", event.type, sessionID, {}, "idle");
          await notify("OpenCode", "Waiting for input");
          await c11(["set-metadata", "--key", "status", "--value", "idle"]);
          break;
        case "session.status": {
          const status = statusTypeFrom(properties.status);
          if (status) {
            await c11(["set-metadata", "--key", "status", "--value", status]);
          }
          if (status === "idle") {
            await append("agent.turn.completed", event.type, sessionID, {}, "idle");
          } else if (status === "busy" || status === "retry") {
            await append("agent.state.changed", event.type, sessionID, { signal: "tool_activity" }, "working");
          }
          break;
        }
        case "permission.asked":
          await append("agent.approval.requested", event.type, sessionID, { request_id: typeof properties.id === "string" ? properties.id : null });
          await notify("OpenCode", "Approval needed", "Permission");
          await c11(["set-metadata", "--key", "status", "--value", "Needs input"]);
          break;
        case "session.error":
          await append("agent.error.reported", event.type, sessionID, { reason_code: "session_failure" });
          await notify("OpenCode", "Session error", "Error");
          break;
      }
    },
  };
};
