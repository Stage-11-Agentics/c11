#!/usr/bin/env node
import assert from "node:assert/strict";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";

// Executable producer boundary: capture what the plugin puts on stdin, never its source shape.
const temporary = mkdtempSync(path.join(tmpdir(), "c11-opencode-journal-"));
const fakeCLI = path.join(temporary, "c11");
const log = path.join(temporary, "events.ndjson");
writeFileSync(log, "");
writeFileSync(fakeCLI, `#!${process.execPath}\nimport fs from 'node:fs';
const input = fs.readFileSync(0, 'utf8');
fs.appendFileSync(${JSON.stringify(log)}, input + '\\n');
if (process.env.JOURNAL_TEST_FAILURE) { console.error(process.env.JOURNAL_TEST_FAILURE); process.exit(1); }
const draft = JSON.parse(input);
console.log(JSON.stringify({event_id: draft.event_id.toUpperCase(), sequence: 1, replayed: false}));\n`, { mode: 0o700 });
process.env.C11_AGENT_HOOK_CLI = fakeCLI;
process.env.C11_TAB_ID = "11111111-1111-4111-8111-111111111111";
process.env.C11_WORKSPACE_ID = "22222222-2222-4222-8222-222222222222";
const events = () => readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const pluginPath = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../skills/opencode-plugins/c11-notify.js");
try {
  const { C11NotifyPlugin } = await import(pathToFileURL(pluginPath));
  const calls = [];
  const shell = (_strings, command, args) => ({ quiet: async () => { calls.push({ command, args }); } });
  const hooks = await C11NotifyPlugin({ $: shell });
  await hooks.event({ event: { type: "session.created", properties: { info: { id: "ses_root", directory: "/synthetic" } } } });
  assert(calls.some(({ args }) => args.join(" ").includes("conversation push --kind opencode --id ses_root")));
  assert.equal(events().at(-1).kind, "agent.session.started");
  await hooks["chat.message"]({ sessionID: "ses_root" });
  assert.equal(events().at(-1).kind, "agent.turn.started");
  assert.equal(events().at(-1).native_event, "chat.message");
  await hooks.event({ event: { type: "session.status", properties: { sessionID: "ses_root", status: { type: "busy" } } } });
  assert.equal(events().at(-1).signal, "tool_activity");
  assert.equal(events().at(-1).kind, "agent.state.changed");
  await hooks.event({ event: { type: "permission.asked", properties: { sessionID: "ses_root", id: "ask-1", body: "PRIVATE-SENTINEL" } } });
  assert.equal(events().at(-1).kind, "agent.approval.requested");
  assert.equal(events().at(-1).request_id, "ask-1");
  await hooks.event({ event: { type: "session.error", properties: { sessionID: "ses_root", error: { message: "PRIVATE-SENTINEL" } } } });
  assert.equal(events().at(-1).reason_code, "session_failure");
  await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_root" } } });
  assert.equal(events().at(-1).kind, "agent.turn.completed");
  assert(!calls.some(({ args }) => args[0] === "agent-hook"), "append and legacy must not both write activity");
  assert(calls.some(({ args }) => args[0] === "rpc" && args[1] === "feed.note_display" && String(args[2]).includes("PRIVATE-SENTINEL")));
  assert(!readFileSync(log, "utf8").includes("PRIVATE-SENTINEL"));
  assert(!readFileSync(log, "utf8").includes("/synthetic"));
  assert.equal(new Set(events().map(event => event.event_id)).size, events().length);

  await hooks.event({ event: { type: "session.created", properties: { info: { id: "ses_child", parentID: "ses_root" } } } });
  const beforeChild = [calls.length, events().length];
  await hooks.event({ event: { type: "session.status", properties: { sessionID: "ses_child", status: { type: "busy" } } } });
  await hooks["chat.message"]({ sessionID: "ses_child" });
  assert.deepEqual([calls.length, events().length], beforeChild, "child callbacks must not clobber root");

  process.env.JOURNAL_TEST_FAILURE = "storage_unavailable";
  const beforeFailedPermission = calls.length;
  await hooks.event({ event: { type: "permission.asked", properties: { sessionID: "ses_root", id: "ask-failed", body: "MUST-NOT-LEAK" } } });
  assert(!calls.slice(beforeFailedPermission).some(({ args }) => args[0] === "rpc" && args[1] === "feed.note_display"), "uncommitted append must not send a display note");
  await hooks["chat.message"]({ sessionID: "ses_root" });
  assert(!calls.some(({ args }) => args[0] === "agent-hook"), "ambiguous failure must not use legacy");
  process.env.JOURNAL_TEST_FAILURE = "method_not_found";
  await hooks["chat.message"]({ sessionID: "ses_root" });
  assert.equal(calls.at(-1).args.join(" "), "agent-hook working");
  assert.deepEqual(await C11NotifyPlugin({ $: shell }), {}, "duplicate plugin loads must be inert");
  console.log("PASS: structural root events, child isolation, privacy and explicit-only legacy fallback");
} finally {
  delete process.env.JOURNAL_TEST_FAILURE;
  rmSync(temporary, { recursive: true, force: true });
}
