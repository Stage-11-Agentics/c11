#!/usr/bin/env node
import assert from "node:assert/strict";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

process.env.C11_AGENT_HOOK_CLI = "/bundle/bin/c11";
const pluginPath = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../skills/opencode-plugins/c11-notify.js",
);
const { C11NotifyPlugin } = await import(pathToFileURL(pluginPath));

const calls = [];
const shell = (_strings, command, args) => {
  return {
    quiet: async () => {
      calls.push({ command, args });
    },
  };
};
const hooks = await C11NotifyPlugin({ $: shell });

await hooks["chat.message"]({ sessionID: "ses_root" });
assert.deepEqual(calls.at(-1), {
  command: "/bundle/bin/c11",
  args: ["agent-hook", "working"],
});

await hooks.event({
  event: {
    type: "session.status",
    properties: { sessionID: "ses_root", status: { type: "busy" } },
  },
});
assert(calls.some(({ args }) => args.join(" ") === "agent-hook working"));
assert(calls.some(({ args }) => args.join(" ") === "set-metadata --key status --value busy"));

await hooks.event({
  event: {
    type: "session.idle",
    properties: { sessionID: "ses_root" },
  },
});
assert(calls.some(({ args }) => args.join(" ") === "agent-hook idle"));
assert(calls.some(({ args }) =>
  args.join(" ") ===
  "agent-hook ingest --provider opencode --event result-ready --actor-thread ses_root"
));

await hooks.event({
  event: {
    type: "session.created",
    properties: { info: { id: "ses_child", parentID: "ses_root" } },
  },
});
const beforeChildStatus = calls.length;
await hooks.event({
  event: {
    type: "session.status",
    properties: { sessionID: "ses_child", status: { type: "busy" } },
  },
});
assert.equal(calls.length, beforeChildStatus, "child session must not clobber root liveness");

const duplicate = await C11NotifyPlugin({ $: shell });
assert.deepEqual(duplicate, {}, "duplicate plugin loads must be inert");

console.log("PASS: OpenCode plugin reports root-session lifecycle exactly");
