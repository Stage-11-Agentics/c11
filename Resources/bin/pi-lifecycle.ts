// c11-scoped Pi lifecycle bridge.
//
// Loaded only by Resources/bin/pi for an interactive Pi process inside a live
// c11 surface. Pi's agent_settled event is the exact point at which retries,
// compaction, and queued continuations are finished, so it is the right
// working→idle boundary for the shared tab/sidebar activity icon.

export default function c11Lifecycle(pi: {
  on: (event: string, handler: () => Promise<void>) => void;
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
        ["--socket", socket, "agent-hook", activity],
        { timeout: 750 },
      );
    } catch {
      // Lifecycle telemetry is advisory. Never disturb Pi if c11 exits or its
      // socket is replaced while the interactive session remains alive.
    }
  };

  pi.on("agent_start", async () => report("working"));
  pi.on("agent_settled", async () => report("idle"));
}
