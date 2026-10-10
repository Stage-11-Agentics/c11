#!/usr/bin/env node
// Prompt cache reports from c11's runtime extensions for Pi and omp (C11-382).
// Drives each extension through a fake extension API and checks the exact
// `c11 rpc agent.prompt_cache.report` payloads it would send. Run it with Bun,
// or a Node that strips TypeScript types (22.18+).
import assert from "node:assert/strict";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const bin = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../Resources/bin");
const { default: piExtension } = await import(pathToFileURL(path.join(bin, "pi-lifecycle.ts")));
const ompModule = await import(pathToFileURL(path.join(bin, "omp-prompt-cache.ts")));
const ompExtension = ompModule.default;

const PANEL = "11111111-1111-4111-8111-111111111111";
const SOCKET = "/tmp/c11-test.sock";

function fakeHost(version) {
  const handlers = new Map();
  const calls = [];
  const api = {
    on: (event, handler) => handlers.set(event, handler),
    exec: (command, args, options) => {
      calls.push({ command, args, options });
      return Promise.resolve({ stdout: "", stderr: "", code: 0, killed: false });
    },
  };
  if (version !== undefined) api.pi = { VERSION: version };
  const reports = () => calls
    .filter(({ args }) => args.includes("agent.prompt_cache.report"))
    .map(({ args }) => {
      assert.deepEqual(args.slice(0, 4), ["--socket", SOCKET, "rpc", "agent.prompt_cache.report"]);
      return JSON.parse(args[4]);
    });
  return { api, handlers, calls, reports };
}

async function withEnv(values, body) {
  const keys = ["C11_AGENT_HOOK_CLI", "CMUX_SOCKET_PATH", "C11_PANEL_ID", "C11_TAB_ID", "CMUX_SURFACE_ID", "PI_CACHE_RETENTION"];
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  for (const key of keys) delete process.env[key];
  Object.assign(process.env, values);
  try { return await body(); } finally {
    for (const key of keys) {
      if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key];
    }
  }
}

const baseEnv = { C11_AGENT_HOOK_CLI: "/fake/c11", CMUX_SOCKET_PATH: SOCKET, C11_PANEL_ID: PANEL };
const assistant = (usage, extra = {}) => ({
  message: {
    role: "assistant", api: "anthropic-messages", provider: "anthropic", model: "claude-opus-4-8",
    timestamp: 1_790_000_000_000, usage, content: [{ type: "text", text: "PRIVATE-SENTINEL" }], ...extra,
  },
});

// ---- Pi ---------------------------------------------------------------------
await withEnv(baseEnv, async () => {
  const host = fakeHost();
  piExtension(host.api);
  for (const event of ["agent_start", "agent_settled", "message_end", "cache_warming_decision", "session_compact",
    "model_select", "thinking_level_select", "session_start"]) {
    assert(host.handlers.has(event), `pi registers ${event}`);
  }
  const end = host.handlers.get("message_end");

  await end(assistant({ input: 12, output: 40, cacheRead: 0, cacheWrite: 9_000, cacheWrite1h: 9_000 }));
  await end(assistant({ input: 5, output: 40, cacheRead: 9_000, cacheWrite: 0 }, { timestamp: 1_790_000_060_000 }));
  await end(assistant({ input: 5, output: 40, cacheRead: 9_000, cacheWrite: 300, cacheWrite1h: 0 }, { timestamp: 1_790_000_120_000 }));
  await end({ message: { role: "user", content: "PRIVATE-SENTINEL", timestamp: 1 } });
  await end(assistant({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, { stopReason: "error" }));
  await end(assistant({ input: 70, output: 9, cacheRead: 2_000, cacheWrite: 0 },
    { api: "openai-responses", provider: "openai", model: "gpt-5.6", timestamp: 1_790_000_180_000 }));

  await end(assistant({ input: 40, output: 9, cacheRead: 3_000, cacheWrite: 10 },
    { provider: "kimi-coding", model: "k3", timestamp: 1_790_000_240_000 }));
  await end(assistant({ input: 40, output: 9, cacheRead: 3_000, cacheWrite: 10 },
    { api: "openai-completions", provider: "github-copilot", model: "claude-sonnet-4.5", timestamp: 1_790_000_300_000 }));
  await end(assistant({ input: 40, output: 9, cacheRead: 3_000, cacheWrite: 0 },
    { api: "openai-completions", provider: "openrouter", model: "anthropic/claude-sonnet-4.5", timestamp: 1_790_000_360_000 }));
  await end(assistant({ input: 40, output: 9, cacheRead: 3_000, cacheWrite: 0 },
    { provider: "opencode", model: "claude-sonnet-4-5", timestamp: 1_790_000_420_000 }));

  const reports = host.reports();
  assert.equal(reports.length, 8, "user lines and requests that never reached the provider are not reported");
  assert(host.calls.every(({ options }) => options?.timeout >= 5000), "a slow c11 still gets the report");
  assert.deepEqual(reports[0], {
    panel_id: PANEL,
    request: {
      at_ms: 1_790_000_000_000, input_tokens: 12, cache_read_tokens: 0, cache_write_tokens: 9_000,
      provider: "anthropic", model: "claude-opus-4-8", ttl_seconds: 3600,
    },
  });
  assert.equal(reports[1].request.ttl_seconds, 3600, "a pure read keeps the tier the last write named");
  assert.equal(reports[2].request.ttl_seconds, 300, "a request with a 5-minute write is a 5-minute cache");
  assert.equal(reports[3].request.ttl_seconds, undefined, "c11's policy table decides a non-Anthropic lifetime");
  assert.equal(reports[3].request.provider, "openai");
  assert.equal(reports[4].request.ttl_seconds, undefined, "another provider on the anthropic-messages API caches implicitly");
  assert.equal(reports[5].request.ttl_seconds, undefined, "Copilot's Claude is not Anthropic's cache");
  assert.equal(reports[6].request.ttl_seconds, 300, "OpenRouter's anthropic/ models are");
  assert.equal(reports[7].request.ttl_seconds, 300, "a bare claude- id on a pass-through backend is too");
  assert(!JSON.stringify(host.calls).includes("PRIVATE-SENTINEL"), "no message text leaves Pi");

  const decide = host.handlers.get("cache_warming_decision");
  assert.equal(await decide({ type: "cache_warming_decision", action: "stop" }), undefined);
  assert.equal(host.reports().length, 8, "a refresh that is not sent changes nothing");
  const beforeWarm = Date.now();
  assert.equal(await decide({ type: "cache_warming_decision", action: "warm" }), undefined,
    "the extension never overrides the warmer's decision");
  const warm = host.reports().at(-1);
  assert.deepEqual(Object.keys(warm.request), ["at_ms"], "a refresh is a request without usage");
  assert(warm.request.at_ms >= beforeWarm);

  await host.handlers.get("session_compact")({ type: "session_compact", reason: "manual" });
  assert.equal(host.reports().at(-1).reset.reason, "compaction");
  const select = host.handlers.get("model_select");
  const before = host.reports().length;
  await select({ model: { provider: "anthropic", id: "claude-opus-4-8" }, previousModel: undefined });
  await select({ model: { provider: "anthropic", id: "claude-opus-4-8" }, previousModel: { provider: "anthropic", id: "claude-opus-4-8" } });
  assert.equal(host.reports().length, before, "the first model and a re-selection reset nothing");
  await select({ model: { provider: "anthropic", id: "claude-sonnet-4-5" }, previousModel: { provider: "anthropic", id: "claude-opus-4-8" } });
  assert.deepEqual(Object.keys(host.reports().at(-1)), ["reset", "panel_id"]);
  assert.equal(host.reports().at(-1).reset.reason, "model_switch");

  const thinking = host.handlers.get("thinking_level_select");
  const beforeThinking = host.reports().length;
  await thinking({ type: "thinking_level_select", level: "high", previousLevel: "high" });
  assert.equal(host.reports().length, beforeThinking, "an unchanged level resets nothing");
  await thinking({ type: "thinking_level_select", level: "high", previousLevel: "low" });
  assert.equal(host.reports().at(-1).reset.reason, "effort_change", "the last request was Anthropic's");

  const start = host.handlers.get("session_start");
  const beforeStart = host.reports().length;
  await start({ type: "session_start", reason: "startup" });
  assert.equal(host.reports().length, beforeStart, "a fresh process has no cache to forget");
  await start({ type: "session_start", reason: "new", previousSessionFile: "/x" });
  assert.deepEqual(host.reports().at(-1), { unknown: { reason: "session_switch" }, panel_id: PANEL });
});

await withEnv({ ...baseEnv, PI_CACHE_RETENTION: "long" }, async () => {
  const host = fakeHost();
  piExtension(host.api);
  await host.handlers.get("message_end")(assistant({ input: 1, cacheRead: 50, cacheWrite: 0 },
    { api: "bedrock-converse-stream", provider: "amazon-bedrock", model: "us.anthropic.claude-sonnet-4-5" }));
  assert.equal(host.reports()[0].request.ttl_seconds, 3600, "PI_CACHE_RETENTION=long is a 1h cache");
});

await withEnv({ CMUX_SOCKET_PATH: SOCKET }, async () => {
  const host = fakeHost();
  piExtension(host.api);
  assert.equal(host.handlers.size, 0, "outside c11 the extension stays inert");
});

// ---- omp --------------------------------------------------------------------
assert.equal(ompModule.versionAtLeast("18.3.5", [18, 3, 5]), true);
assert.equal(ompModule.versionAtLeast("18.10.0", [18, 3, 5]), true);
assert.equal(ompModule.versionAtLeast("18.3.4", [18, 3, 5]), false);
assert.equal(ompModule.versionAtLeast("16.2.2", [18, 3, 5]), false);
assert.equal(ompModule.versionAtLeast("19.0.0-beta.1", [18, 3, 5]), true);

await withEnv(baseEnv, async () => {
  const before = fakeHost("16.2.2");
  ompExtension(before.api);
  assert(before.handlers.has("message_end"));
  assert(!before.handlers.has("cache_warming_decision"), "omp before 18.3.5 cannot warm the cache");
  assert(!before.handlers.has("agent_start"), "omp lifecycle is not reported by this extension");

  const end = before.handlers.get("message_end");
  await end(assistant({ input: 3, cacheRead: 0, cacheWrite: 800, cttl: { ephemeral1h: 800 } }));
  await end(assistant({ input: 3, cacheRead: 800, cacheWrite: 0 }));
  await end(assistant({ input: 3, cacheRead: 800, cacheWrite: 90, cttl: { ephemeral5m: 90 } }));
  await end(assistant({ input: 3, cacheRead: 800, cacheWrite: 0 }, { provider: "google-vertex", model: "claude-opus-4-8@default" }));
  await end(assistant({ input: 3, cacheRead: 800, cacheWrite: 0 }, { provider: "minimax", model: "MiniMax-M3" }));
  assert.deepEqual(before.reports().map((report) => report.request.ttl_seconds), [3600, 3600, 300, 300, undefined]);
  assert.equal(before.reports()[0].panel_id, PANEL);

  for (const version of ["18.4.6", undefined]) {
    const after = fakeHost(version);
    ompExtension(after.api);
    const decide = after.handlers.get("cache_warming_decision");
    assert(decide, `omp ${version ?? "of unknown version"} may warm the cache`);
    assert.equal(await decide({ type: "cache_warming_decision", action: "warm" }, { hasUI: false }), undefined);
    assert.equal(after.reports().length, 0, "a subagent's warmer is not the panel's");
    assert.equal(await decide({ type: "cache_warming_decision", action: "warm" }), undefined);
    assert.deepEqual(after.reports().map((report) => Object.keys(report.request)), [["at_ms"]]);
  }
  // A task subagent runs in-process with hasUI false: its cache is not the panel's.
  const sub = { hasUI: false };
  const beforeSubagent = before.reports().length;
  await end(assistant({ input: 3, cacheRead: 800, cacheWrite: 0 }, { provider: "minimax", model: "MiniMax-M3" }), sub);
  await before.handlers.get("session_compact")({ type: "session_compact" }, sub);
  assert.equal(before.reports().length, beforeSubagent, "a subagent reports nothing");
  await end(assistant({ input: 3, cacheRead: 800, cacheWrite: 0 }), { hasUI: true });
  assert.equal(before.reports().length, beforeSubagent + 1, "the session with a UI reports");
  assert(before.handlers.has("session_compact"));
  await before.handlers.get("session_compact")({ type: "session_compact" });
  assert.equal(before.reports().at(-1).reset.reason, "compaction");
});

console.log("PASS: Pi and omp extensions report each request, warming refresh and reset of their prompt cache");
