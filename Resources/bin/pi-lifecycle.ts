import { randomUUID } from 'node:crypto';
import { subscribeNativeMailbox, doorbellText } from './mailbox-native.mjs';

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

type Handler = (event: any, ctx?: any) => unknown;

export default function c11Lifecycle(pi: {
  on: (event: string, handler: Handler) => void;
  sendUserMessage?: (text: string, options?: { deliverAs: "followUp" }) => void;
  exec: (
    command: string,
    args: string[],
    options?: { timeout?: number },
  ) => Promise<unknown>;
}) {
  const c11 = process.env.C11_AGENT_HOOK_CLI;
  const socket = process.env.C11_SOCKET_PATH || process.env.CMUX_SOCKET_PATH;
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

  // Prompt cache reports are fire-and-forget: Pi never waits on c11.
  const panel = process.env.C11_PANEL_ID || process.env.C11_TAB_ID || process.env.CMUX_SURFACE_ID;
  let stopMailbox: (() => void) | undefined;
  let nativeAccepted: (() => void) | undefined;
  let nativeContext: any;
  const stopNative = () => {
    stopMailbox?.(); stopMailbox = undefined;
    nativeAccepted = undefined;
  };
  pi.on("session_start", async (_event, ctx) => {
    stopNative();
    nativeContext = ctx;
    const agentPID = Number(process.env.C11_AGENT_INTERACTIVE_PID);
    if (!panel || !ctx?.hasUI || agentPID !== process.pid) return;
    if (process.env.C11_PI_NATIVE_MAIL_DISABLED !== "1" && pi.sendUserMessage) {
      stopMailbox = subscribeNativeMailbox({
        socketPath: socket, panelID: panel, agentPID, sessionID: randomUUID(), route: "pi_extension", canQueue: false,
        deliver: (text: string) => {
          if (!nativeContext?.isIdle() || nativeAccepted) return Promise.reject(new Error("busy"));
          return new Promise<void>((resolve) => {
            nativeAccepted = () => { nativeAccepted = undefined; resolve(); };
            // Pi's API returns void. Only message_start below acknowledges it.
            // Failure after calling is uncertain: let c11's bounded timeout use
            // the existing typed gate, rather than asserting a safe rejection.
            try { pi.sendUserMessage!(text, { deliverAs: "followUp" }); } catch { nativeAccepted = undefined; }
          });
        },
      });
    }
    // /new ends at an idle prompt without running an agent turn. Its Return
    // otherwise leaves c11 waiting for a settled event Pi will never emit.
    if (ctx.isIdle()) await report("idle");
  });
  pi.on("session_shutdown", stopNative);
  pi.on("message_start", (event, ctx) => {
    nativeContext = ctx;
    if (event?.message?.role !== "user") return;
    const content = event.message.content;
    const text = typeof content === "string" ? content : content?.map((part: any) => part.type === "text" ? part.text : "").join("");
    if (text === doorbellText) nativeAccepted?.();
  });
  // A failed preflight has no user message. Release the local slot at idle;
  // c11 still owns timeout/fallback and inbox state.
  pi.on("agent_settled", async (_event, ctx) => {
    nativeContext = ctx;
    nativeAccepted = undefined;
    // Publishing idle can immediately deliver the next invitation. Clear the
    // prior slot first, never after awaiting a report that opened that gate.
    await report("idle");
  });

  const reportCache = (payload: Record<string, unknown>) => {
    if (panel) payload.panel_id = panel;
    try {
      // Nothing waits on it, so a slow c11 under load still gets the report.
      pi.exec(c11, ["--socket", socket, "rpc", "agent.prompt_cache.report", JSON.stringify(payload)], { timeout: 5000 })
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
  // Anthropic itself, a router serving its model under an `anthropic/…`,
  // `anthropic.…` or `….anthropic.…` id, a backend passing its cache through
  // under a bare `claude-…` id (Vertex, OpenCode Zen), or a request whose usage
  // names Anthropic's cache tiers. Other providers on the anthropic-messages API
  // (Kimi, MiniMax, GLM) and GitHub Copilot's Claude cache their own way, so
  // c11's policy table decides their lifetime.
  const usesAnthropicCache = (message: any) => {
    const provider = String(message.provider ?? "").toLowerCase();
    const model = String(message.model ?? "").toLowerCase();
    return provider.includes("anthropic")
      || model.startsWith("anthropic/") || model.startsWith("anthropic.") || model.includes(".anthropic.")
      || (model.startsWith("claude") && provider !== "github-copilot")
      || count(message.usage?.cacheWrite1h) > 0;
  };

  let lastRequestAnthropic = false;
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
    lastRequestAnthropic = usesAnthropicCache(message);
    if (lastRequestAnthropic) request.ttl_seconds = anthropicTTL(usage);
    reportCache({ request });
  });

  // Pi 0.86+ can refresh the cache on its own ("cache warming"). A refresh
  // replays the last request, which reads the cache and restarts its lifetime,
  // so it is reported as a request; once warming stops, the cache goes cold
  // one lifetime after the last refresh. The warmer's decision is never changed.
  pi.on("cache_warming_decision", async (event) => {
    if (event?.action === "warm") reportCache({ request: { at_ms: Date.now() } });
  });

  // A compaction or a model switch replaces the cached prefix: cold until the
  // next request writes a new one.
  pi.on("session_compact", async () => {
    reportCache({ reset: { reason: "compaction", at_ms: Date.now() } });
  });
  pi.on("model_select", async (event) => {
    const next = event?.model;
    const previous = event?.previousModel;
    if (!next || !previous || (next.provider === previous.provider && next.id === previous.id)) return;
    reportCache({ reset: { reason: "model_switch", at_ms: Date.now() } });
  });
  // Anthropic drops cached messages when the thinking settings change.
  pi.on("thinking_level_select", async (event) => {
    if (!lastRequestAnthropic || !event || event.level === event.previousLevel) return;
    reportCache({ reset: { reason: "effort_change", at_ms: Date.now() } });
  });
  // Another conversation in the same panel (`/new`, a resume or a fork) has
  // its own cache, which c11 knows nothing about until its first request.
  pi.on("session_start", async (event) => {
    if (event?.reason === "new" || event?.reason === "resume" || event?.reason === "fork") {
      reportCache({ unknown: { reason: "session_switch" } });
    }
  });
}
