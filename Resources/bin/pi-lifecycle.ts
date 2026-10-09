// c11-scoped Pi lifecycle bridge.
//
// Loaded only by Resources/bin/pi for an interactive Pi process inside a live
// c11 surface. Pi's agent_settled event is the exact point at which retries,
// compaction, and queued continuations are finished, so it is the right
// working→idle boundary for the shared tab/sidebar activity icon.
//
// It also reports each model request's prompt cache use (time, provider,
// model and token counts, never text) so the cold mark can follow the cache.
// Pi's session files are never opened.

type Handler = (event: any) => unknown;

export default function c11Lifecycle(pi: {
  on: (event: string, handler: Handler) => void;
  exec: (
    command: string,
    args: string[],
    options?: { timeout?: number },
  ) => Promise<unknown>;
}) {
  const c11 = process.env.C11_AGENT_HOOK_CLI;
  const socket = process.env.CMUX_SOCKET_PATH;
  if (!c11 || !socket) return;

  const report = async (activity: "working" | "idle") => {
    try {
      await pi.exec(
        c11,
        ["--socket", socket, "agent-hook", activity, "--native-event", activity === "working" ? "agent_start" : "agent_settled"],
        { timeout: 750 },
      );
    } catch {
      // Lifecycle telemetry is advisory. Never disturb Pi if c11 exits or its
      // socket is replaced while the interactive session remains alive.
    }
  };

  pi.on("agent_start", async () => report("working"));
  pi.on("agent_settled", async () => report("idle"));

  // Prompt cache reports are fire-and-forget: Pi never waits on c11.
  const panel = process.env.C11_PANEL_ID || process.env.C11_TAB_ID || process.env.CMUX_SURFACE_ID;
  const reportCache = (payload: Record<string, unknown>) => {
    if (panel) payload.panel_id = panel;
    try {
      pi.exec(c11, ["--socket", socket, "rpc", "agent.prompt_cache.report", JSON.stringify(payload)], { timeout: 750 })
        .catch(() => {});
    } catch {
      // Advisory, as above.
    }
  };
  const count = (value: unknown) =>
    typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.round(value) : 0;

  // Anthropic's cache lifetime is the one the request asked for: 5m, or 1h
  // with PI_CACHE_RETENTION=long. A request that writes names its tier (when
  // it writes both, the 5-minute part is the tail); a pure read keeps the last.
  const longRetention = process.env.PI_CACHE_RETENTION === "long";
  let lastTTL: number | undefined;
  const anthropicTTL = (usage: any) => {
    const write = count(usage.cacheWrite);
    if (write > 0 && typeof usage.cacheWrite1h === "number") lastTTL = usage.cacheWrite1h >= write ? 3600 : 300;
    return lastTTL ?? (longRetention ? 3600 : 300);
  };
  const usesAnthropicCache = (message: any) => {
    const provider = String(message.provider ?? "").toLowerCase();
    const model = String(message.model ?? "").toLowerCase();
    return message.api === "anthropic-messages" || provider.includes("anthropic")
      || model.startsWith("anthropic/") || model.startsWith("anthropic.") || model.includes(".anthropic.");
  };

  pi.on("message_end", async (event) => {
    const message = event?.message;
    if (message?.role !== "assistant") return;
    const usage = message.usage ?? {};
    const input = count(usage.input);
    const read = count(usage.cacheRead);
    const write = count(usage.cacheWrite);
    // No usage: the request failed before the provider read anything.
    if (input + read + write === 0) return;
    const request: Record<string, unknown> = {
      // Set when the provider stream starts: the request's own time.
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

  // Pi 0.86+ can refresh the cache on its own ("cache warming"). After a
  // refresh, the last request no longer says when the cache expires, so c11
  // shows no cache state until the next real request.
  pi.on("cache_warming_decision", async (event) => {
    if (event?.action === "warm") reportCache({ unknown: { reason: "cache_warming" } });
  });
}
