#!/usr/bin/env node
// omp native mailbox consumer (C11-473). Drives Resources/bin/omp-native-mail.ts
// through a fake omp extension API against a real Unix socket speaking c11's
// `mailbox.native.subscribe` stream. Run it with Bun, or a Node that strips
// TypeScript types (22.18+).
import assert from "node:assert/strict";
import { createServer } from "node:net";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const bin = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../Resources/bin");
const { default: extension } = await import(pathToFileURL(path.join(bin, "omp-native-mail.ts")));
const DOORBELL = "You have mail: run c11 mailbox recv --ack when you want to receive it.";
const PANEL = "11111111-1111-4111-8111-111111111111";

async function until(predicate, label) {
  const deadline = Date.now() + 3000;
  while (!predicate()) {
    assert(Date.now() < deadline, "timed out: " + label);
    await delay(5);
  }
}

// A c11 stand-in: records frames, answers the subscribe, pushes deliveries.
async function server() {
  const root = await mkdtemp("/tmp/c11-omp-native-test-");
  const socketPath = root + "/mail.sock";
  const frames = [];
  const sockets = [];
  const listener = createServer((socket) => {
    sockets.push(socket);
    socket.on("error", () => {});
    let input = "";
    socket.on("data", (chunk) => {
      input += chunk.toString("utf8");
      let end;
      while ((end = input.indexOf("\n")) >= 0) {
        const frame = JSON.parse(input.slice(0, end));
        input = input.slice(end + 1);
        frames.push(frame);
        if (frame.method === "mailbox.native.subscribe") {
          socket.write(JSON.stringify({ id: frame.id, ok: true, result: { subscription_id: "sub" } }) + "\n");
        }
      }
    });
  });
  await new Promise((resolve) => listener.listen(socketPath, resolve));
  const subscribes = () => frames.filter((frame) => frame.method === "mailbox.native.subscribe");
  return {
    socketPath, frames, subscribes,
    deliver: (id) => sockets.at(-1).write(JSON.stringify({ type: "deliver", delivery_id: id, text: DOORBELL }) + "\n"),
    answers: (id) => frames.filter((frame) => frame.delivery_id === id),
    close: async () => { sockets.forEach((socket) => socket.destroy()); await new Promise((r) => listener.close(r)); await rm(root, { recursive: true, force: true }); },
  };
}

// The omp extension host: handlers by event, recorded exec and sendMessage calls.
function host({ idle = true } = {}) {
  const handlers = new Map();
  const state = { idle, sent: [], exec: [] };
  const api = {
    on: (event, handler) => handlers.set(event, [...(handlers.get(event) ?? []), handler]),
    exec: (command, args) => { state.exec.push({ command, args }); return Promise.resolve({}); },
    sendMessage: (message, options) => { state.sent.push({ message, options }); },
  };
  const ctx = { hasUI: true, isIdle: () => state.idle };
  const emit = async (event, payload = {}, context = ctx) => {
    for (const handler of handlers.get(event) ?? []) await handler({ type: event, ...payload }, context);
  };
  const activity = () => state.exec.map(({ args }) => args.at(-1));
  return { api, ctx, state, emit, activity };
}

async function withEnv(values, body) {
  const keys = ["C11_AGENT_HOOK_CLI", "C11_SOCKET_PATH", "CMUX_SOCKET_PATH", "C11_PANEL_ID", "C11_AGENT_INTERACTIVE_PID", "C11_OMP_NATIVE_MAIL_DISABLED"];
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  for (const key of keys) delete process.env[key];
  Object.assign(process.env, values);
  try { return await body(); } finally {
    for (const key of keys) { if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key]; }
  }
}
const env = (srv, extra = {}) => ({
  C11_AGENT_HOOK_CLI: "/fake/c11", C11_SOCKET_PATH: srv.socketPath, C11_PANEL_ID: PANEL,
  C11_AGENT_INTERACTIVE_PID: String(process.pid), ...extra,
});
const doorbell = (overrides = {}) => ({ message: { role: "custom", customType: "c11-mailbox-doorbell", content: DOORBELL, ...overrides } });

const srv = await server();
// The extension writes no file anywhere under HOME (so nothing under ~/.omp).
const home = await mkdtemp("/tmp/c11-omp-native-home-");
process.env.HOME = home;
// Reconnect timers of a failed run must not keep the process alive.
let failed = true;
try {
  // 1. Idle: a custom message that triggers a turn, accepted only by omp's own
  //    message_start carrying the exact text.
  await withEnv(env(srv), async () => {
    const omp = host();
    extension(omp.api);
    await omp.emit("session_start");
    await until(() => srv.subscribes().length === 1, "subscribe");
    const subscribe = srv.subscribes()[0].params;
    assert.deepEqual(
      { ...subscribe, session_id: typeof subscribe.session_id },
      { panel_id: PANEL, agent_pid: process.pid, session_id: "string", route: "omp_extension", can_queue: false },
    );
    assert.deepEqual(omp.activity(), ["idle"], "session start publishes idle");

    srv.deliver("D1");
    await until(() => omp.state.sent.length === 1, "idle delivery calls omp");
    assert.deepEqual(omp.state.sent[0], {
      message: { customType: "c11-mailbox-doorbell", content: DOORBELL, display: true },
      options: { triggerTurn: true },
    });
    await delay(60);
    assert.equal(srv.answers("D1").length, 0, "calling the API is not acceptance");
    // The same words as a user message, or another custom type, are not the ack.
    await omp.emit("message_start", { message: { role: "user", content: DOORBELL } });
    await omp.emit("message_start", doorbell({ customType: "other" }));
    await delay(60);
    assert.equal(srv.answers("D1").length, 0, "only the doorbell custom message accepts");
    await omp.emit("message_start", doorbell());
    await until(() => srv.answers("D1").length === 1, "accepted");
    assert.deepEqual(srv.answers("D1")[0], { type: "accepted", delivery_id: "D1" });
    await omp.emit("session_shutdown");
  });

  // 2. Busy: rejected before any side effect, so no AgentBusyError reaches the UI.
  await withEnv(env(srv), async () => {
    const omp = host({ idle: false });
    extension(omp.api);
    await omp.emit("session_start");
    await until(() => srv.subscribes().length === 2, "second subscribe");
    srv.deliver("D2");
    await until(() => srv.answers("D2").length === 1, "busy answer");
    assert.deepEqual(srv.answers("D2")[0], { type: "rejected", delivery_id: "D2" });
    assert.equal(omp.state.sent.length, 0, "a busy agent is never sent the doorbell");
    await omp.emit("session_shutdown");
  });

  // 2b. A turn that began an instant before the request settles inside the
  //     wait: delivered, not rejected.
  await withEnv(env(srv), async () => {
    const omp = host({ idle: false });
    extension(omp.api);
    await omp.emit("session_start");
    await until(() => srv.subscribes().length === 3, "subscribe for the settling turn");
    srv.deliver("D2b");
    setTimeout(() => { omp.state.idle = true; }, 100);
    await until(() => omp.state.sent.length === 1, "delivered once idle");
    await omp.emit("message_start", doorbell());
    await until(() => srv.answers("D2b").length === 1, "accepted after settling");
    assert.deepEqual(srv.answers("D2b")[0], { type: "accepted", delivery_id: "D2b" });
    await omp.emit("session_shutdown");
  });

  // 3. /new rebinds with a fresh session id and publishes idle.
  await withEnv(env(srv), async () => {
    const omp = host();
    extension(omp.api);
    await omp.emit("session_start");
    await until(() => srv.subscribes().length === 4, "fourth subscribe");
    const first = srv.subscribes()[3].params.session_id;
    await omp.emit("session_switch", { reason: "new" });
    await until(() => srv.subscribes().length === 5, "rebind");
    assert.notEqual(srv.subscribes()[4].params.session_id, first);
    assert.deepEqual(omp.activity(), ["idle", "idle"], "the new session is at an idle prompt");
    await omp.emit("session_shutdown");
  });

  // 3b. A delivery still waiting for its acknowledgement when the session
  //     switches is stale: the new session's events cannot accept it.
  await withEnv(env(srv), async () => {
    const omp = host();
    const before = srv.subscribes().length;
    extension(omp.api);
    await omp.emit("session_start");
    await until(() => srv.subscribes().length === before + 1, "subscribed");
    const count = before + 1;
    srv.deliver("D3b");
    await until(() => omp.state.sent.length === 1, "called omp");
    await omp.emit("session_switch", { reason: "new" });
    await until(() => srv.subscribes().length === count + 1, "rebound");
    await omp.emit("message_start", doorbell());
    await delay(80);
    assert.equal(srv.answers("D3b").length, 0, "a stale delivery is never accepted by the next session");
    await omp.emit("session_shutdown");
  });

  // 4. Lifecycle edges: working at agent_start; idle only once omp's isIdle()
  //    is true, because agent_end fires before it flips.
  await withEnv(env(srv), async () => {
    const omp = host();
    extension(omp.api);
    await omp.emit("agent_start");
    omp.state.idle = false;
    setTimeout(() => { omp.state.idle = true; }, 30);
    await omp.emit("agent_end");
    assert.deepEqual(omp.activity(), ["working", "idle"]);
    assert.equal(omp.state.idle, true, "idle was published only after isIdle() turned true");
    assert.deepEqual(omp.state.exec[0], { command: "/fake/c11", args: ["--socket", srv.socketPath, "agent-hook", "working"] });
  });

  // 5. Task subagents (hasUI false) neither subscribe nor report lifecycle.
  await withEnv(env(srv), async () => {
    const omp = host();
    const before = srv.subscribes().length;
    extension(omp.api);
    const subagent = { hasUI: false, isIdle: () => true };
    await omp.emit("session_start", {}, subagent);
    await omp.emit("agent_start", {}, subagent);
    await omp.emit("agent_end", {}, subagent);
    await delay(60);
    assert.equal(srv.subscribes().length, before);
    assert.deepEqual(omp.activity(), []);
  });

  // 6. No stream without the interactive PID marker or with the kill switch;
  //    lifecycle still reports. Nothing happens outside c11.
  for (const extra of [{ C11_AGENT_INTERACTIVE_PID: String(process.pid + 1) }, { C11_OMP_NATIVE_MAIL_DISABLED: "1" }]) {
    await withEnv(env(srv, extra), async () => {
      const omp = host();
      const before = srv.subscribes().length;
      extension(omp.api);
      await omp.emit("session_start");
      await delay(60);
      assert.equal(srv.subscribes().length, before, JSON.stringify(extra));
      assert.deepEqual(omp.activity(), ["idle"]);
    });
  }
  await withEnv({}, async () => {
    const omp = host();
    extension(omp.api);
    assert.equal(omp.state.exec.length, 0);
    await omp.emit("session_start");
    assert.deepEqual(omp.activity(), []);
  });
  assert.deepEqual(await readdir(home), [], "the extension must write nothing under HOME");
  failed = false;
  console.log("PASS: omp native mail consumer");
} catch (error) {
  console.error("FAIL: " + (error?.stack ?? error));
} finally {
  await srv.close();
  await rm(home, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}
