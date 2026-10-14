# Review: Evolutionary Lens
**Model:** ugemini
**Lens:** Evolutionary

## 1. What is this, really?
At its core, this is a **filesystem-backed, distributed actor-model runtime**. By tying message delivery to the filesystem (`_outbox/`, `inbox/`) and using terminal PTYs as the message ingestion interface, it transforms isolated terminal sessions into stateful actors capable of async coordination. The "filesystem IPC bus" framing is the most powerful because it reveals the system's resilience—crashing the c11 daemon doesn't drop messages if they're committed to disk. It applies the Unix philosophy to multi-agent swarm orchestration: everything is a file, state is explicit, and surfaces communicate by appending structured JSON. This is the foundational substrate for a localized, multi-agent operating system.

## 2. How will it actually be used?
The target operator (managing 8–30 agents via lattice-orchestrator) will lean on this heavily for **supervision trees, work-stealing, and handoffs**.
An "overwatch" agent will run in a dedicated pane, consuming events and delegating work to worker agents via the mailbox.
Patterns that emerge:
*   **Handoffs/Pipelines:** Agent A (builder) completes a task, drops an envelope to Agent B (tester) to take over the next step.
*   **Heartbeats:** Worker agents pinging their status to the overwatch agent.
The design supports handoffs beautifully but will severely fight **request/reply** patterns. Because there are no built-in reply chains or robust correlation IDs at the protocol level, two-way sync is difficult. Furthermore, operators will immediately hit a wall with the `stdin` delivery handler. An agent bombarded with `<c11-msg>` blocks while it's in the middle of executing a shell command or using Vim will experience terminal corruption and race conditions.

## 3. Is it enough as-is?
**No, it is not enough as-is.** While the cross-workspace routing allows for basic swarm topologies, the reliance on the `stdin` delivery handler makes it a fragile toy for any serious, high-throughput orchestration. Pasting `<c11-msg>` into an active PTY is inherently unsafe for a concurrent swarm. If an agent is mid-command or in a cooked-mode application, the paste will corrupt the input stream. To be a true orchestration primitive, the system absolutely needs a dedicated out-of-band delivery mechanism.

## 4. Mutation vectors — ranked
1.  **Stable Addressing (IDs/Roles vs mutable titles):** *High leverage, small change.* Right now, routing by a user-mutable `title` is a massive liability. In an 8-30 agent swarm, name collisions are inevitable. Moving to role-based routing (e.g., `role: linter`) or stable, immutable ULIDs guarantees reliable actor addressing.
2.  **Out-of-band Delivery (Control socket):** *High leverage, high unlock.* Instead of `stdin` pasting, deliver the message to a dedicated control socket or a named pipe that the agent process listens to. Unlocks reliable message parsing without corrupting the PTY's data plane.
3.  **Topic / Pub-Sub Fan-out:** *Medium leverage.* Planned for Stage 3, this is necessary for true swarm awareness (e.g., broadcasting `event: repo-updated`). Cost is manageable, but risks introducing noisy-neighbor problems.
4.  **Ack/Receipt and `_processing/` Recovery:** *Medium leverage.* Crucial for exactly-once or at-least-once delivery guarantees. Will be required once agents start trusting the mailbox for critical state mutations.

## 5. Wildest mutations
*   **Mailbox as the Agent Event Store Memory:** The `_dispatch.log` and inboxes evolve into a durable, content-addressed append-only log. Agents use this log to bootstrap their context upon restart ("what did I miss while I was asleep?"), effectively turning the mailbox into shared memory.
*   **Seam for Human-Agent Collaboration:** A dedicated macOS Mailbox dashboard UI where humans can intercept, approve, modify, or inject messages into the agent swarm, making the human just another addressable node on the bus.
*   **C11-Msg Protocol as an OS Standard:** The `<c11-msg>` framing standardizes and outlives c11 entirely, becoming the generic wire protocol for LLM-to-LLM communication across any terminal, host, or SSH session.

## 6. What would you remove or simplify?
**Remove the `silent` delivery handler.** It feels like a testing or debugging artifact that leaks into production complexity. If a surface doesn't want messages, it shouldn't be addressable, or messages sent to it should simply be rejected.
**Simplify local-first cross-workspace routing.** The ambiguous routing rules (local-first, then single-workspace, else ambiguous) are too clever and unpredictable. It should strictly require workspace disambiguation (`--to-workspace`) if names aren't globally unique.

***

The single most important mutation is transitioning away from the `stdin` PTY delivery mechanism to an **out-of-band delivery socket** coupled with **stable actor addressing**. Using user-mutable `title` metadata as a routing key in a 30-agent swarm practically guarantees misdelivery. More critically, relying on `stdin` pasting means agents can never safely receive messages while they are actively working (running commands, editing files). By giving agents a stable identity and a dedicated side-channel for `<c11-msg>` blocks, the mailbox graduates from a fragile bash-script parlor trick into a robust, concurrent actor-model runtime.

In three months, the operator will abandon the `stdin` handler entirely. Realizing that the PTY input stream is too chaotic for reliable concurrent message ingestion, they will write wrapper scripts around their agents that manually tail the filesystem `watcher/inbox` directly. They will treat the c11 dispatcher strictly as a filesystem IPC router and bypass its PTY injection capabilities altogether, proving that the filesystem contract is the true value of the feature, not the terminal integration.