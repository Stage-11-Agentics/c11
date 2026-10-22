import { randomUUID } from 'node:crypto';
import { subscribeNativeMailbox, doorbellText } from './mailbox-native.mjs';

// c11-scoped omp (oh-my-pi) native mailbox bridge.
//
// Loaded only by Resources/bin/omp for an interactive omp process inside a
// live c11 surface. It does two things and nothing else:
//
//  1. Reports omp's working/idle edges, so c11's turn gate reflects the agent
//     loop. `agent_end` is not proof of rest: omp can start a continuation
//     (empty-response recovery, auto-retry) before it emits the old one. Idle is
//     published only once `isIdle()` is true and no newer turn has begun.
//  2. Delivers c11's mailbox doorbell as a message that starts a turn at idle. Only the
//     invitation travels; the envelope stays in the inbox until
//     `c11 mailbox recv --ack`.
//
// The doorbell goes in as a custom message with `triggerTurn: true`: omp starts
// a turn when the agent is idle, and the model reads it like a user message.
// `sendUserMessage(text)` would also start a turn, but omp's UI then clears the
// operator's unsent composer text for any user message it did not submit
// itself. Mid-turn, `sendMessage` steers into the running turn, and
// `deliverAs: "followUp"` queues without any acceptance signal, so the route is
// idle-only (`canQueue: false`): it checks `isIdle()` first and is accepted
// only by the session's own `message_start` carrying the exact doorbell text.
// omp's session files, the composer and ~/.omp are never touched.
//
// omp hands its launch extensions to the task subagents it runs in-process.
// They have `hasUI === false` and are ignored here.

type Handler = (event: any, ctx?: any) => unknown;

export default function c11OmpNativeMail(omp: {
  on: (event: string, handler: Handler) => void;
  sendMessage?: (
    message: { customType: string; content: string; display: boolean },
    options?: { triggerTurn?: boolean },
  ) => void;
  exec: (
    command: string,
    args: string[],
    options?: { timeout?: number },
  ) => Promise<unknown>;
}) {
  const c11 = process.env.C11_AGENT_HOOK_CLI;
  const socket = process.env.C11_SOCKET_PATH || process.env.CMUX_SOCKET_PATH;
  if (!c11 || !socket) return;
  const panel = process.env.C11_PANEL_ID || process.env.C11_TAB_ID || process.env.CMUX_SURFACE_ID;

  const report = async (activity: "working" | "idle") => {
    try {
      await omp.exec(c11, ["--socket", socket, "agent-hook", activity], { timeout: 750 });
    } catch {
      // Lifecycle telemetry is advisory. Never disturb omp if c11 exits or its
      // socket is replaced while the interactive session remains alive.
    }
  };

  let turn = 0;
  let session = 0;
  let stopMailbox: (() => void) | undefined;
  let nativeAccepted: (() => void) | undefined;
  let nativeContext: any;
  const stopNative = () => {
    stopMailbox?.(); stopMailbox = undefined;
    nativeAccepted = undefined;
  };
  const isSubagent = (ctx: any) => ctx?.hasUI === false;

  const bind = async (_event: any, ctx: any) => {
    turn += 1;
    session += 1;
    stopNative();
    if (isSubagent(ctx)) return;
    nativeContext = ctx;
    const agentPID = Number(process.env.C11_AGENT_INTERACTIVE_PID);
    if (panel && agentPID === process.pid && process.env.C11_OMP_NATIVE_MAIL_DISABLED !== "1" && omp.sendMessage) {
      stopMailbox = subscribeNativeMailbox({
        socketPath: socket, panelID: panel, agentPID, sessionID: randomUUID(), route: "omp_extension", canQueue: false,
        deliver: async (text: string) => {
          // The wait delivers only if isIdle() becomes true (a turn that is
          // ending); it does not absorb the start of a live turn. Otherwise reject,
          // only before any side effect: a busy agent would throw AgentBusyError
          // into the operator's UI. c11 treats this rejection as retryable on omp.
          // A session switch during the wait supersedes this delivery.
          const bound = session;
          for (let wait = 0; wait < 60 && !nativeContext?.isIdle() && session === bound; wait += 1) {
            await new Promise((resolve) => setTimeout(resolve, 25));
          }
          if (session !== bound || !nativeContext?.isIdle()) throw new Error("busy");
          return new Promise<void>((resolve) => {
            nativeAccepted = () => { nativeAccepted = undefined; resolve(); };
            // The API returns void. Only message_start below acknowledges it. A
            // failure after calling is uncertain: let c11's bounded timeout use
            // the existing typed gate rather than asserting a safe rejection.
            try {
              omp.sendMessage!({ customType: "c11-mailbox-doorbell", content: text, display: true }, { triggerTurn: true });
            } catch { nativeAccepted = undefined; }
          });
        },
      });
    }
    // /new and a resume end at an idle prompt without running an agent turn.
    // The command's Return otherwise leaves c11 waiting for an agent_end omp
    // will never emit.
    if (ctx?.isIdle?.()) await report("idle");
  };
  omp.on("session_start", bind);
  omp.on("session_switch", bind);
  omp.on("session_shutdown", async () => { turn += 1; session += 1; stopNative(); });

  // A turn counter invalidates a pending end notification. omp's recovery
  // paths (an empty response, auto-retry) schedule a continuation before they
  // emit the old `agent_end`, so that handler can run while the next turn is
  // already starting or running.
  omp.on("agent_start", async (_event, ctx) => {
    if (isSubagent(ctx)) return;
    turn += 1;
    await report("working");
  });
  omp.on("message_start", (event, ctx) => {
    if (isSubagent(ctx)) return;
    nativeContext = ctx;
    if (event?.message?.role !== "custom" || event.message.customType !== "c11-mailbox-doorbell") return;
    const content = event.message.content;
    const text = typeof content === "string" ? content : content?.map((part: any) => part.type === "text" ? part.text : "").join("");
    if (text === doorbellText) nativeAccepted?.();
  });
  omp.on("agent_end", (_event, ctx) => {
    if (isSubagent(ctx)) return;
    nativeContext = ctx;
    // Publishing idle can immediately deliver the next invitation. Clear the
    // prior slot first, never after awaiting a report that opened that gate.
    nativeAccepted = undefined;
    // Publish idle only when omp is actually idle: isIdle() turns true about
    // 11 ms after this handler runs, or never if a continuation starts. Return
    // at once (omp awaits handlers) and let a newer turn, session or shutdown
    // supersede the wait, never a polling budget.
    const mine = turn;
    void (async () => {
      while (turn === mine && ctx?.isIdle?.() === false) {
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
      if (turn === mine) await report("idle");
    })();
  });
}
