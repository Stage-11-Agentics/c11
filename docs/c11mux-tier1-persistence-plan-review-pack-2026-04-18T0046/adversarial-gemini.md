# Adversarial Plan Review: c11mux-tier1-persistence-plan

### Executive Summary
The plan is fundamentally sound in its goals but contains a critical type mismatch that will cause implementation failure on day one, along with severe performance and architectural risks. It treats metadata persistence as a simple serialization problem, ignoring the realities of high-frequency agent updates, UI thread blocking, and the fragility of reverse-engineering an external tool's undocumented internal state. The single biggest issue is the type mismatch between `[String: Any]` in `SurfaceMetadataStore` and the proposed `[String: String]` in the snapshot schema, which will immediately break serialization for existing numeric keys like `progress`.

### How Plans Like This Fail
1. **The "It's Just Data" Fallacy**: Assuming that because data fits in memory, it can be safely and cheaply written to disk synchronously. Writing potentially 32 MiB of JSON on the main thread every 8 seconds will cause severe UI stuttering and frame drops.
2. **Coupling to Undocumented Externals**: Relying on Claude Code's undocumented internal directory structure (`~/.claude/projects/`) is highly fragile. When Anthropic inevitably changes their storage model (e.g., to SQLite or a different path), c11mux's resume feature will silently break.
3. **The Thundering Herd**: Not accounting for high-frequency updates. If an agent spams the `progress` key (e.g., a fast spinner), and every mutation bumps the autosave fingerprint, the system will needlessly burn CPU and SSD life writing large session files at every 8-second interval.

### Assumption Audit
1. **Metadata values are Strings (False/Fatal):** The plan proposes `var metadata: [String: String]?`. But `SurfaceMetadataStore` holds `[String: Any]` and explicitly validates `progress` as an `NSNumber` (0.0–1.0). **Load-bearing.** This will cause compilation or runtime encoding failures immediately.
2. **Synchronous JSON Encoding is Fast Enough (Dangerous):** Assuming up to 32 MiB of `SessionWorkspaceSnapshot` can be encoded without dropping frames. `SessionPersistenceStore.save` appears to run synchronously for the snapshot data construction.
3. **Agent Updates are Infrequent (Unlikely):** Assuming the autosave fingerprint can safely bump on every metadata mutation without causing pathological disk write amplification.
4. **Terminal is at a Shell Prompt (Dangerous):** Phase 5 assumes it's safe to blindly `panel.send_text("claude --resume <id>\n")`. If the terminal is currently in a Python REPL, Vim, or has half-typed text, this injection will fail or cause unintended execution.
5. **UUIDs are Unique Across Time (Mostly True):** But if a user duplicates a workspace snapshot or uses a dotfiles manager to sync sessions across machines, UUIDs will collide across active instances.

### Blind Spots
1. **Disk Wear and Battery Life:** Continually serializing up to 32MB to disk every 8 seconds during an active agent session (where progress/status updates rapidly) is hostile to laptop batteries and SSD lifespans.
2. **Stale State Accumulation:** Zombie status entries from crashed or uninstalled agents will persist forever because there is no garbage collection or aging for `staleFromRestart=true` chips.
3. **Claude Slug Encoding Edge Cases:** The plan assumes `cwd` to slug conversion just replaces `/` with `-` (e.g., `-Users-demo...`). What about paths with spaces, special characters, or Unicode? Does it exactly match Anthropic's slugification algorithm?
4. **Schema Versioning for Metadata:** The plan says "Schema stays at v1", but we are introducing complex inner dictionaries. If we need to change the `metadata` payload structure later, we have no versioning for the inner payload, relying entirely on loose JSON types.

### Challenged Decisions
1. **Decision 2: "Full contents, no whitelist."**
    * *Counterargument:* A whitelist of canonical keys is much safer. Allowing arbitrary 64 KiB blocks of custom data per panel enables rogue agents to bloat the session file, practically guaranteeing the 32 MiB worst-case scenario.
    * *Alternative:* Only persist canonical keys, or enforce a much smaller cap (e.g., 4 KiB) for non-canonical keys in the persistent snapshot.
2. **Phase 3: Not Aging Out Stale Entries.**
    * *Counterargument:* Leaving stale entries forever guarantees the UI will eventually clutter with ghosts of abandoned workspaces, confusing users.
    * *Alternative:* Drop stale entries after 24 hours of inactivity or if the agent hasn't re-asserted them.
3. **Phase 4: Implicit External State Coupling.**
    * *Counterargument:* Reading `~/.claude/projects/` is an inherently brittle hack that violates encapsulation.
    * *Alternative:* Push the integration burden to the agent. Provide a standardized environment variable or socket message for agents to register their resume commands explicitly.

### Hindsight Preview
1. **"Why didn't we just throttle metadata autosaves?"** We will realize that tying the session autosave directly to metadata mutations causes the app to constantly write to disk when agents run fast progress bars.
2. **"We should have validated the terminal state before sending text."** Users will complain that clicking "Resume Claude session" while Vim or `nano` was open caused it to blindly type "claude --resume" into their code.
3. **"The JSON encoder is the top CPU consumer."** Profiling will show `AppSessionSnapshot.build(...)` destroying app responsiveness because we added too much unstructured dictionary data to the tree.

### Reality Stress Test
*What happens when the three most likely disruptions hit simultaneously?*
1. A user runs a heavy Claude session with a very deep directory structure (complex slug).
2. Claude Code updates its version and subtly changes its `projects/` path format.
3. The agent sends 20 `progress` updates per second.

*Result:* The Claude session resume silently vanishes (because the directory structure changed and our naive scan fails), while the app stutters heavily trying to serialize 30MB of JSON to disk 20 times a second (bounded only by the 8s interval, meaning it hits disk *every* 8s perfectly with a massive payload), completely ruining the user experience.

### The Uncomfortable Truths
1. We don't actually know Claude's slugification rules. We're guessing it's just replacing `/` with `-`.
2. This plan blesses `SurfaceMetadataStore` to become a durable database, but it is architected like an ephemeral cache (using `[String: Any]`).
3. The 32 MiB worst-case size is hand-waved away, but JSON encoding/decoding of 32 MiB is not O(1) and will block the main thread unless explicitly moved to a background queue, which `SessionPersistenceStore.save` currently does not do safely for the entire snapshot construction.

### Hard Questions for the Plan Author
1. How will you serialize `progress` (an `NSNumber`) into `var metadata: [String: String]?` without crashing or breaking compilation?
2. How do we guarantee that `panel.send_text("claude --resume <id>\n")` won't execute destructively if the terminal is not at a clean shell prompt?
3. What happens to battery life and SSD wear when an agent updates a status or progress key 10 times a second, triggering the 8-second autosave loop continuously for hours?
4. What is the exact algorithm Claude uses to convert a `cwd` to a slug, and what happens when it encounters spaces or Unicode? (If "we don't know", Phase 4 is built on sand).
5. How do we purge `staleFromRestart=true` status chips if the user never runs the agent again? Do they stay forever?
