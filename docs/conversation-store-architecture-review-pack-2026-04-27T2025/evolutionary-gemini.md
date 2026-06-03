# Evolutionary Plan Review: Conversation Store Architecture

### Executive Summary
The plan proposes a shift from a brittle, metadata-driven session resume mechanism to a first-class `Conversation` primitive decoupled from specific TUIs. While positioned as a robust crash-recovery and resume fix, this architecture covertly builds the foundation for c11 to become a universal temporal orchestrator. By severing conversation state from live processes, c11 is perfectly positioned to offer centralized history, cross-surface mobility, and a unified memory store for all agentic interactions across workspaces.

### What's Really Being Built
**A decoupled, universal agent memory bus.** 
c11 is evolving from a spatial orchestrator (arranging terminals and handling inputs) to a temporal orchestrator (managing the timeline and state of agent workflows). The `ConversationStore` becomes the definitive system of record for "what work was being done," independent of the LLM tool executing it or the UI surface hosting it. 

### How It Could Be Better
- **Elevate Scrape-Pull to Proactive Push:** For agents lacking hooks (Codex, Opencode, Kimi), relying on a 30s autosave pull-scrape is a fallback that introduces a 30s vulnerability window. Instead, c11 could deploy standard file-system watchers (e.g., `FSEvents`) on known session directories (`~/.codex/sessions/`) tied to active surfaces. This turns a polling fallback into a near-instant push, closing the crash-recovery gap for uncooperative TUIs.
- **Universal Payload Schema for Routing:** The `payload` field (`[String: PersistedJSONValue]?`) should promote universal metadata (like `cwd` and `git_branch`) to first-class optional fields on `ConversationRef`. Standardizing these allows c11 to globally query, filter, and route conversations (e.g., "resume my last Claude session that touched branch X") without writing kind-specific parsers.
- **Don't Wait for V2 to Collect History:** The plan states `history` is empty in V1 writes. This misses the compounding value of the primitive. Populating the `history` array when an active ref is tombstoned or replaced costs almost nothing in JSON size but immediately begins building the dataset needed for V2 features.

### Mutations and Wild Ideas
- **Headless Background Conversations:** If a conversation is just a stateful ref and a strategy, a "suspended" conversation doesn't strictly need to be resumed into a visible UI surface. c11 could resume long-running conversations in headless PTYs for background tasks (e.g., test fixing, massive refactors), surfacing them to a UI pane only when they require operator input or reach a terminal state.
- **Conversation Forking (Time Travel):** With `replayPTY` and decoupled session IDs, c11 could offer "fork this conversation." Duplicate the session storage (or use the LLM's own fork feature) and launch two panes from the same historical branch point to explore parallel solutions simultaneously.
- **Cross-Agent Handoff:** With standardized `cwd` and `context` payloads, a conversation's intent could theoretically change kinds. An operator could suspend an `opencode` session, extract its context, and resume that workflow inside a `claude-code` pane.

### What It Unlocks
- **Cross-Workspace Mobility:** A conversation started in Workspace A could be detached, held in the global index, and resumed in Workspace B. The conversation is now a portable entity, not a permanent resident of a single UI coordinate.
- **Unified Telemetry and Auditing:** Operators gain the ability to run analytics directly on the `ConversationStore` to see which agents were used where, for how long, and on what projects—without needing to reverse-engineer individual CLI logs.
- **Global Context Search:** c11 could integrate text search over the `transcript_path` stored in the refs, enabling universal queries like "find the conversation where I asked about the routing bug last Tuesday."

### Sequencing and Compounding
1. **Ship the Primitives (V1):** Land the `ConversationStore`, `ConversationRef`, and strategies.
2. **Collect History Immediately:** Write tombstoned sessions to the `history` array in V1 so data compounds prior to the UI existing.
3. **Build the Global Derived Index:** Establish the out-of-band index on launch.
4. **Expose CLI Primitives Early:** Before baking opinionated UI, expose `c11 conversation search` and `c11 conversation fork` so power users can script their own workflows.
5. **Ship the UI (V2):** Add the visual history pickers and cross-workspace drag-and-drop.

### The Flywheel
The flywheel is driven by **trust leading to abandonment**.
- The operator trusts c11 will never lose a conversation.
- Because they trust it, they stop carefully managing agent lifecycles (typing `/exit`, ensuring clean shutdowns). They begin recklessly closing panes and hitting Cmd+Q.
- This behavior causes more conversations to become `suspended` or `tombstoned` rather than cleanly resolved.
- This creates a massive, implicit history of disconnected agent work.
- c11 can then surface this history as a highly valuable, searchable knowledge base ("past contexts"), making c11 the most critical asset in the operator's stack and driving further usage.

### Concrete Suggestions
1. **Change V1 to Populate `history`:** Modify the state machine so that `alive` -> `tombstoned` or replacing an `active` ref appends the outgoing ref to `history`. The V1 UI can ignore it, but the data will be there for V2.
2. **Standardize `cwd`:** Promote `cwd` out of `payload` and into the core `ConversationRef` struct. It is universally applicable to software engineering agents and critical for scrape-pull filtering and cross-workspace routing.
3. **Emit SurfaceEvents on Transition:** Add a `SurfaceEvent` broadcast whenever a conversation transitions state (e.g., `alive` -> `suspended`). This allows other c11 components (like the sidebar telemetry) or external operator scripts to react immediately without polling the store.

### Questions for the Plan Author
1. Should `cwd` (and potentially `git_branch`) be a first-class field on `ConversationRef` rather than buried in `payload`, given how crucial it is for filtering and scraping across all agent types?
2. If `history` is completely ignored in V1 writes, what happens to an `alive` session when the user starts a *new* session in the same surface? Is the old ref dropped, immediately losing the temporal advantage?
3. For hookless TUIs (Codex, Opencode), could we use `FSEvents` on their known session directories to trigger a push-like capture, rather than relying strictly on the 30s autosave pull-scrape?
4. How does the `c11 conversation push` CLI authenticate that the push is coming from a legitimate agent process in that surface, rather than a rogue background script? Is `CMUX_SURFACE_ID` sufficient security?
5. The global derived index is built on launch by scanning all snapshots. If an operator has hundreds of snapshots, will this cause noticeable launch latency? Should the scan be asynchronous or deferred?
