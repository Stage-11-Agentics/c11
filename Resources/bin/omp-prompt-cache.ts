// c11-scoped omp (oh-my-pi) prompt cache bridge.
//
// Loaded only by Resources/bin/omp for an interactive omp process inside a
// live c11 surface. It reports each model request's prompt cache use (time,
// provider, model and token counts, never text) so the cold mark can follow
// the cache. omp's session files are never opened, and no lifecycle is reported.
//
// omp 18.3.5 added prompt-cache warming: shortly before a 5-minute entry
// expires, omp replays its last request to keep the cache warm (setting
// `providers.cacheWarming`, idle by default). The last request then no longer
// says when the cache expires, so on releases that can warm, each refresh is
// reported as a request: it reads the cache and restarts its lifetime, and once
// warming stops the cache goes cold one lifetime after the last refresh.

type Handler = (event: any) => unknown;

/** The first omp release that can warm the cache on its own. */
const CACHE_WARMING_SINCE = [18, 3, 5];

/** Whether `version` ("18.4.6", "18.4.6-beta.1") is at least `floor`. */
export function versionAtLeast(version: string, floor: number[]): boolean {
  const parts = version.split(/[.+-]/).slice(0, floor.length).map((part) => Number.parseInt(part, 10));
  for (let index = 0; index < floor.length; index += 1) {
    const part = Number.isFinite(parts[index]) ? parts[index] : 0;
    if (part !== floor[index]) return part > floor[index];
  }
  return true;
}

export default function c11OmpPromptCache(omp: {
  on: (event: string, handler: Handler) => void;
  exec: (
    command: string,
    args: string[],
    options?: { timeout?: number },
  ) => Promise<unknown>;
  pi?: { VERSION?: unknown };
}) {
  const c11 = process.env.C11_AGENT_HOOK_CLI;
  const socket = process.env.CMUX_SOCKET_PATH;
  if (!c11 || !socket) return;

  // Reports are fire-and-forget: omp never waits on c11.
  const panel = process.env.C11_PANEL_ID || process.env.C11_TAB_ID || process.env.CMUX_SURFACE_ID;
  const reportCache = (payload: Record<string, unknown>) => {
    if (panel) payload.panel_id = panel;
    try {
      // Nothing waits on it, so a slow c11 under load still gets the report.
      omp.exec(c11, ["--socket", socket, "rpc", "agent.prompt_cache.report", JSON.stringify(payload)], { timeout: 5000 })
        .catch(() => {});
    } catch {
      // Cache telemetry is advisory. Never disturb omp if c11 exits.
    }
  };
  const count = (value: unknown) =>
    typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.round(value) : 0;

  // Anthropic's lifetime is the tier the request wrote (`cttl`): 1h by default
  // on OAuth, 5m on an API key unless PI_CACHE_RETENTION=long. When a request
  // writes both, the 5-minute part is the tail; a pure read keeps the last tier.
  const longRetention = process.env.PI_CACHE_RETENTION === "long";
  let lastTTL: number | undefined;
  const anthropicTTL = (usage: any) => {
    if (count(usage.cttl?.ephemeral5m) > 0) lastTTL = 300;
    else if (count(usage.cttl?.ephemeral1h) > 0) lastTTL = 3600;
    return lastTTL ?? (longRetention ? 3600 : 300);
  };
  // Anthropic itself, or a router serving its model under an `anthropic/…`,
  // `anthropic.…` or `….anthropic.…` id. Other providers on the
  // anthropic-messages API (Kimi, MiniMax, GLM, Copilot) cache implicitly, so
  // c11's policy table decides their lifetime.
  const usesAnthropicCache = (message: any) => {
    const provider = String(message.provider ?? "").toLowerCase();
    const model = String(message.model ?? "").toLowerCase();
    return provider.includes("anthropic")
      || model.startsWith("anthropic/") || model.startsWith("anthropic.") || model.includes(".anthropic.");
  };

  omp.on("message_end", async (event) => {
    const message = event?.message;
    if (message?.role !== "assistant") return;
    const usage = message.usage ?? {};
    const input = count(usage.input);
    const read = count(usage.cacheRead);
    const write = count(usage.cacheWrite);
    // No usage: the request failed before the provider read anything.
    if (input + read + write === 0) return;
    const request: Record<string, unknown> = {
      at_ms: count(message.timestamp) || Date.now(),
      input_tokens: input,
      cache_read_tokens: read,
      cache_write_tokens: write,
    };
    if (typeof message.provider === "string") request.provider = message.provider.slice(0, 128);
    if (typeof message.model === "string") request.model = message.model.slice(0, 128);
    if (usesAnthropicCache(message)) request.ttl_seconds = anthropicTTL(usage);
    reportCache({ request });
  });

  // A compaction replaces the cached prefix: cold until the next request.
  omp.on("session_compact", async () => {
    reportCache({ reset: { reason: "compaction", at_ms: Date.now() } });
  });

  // An unreadable version is treated as one that can warm. The warmer's
  // decision is never changed.
  const version = typeof omp.pi?.VERSION === "string" ? omp.pi.VERSION : undefined;
  if (version === undefined || versionAtLeast(version, CACHE_WARMING_SINCE)) {
    omp.on("cache_warming_decision", async (event) => {
      if (event?.action === "warm") reportCache({ request: { at_ms: Date.now() } });
    });
  }
}
