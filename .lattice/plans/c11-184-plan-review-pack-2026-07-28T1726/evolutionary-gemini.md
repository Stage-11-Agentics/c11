# C11-184 Evolutionary Plan Review

### Executive Summary
The plan aims to implement two simple binary states—`flag` and `suppressed`—for agents. While framed primarily as a UI and attention-management feature, this is secretly the foundation for **hierarchical agent orchestration and autonomous exception handling**. By formalizing how agents ask for help and how they can be silenced, this plan sets the stage for a massive scale-up in the number of concurrent agents an operator can manage. The biggest opportunity here isn't just making a prettier UI for humans; it's using the socket events to allow *other agents* to supervise and unblock the flagged ones.

### What's Really Being Built
You are building an **Agent Exception Handling Protocol**.
Until now, agents were essentially unmanaged processes. If they failed or needed input, they just printed to stdout. By adding `flag` and `suppressed`, you are creating a semantic layer of interrupts. "Suppressed" is equivalent to sending a process to the background (`&`), and "flag" is equivalent to an unhandled exception or a blocking `SIGSTOP` awaiting a signal. This is the first step toward a true operating system scheduler for autonomous agents.

### How It Could Be Better
- **Context-Rich Interrupts:** Currently, `flag.raised {reason}` is quite thin. It forces the operator (or an external system) to context-switch, focus the terminal, and read the scrollback to understand the problem. The event should optionally carry a short snapshot of recent terminal output or the last executed command. This would allow immediate triage without switching focus.
- **Ephemeral Suppression:** Human operators are notoriously bad at remembering they muted something. A permanent `suppressed = true` risks zombie agents burning resources. A time-bound suppression (`suppress --until "1h"`) or condition-bound suppression (`suppress --until-flag`) would be more resilient.
- **Structured Resolutions:** When a flag is lowered, it's just gone. If we capture *how* it was lowered (e.g., `lower-flag --resolution "fixed API key"`), we instantly start building a high-value dataset for fine-tuning agents to self-correct in the future.

### Mutations and Wild Ideas
- **Agent-to-Agent Triage (The Supervisor Swarm):** What if flags weren't just for humans? You could spawn a "Supervisor Agent" whose sole job is to listen for `flag.raised` events. When a worker agent flags "Need a GitHub token", the Supervisor Agent reads the event, injects the token into the worker's surface, and issues `flag.lower`. The human never even sees it.
- **The Flag Bidding Market:** Instead of a strict oldest-first FIFO queue for flags, what if agents could assign a "severity" or "bounty" to their flags? Critical infrastructure agents outbid coding agents for the operator's attention.
- **Flag Storm Coalescence:** If a backend service goes down, 50 agents might simultaneously raise a flag. The UI could detect identical or highly similar flag reasons and coalesce them into a single "Incident", allowing bulk-lowering.

### What It Unlocks
- **Massive Concurrency:** Operators can confidently launch 100+ agents simultaneously, safely suppressing them all, knowing that the `flag` protocol guarantees they will be interrupted only for true exceptions.
- **Overwatch Automation:** The events emitted (`flag.raised`, `flag.lowered`) are the missing link for external dashboards (like Overwatch) to measure agent autonomy limits—calculating MTBI (Mean Time Between Interventions) and tracking which tasks require the most hand-holding.
- **Invisible Daemons:** Agents can now function entirely as background daemons (`suppressed = true`), completely outside the operator's visual field, checking in only when a threshold is breached.

### Sequencing and Compounding
1. **The Event Payload is the Lever:** Invest heavily in the data payload of the four socket events (`raised`, `lowered`, `suppressed`, `unsuppressed`). This is where the compound interest lies. If those events are rich enough, the community will build the dashboards and auto-resolvers for you.
2. **Defer the Cross-Workspace Dashboard:** The plan rightly avoids the cross-workspace dashboard for now. Keep deferring it. Let the `flag.list` API and events handle external aggregations until the usage patterns are proven.
3. **Capture the Lowering Context:** Add an optional `resolution` string to the `lower` command early on. It costs almost nothing to store, but the accumulated data will be invaluable for future RLHF (Reinforcement Learning from Human Feedback).

### The Flywheel
The ideal self-reinforcing loop:
1. Agent encounters a novel problem -> Raises Flag.
2. Human investigates -> Provides a solution -> Lowers Flag with resolution note.
3. The paired Flag + Resolution is ingested into the agent's context or a global fine-tuning dataset.
4. Agent encounters the same problem -> Solves it autonomously -> Does not raise flag.
**To engineer this:** You need a way to link the `lower` action with the preceding terminal input. If the UI could automatically snapshot the 5 commands typed between a `flag` and a `lower`, you'd have an automated training-data factory.

### Concrete Suggestions
1. **Extend the Event Payload:** Update the `flag.raised` event to include a brief state summary (e.g., last 10 lines of the surface buffer or current working directory).
2. **Add a Resolution Field:** Update `flag.lower` to accept an optional `--resolution <text>` argument. Even if it's just logged and not displayed in the UI, it captures the human's triage intent.
3. **"Suppress Until Flag" Default:** Consider making `suppress` automatically lift if a flag is raised (the plan implies flag *overrides* suppression visually, but maybe `suppressed` should actually be cleared upon a flag raise so the agent is fully demoted back to normal operator attention).

### Questions for the Plan Author
1. If a supervisor agent listens to `flag.raised` and fixes the issue, how does it know the context without a terminal snapshot in the event payload?
2. Are we at risk of a "flag storm" if a network outage causes 50 agents to flag simultaneously, and is there any throttling mechanism on direct system notifications?
3. The spec mentions "No auto-lower on terminal input". But what if the *agent* realizes it can recover and issues its own `flag.lower`? Is that permitted, or can only the operator/supervisor lower it?
4. Is a permanent `suppressed = true` state dangerous if the operator forgets about it? Should we support a timeout?
5. When a human lowers a flag via the UI banner 'X', we lose the context of *why* they dismissed it. Should the banner offer a quick way to log the resolution?
