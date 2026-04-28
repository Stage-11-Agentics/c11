## Evolutionary Code Review
- **Date:** 2026-04-28T00:35:00Z
- **Model:** Claude (claude-opus-4-7)
- **Branch:** c11-flash-tab-and-workspace
- **Latest Commit:** 9b1e1f62
- **Linear Story:** flash-tab (Stage 11; no AUT-### id)
- **Review Type:** Evolutionary/Exploratory
---

### What's Really Being Built

Read narrowly, this PR adds two visual ornaments next to an existing pane flash. Read at the right altitude, it does something more interesting: it elevates *flash* from "ring around one pane" to **a workspace-scope locator event** that fans out across every layer where the operator might be looking — pane content, tab strip, sidebar workspace row.

What is actually being birthed here, even if nobody has named it yet:

- **A spatial routing primitive for "look here" signals.** The fan-out at `Workspace.triggerFocusFlash(panelId:)` (Sources/Workspace.swift:8811) is the first place in c11 where a single id is exploded into "draw the operator's eye to the pane *and* the tab *and* the workspace row, simultaneously, without changing focus." That's not a flash feature. That's the **attention bus** — a non-intrusive, non-selecting way for the system (and, soon, agents) to point at a surface.
- **A discipline split between "alert" and "ambient."** The three channels deliberately differ in peak opacity (1.0 / 0.55 / 0.18) and pulse count (2 / 2 / 1). That's not animation aesthetics — that's an emerging *intensity vocabulary* keyed to spatial distance from the operator's gaze. The further from where the operator is currently looking, the gentler the signal. This is exactly the right gradient. It just hasn't been formalized as a vocabulary yet.
- **Bonsplit's first agent-aware affordance.** `flashTab(_:)` (vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift:301) is, in the abstract, "an external caller can ask a tab strip to draw attention to a non-selected tab without selecting it." That's a generic primitive any consumer wants, but it's especially load-bearing for the operator:agent pair, where agents need to point at things they *aren't* the operator's current focus.
- **A separation of "where focus is" from "where attention is."** Until now those collapsed: focus changes meant a flash on the now-focused pane. The notification gateway still calls `focusPanel` then flashes. But `triggerFocusFlash` itself is now a *pure attention* event — the v2 socket path uses it without any focus mutation. That separation is small in lines of code and large in implications. (See "Mutations" below — agents calling attention without stealing focus is a design space that just opened.)

The capability statement: **c11 now has a one-call API for "draw the operator's eye to surface X across every layer of the workspace UI, without disturbing what they're doing."** This is the seed of an attention/notification bus.

### Emerging Patterns

**Patterns to formalize:**

1. **Generation-token + `.onChange` + per-row `==` skip.** This pattern appears three times now: pane content (`focusFlashAnimationGeneration` in MarkdownPanelView/BrowserPanelView), Bonsplit tab (`pane.flashTabGeneration` + per-tab gating to 0), sidebar row (`Workspace.sidebarFlashToken` threaded as `let`). The shape is identical: a published Int monotonically increments at fan-out → a precomputed `let` on the view → `.onChange` fires → a `lastObservedX` field guards re-runs and stale segments. This is c11's idiomatic "fire-and-forget transient signal under typing-latency-sensitive equatability." It deserves a name and probably a tiny helper.
2. **Fan-out at the workspace boundary, not at the call site.** The four trigger paths (keyboard, right-click, v2 socket, notification routing) all converge at `triggerFocusFlash`. The notification routing now also routes *through* `triggerFocusFlash` rather than duplicating the per-channel work. This is good architectural hygiene — the workspace owns the canonical fan-out, callers express intent only.
3. **Visual-only contracts.** Both new channels make "no selection mutation" an explicit contract documented at the public seam (`flashTab(_:)`'s docstring, `triggerFocusFlash`'s docstring, the `sidebarFlashToken` doc). This is a pattern worth keeping pressure on — every animation channel that "looks like it might select" is a future bug.
4. **Mirrored-by-construction envelope across module boundaries.** `TabFlashPattern` in Bonsplit reproduces the host's `FocusFlashPattern` shape numerically rather than depending on it. This is the right call for upstream-friendliness, but it means the "match by construction" promise is policed only by code review. A small mismatch (curve, duration) would silently drift the visuals.

**Anti-patterns to catch early:**

1. **Three subtly different segment runners.** `runSidebarFlashAnimation` in ContentView.swift:11604, `runFlashAnimation` in Bonsplit's TabItemView, and the existing focus-flash animation methods in MarkdownPanelView/BrowserPanelView all have the same shape: reset to envelope[0], iterate `segments`, `DispatchQueue.main.asyncAfter` per segment, guard on generation, `withAnimation`. There are now three places where one timing bug needs to be fixed three times. Worth a single helper (Sources/Panels/Panel.swift would host it cleanly next to the patterns).
2. **`SidebarFlashPattern` and `FocusFlashPattern` share segment-building boilerplate.** Both enums recompute `segments` from `values`/`keyTimes`/`curves`/`duration`. A factory `FlashEnvelope.from(values:keyTimes:duration:curves:)` removes ~12 lines per envelope and centralizes the off-by-one in `min(curves.count, values.count - 1, keyTimes.count - 1)` (which is fine but copied verbatim).
3. **Fan-out gate at the workspace, not at the channel.** The "Pane Flash" toggle (NotificationPaneFlashSettings.isEnabled) now silences *all three* channels. That's clean today, but as the channels diversify in semantic role (alert / locate / agent-said-something), the operator will eventually want per-channel toggles. The current gate makes that a future schema-breaking change to settings unless the gate moves slightly. Not urgent — but worth noting now while the channel count is small.
4. **Spelling drift between `lastObservedFlashGeneration` (Bonsplit) and `lastObservedSidebarFlashToken` (c11).** Token vs generation, and the surface-level fact that one calls itself a token and the other a generation. Trivial, but if you formalize this pattern it should pick one word.

### How This Could Evolve

Not polish — directions that change what c11 can be:

1. **Attention bus as an addressable primitive.** Today the only fan-out is "flash everywhere." Tomorrow's API:
   ```swift
   workspace.draw(attentionTo: panelId, intensity: .ambient | .normal | .urgent, layers: [.pane, .tab, .sidebar])
   ```
   With three intensity tiers and explicit layer choice, you cover: "agent finished a quiet task" (ambient, sidebar only), "build failed" (urgent, all three), "agent has a question" (normal, pane + tab). The infrastructure is already 80% there — three pulse envelopes calibrated for distance, three layers wired up. What's missing is the named API.
2. **Attention as a first-class agent capability over the v2 socket.** `surface.trigger_flash` becomes one call in a family: `surface.draw_attention {intensity, layers}`. Agents already call this in the existing pane flash. Once the API is named, every Lattice review agent, every long-running build agent, every autonomous loop gets a polite way to say "I changed something here, don't yell, just put a glow on it." This is the operator-loving move.
3. **Layered telemetry that survives workspace switching.** The sidebar pulse already works on a workspace the operator isn't viewing. The next obvious step: make the sidebar row *carry residue* — a faint gradient or count badge that decays over a few seconds — so the operator who walks back from a coffee break can see *which workspaces flashed while they were away*. This is the Lattice-board-on-the-side-of-the-app-itself move. The `sidebarFlashToken` is already a monotonic counter; it needs a paired "last flashed at" timestamp and a passive decay overlay.
4. **Mute & route per workspace.** The fan-out is symmetric across workspaces, but workspaces have different urgency profiles (production-monitor workspace versus scratch workspace). A workspace-level "notification policy" that maps incoming flashes to {silenced, ambient-only, full} is a small extension to the gate at line 8812. Now operators can have 30 agents running and only see attention from the four workspaces they care about today.
5. **Bonsplit upstreams `flashTab` and gets a `flashPane` sibling.** The same primitive at the *pane* level (flash the whole pane container, not the active tab) is the natural complement. With both, `BonsplitController` can express "draw the operator's eye to this surface" generically without needing the host to fan out on its own.
6. **Attention dispatch from terminal escape sequences.** Terminal apps already write OSC sequences for titles, hyperlinks, etc. A c11-specific OSC for "request attention on this surface" lets *programs running inside terminals* (not just c11 socket clients) point at themselves — `make` finishing, `pytest` printing first failure, `claude --dangerously-skip-permissions` finishing a turn. The handler is one-line: parse sequence → call `triggerFocusFlash`.
7. **Audit log of attention events.** Sidebar-status/log already exists for workspace telemetry. A debug-mode attention log (timestamps + source-of-flash + which channels fired) would make this whole subsystem observable for free, and is likely 15 lines.

### Mutations and Wild Ideas

- **The "attention storm" mode.** When ten agents all finish in 30 seconds, ten flashes fire across ten sidebar rows. This is information-rich. Lean into it — coalesce into a brief sidebar-wide "shimmer" pattern that signals "lots happened, look at the dashboard." The token machinery is already there; the missing piece is a sidebar-level subscriber that watches every workspace's `sidebarFlashToken` and cross-correlates.
- **Attention as a recordable channel.** Every `triggerFocusFlash` call is a "the system thinks the operator should look here" event. Persist these (with surface id, timestamp, source) and you have a *gaze record* — a derivable answer to "what was the system trying to tell me in the last hour?" This is highly composable with Lattice, with sidebar status, with retro AARs.
- **Attention shaping via agent voice.** Different agents could request flash with different *temperaments* — Gregorovitch's flashes might be slow and gold-tinted; a build watcher's might be sharp and red. Replace the single `cmuxAccentColor()` with a `flash.color` parameter at the API level, and now agent identity *visually* registers in the sidebar.
- **"Attention hover" — the inverse signal.** When the operator's mouse hovers over a sidebar row, briefly pulse the *corresponding tab in that workspace's tab strip* (if mounted). Bidirectional cross-layer pointing. Same primitive (flashTab), opposite direction. Trivial implementation, possibly transformative for navigability.
- **The "show me what you mean" debug shortcut.** Cmd-Shift-? + click any agent's status line in the sidebar → flashes the surface that wrote it. Re-uses the existing fan-out; closes the loop between sidebar telemetry and the surface that produced it.
- **Sidebar-only flashes for "remote teammates."** When other operators in the same Lattice plan touch a surface, fire a sidebar-only ambient pulse on workspaces tied to that plan. The fan-out's three-channel structure is *already* shaped for "polite ambient signal" — you just connect the wire from Lattice events into `sidebarFlashToken`.

### Leverage Points

Where small changes create disproportionate value:

1. **Extract a `FlashEnvelope` factory** (Sources/Panels/Panel.swift). Removes duplication, makes adding a fourth or fifth pulse pattern (urgent/agent-voice/storm) a 5-line affair.
2. **Extract `runFlashAnimation(envelope:generation:onUpdate:)`** as a `@MainActor` free function. Used by sidebar TabItemView, MarkdownPanelView, BrowserPanelView, and Bonsplit's TabItemView (with one-line wrapper for the latter to keep Bonsplit module-local). Single source of truth for the "reset → asyncAfter loop → guard → withAnimation" choreography.
3. **Name the attention bus.** A `Workspace.drawAttention(panelId:intensity:layers:)` API with `triggerFocusFlash` as the `.normal` / `[.pane, .tab, .sidebar]` case. Costs ~20 lines, opens the per-channel-toggle and per-intensity vocabulary doors immediately.
4. **Add `lastFlashedAt: Date?` to Workspace alongside `sidebarFlashToken`.** Enables decay overlays, "what flashed while I was away?", attention audit log, and per-workspace mute logic — all for one extra published property.
5. **Surface-level CLI command `c11 attention <surface>`** (alias of `surface.trigger_flash`, with `--intensity` / `--layers` flags later). Makes the primitive immediately accessible to scripts and the skill, which is where it spreads to every agent in the field.

### The Flywheel

**Existing self-reinforcement (already spinning):**

Single fan-out at `triggerFocusFlash` means every new trigger path (keyboard, right-click, v2 socket, notification, future agents) automatically gets all three channels for free. Each new caller makes the channels more valuable; each new channel makes existing callers more valuable. Today's commit just put the third spoke on this wheel.

**Engineerable next loop:**

Once the attention bus is named (`drawAttention(panelId:intensity:layers:)`), the loop becomes:

1. Skill teaches agents to call `c11 attention <surface> --intensity ambient` when they finish quiet work.
2. Operators observe ambient flashes are useful → keep them on.
3. Agents see the operator notice and act → calibrate their attention requests.
4. New agent classes (build watchers, Lattice review bots, OSC-from-terminal) plug into the same primitive.
5. The attention log becomes a retro-AAR signal: "where did the system point me, did I respond, was it right?"
6. Calibration data improves agent attention behavior → more useful flashes → more operator trust → more delegated work.

Each turn of the loop adds calibration data and reduces the cost of the next agent's attention request. This is the real prize — not a prettier flash, but an *attention substrate* for the operator:agent pair.

### Concrete Suggestions

#### High Value

1. **Extract `runFlashAnimation` helper.** Three call sites converge on the same `reset → asyncAfter loop → generation guard → withAnimation` shape. A `@MainActor` helper in `Sources/Panels/Panel.swift` (next to `FocusFlashPattern` / `SidebarFlashPattern`) takes `(envelope: FlashEnvelopeProtocol, generation: Int, isCurrent: () -> Bool, apply: (Double) -> Void)` and centralizes the loop. Bonsplit keeps its own copy (module isolation), but c11's two callers (`MarkdownPanelView.triggerFocusFlashAnimation` plus the new `runSidebarFlashAnimation` at ContentView.swift:11604) collapse to one. ✅ Confirmed — verified the loop shapes are identical and the existing focus-flash animation methods in MarkdownPanelView/BrowserPanelView already use this exact pattern.

2. **Name the attention bus.** Rename / wrap `triggerFocusFlash(panelId:)` as `drawAttention(panelId:intensity:layers:)` with the current call as the default. Why now: the API will accumulate callers and rename cost grows fast. Doing it before agents start scripting against `surface.trigger_flash` (which has only just shipped) is cheap. The v2 socket can keep the `surface.trigger_flash` command name for compat and just route through `drawAttention(.normal, [.pane, .tab, .sidebar])`. ❓ Needs exploration — touches the v2 socket protocol, which may have its own naming policy; worth one round of dialogue with the operator on whether `attention` is the right word vs `flash` / `point`.

3. **Add `lastFlashedAt: Date?` next to `sidebarFlashToken`.** Single field on `Workspace`. Unlocks: (i) sidebar decay overlay, (ii) "what changed while I was away," (iii) per-workspace mute by recency, (iv) attention audit log. The cost is one published property + one assignment in `triggerFocusFlash`. ✅ Confirmed — verified `Workspace.sidebarFlashToken` (Sources/Workspace.swift:5099-5104) is the natural anchor.

4. **Move the typing-latency invariant comment into a doc-comment on `==`.** The warning at Sources/ContentView.swift:10905-10915 is a wall of `//` comments above the struct. With three sites now touching this comparator (the original properties, the new `sidebarFlashToken`, and inevitably more soon), it should be a `///` doc-comment on the `==` function itself so Xcode quick-help surfaces it the moment someone touches the comparator. Same content, different location. ✅ Confirmed — purely a comment relocation, zero behavioral risk.

#### Strategic

5. **Formalize the `FlashEnvelope` shape.** Both `FocusFlashPattern` and `SidebarFlashPattern` have identical structure (values / keyTimes / duration / curves / `var segments`) with the same boilerplate `min(...)` step calculation. A protocol or a single struct factory `FlashEnvelope(values:keyTimes:duration:curves:)` removes the duplication and makes adding a third or fourth envelope (e.g., `UrgentFlashPattern`, `AgentVoiceFlashPattern`) trivial. Sets up the attention-intensity vocabulary cleanly. ✅ Confirmed — the two enums in Sources/Panels/Panel.swift are nearly mechanical duplicates.

6. **OSC sequence handler for "attention from inside the terminal."** Terminal programs already use OSC 7 / OSC 8 / OSC 1337 for various host signals. Define a c11-specific OSC (e.g., OSC 1338 ; type=flash ; intensity=ambient) and route it into `triggerFocusFlash`. Now `make` finishing, `pytest` first-failure, etc. point at themselves without operator scripting. ❓ Needs exploration — requires touching the Ghostty embed's OSC handler; should be checked for collision with upstream Ghostty/cmux conventions before claiming a number.

7. **Bonsplit `flashPane(_ paneId:)` companion.** Same shape as `flashTab`, applied at the pane level (flashes the whole pane container, useful when the relevant signal isn't a tab change but a pane-level event like split focus migrating). Bonsplit-internal patterns are already there; ~30 lines including the public API. Sets up cleaner upstream PR ("Add tab-level and pane-level flash affordances"). ❓ Needs exploration — confirm whether Bonsplit panes have an analog to `PaneState.flashTabId`/`flashTabGeneration` that fits this semantics; likely needs a new pair `flashGeneration` on `PaneState` alone.

8. **Attention debug log behind a `#if DEBUG` flag.** Single `dlog("attention.fan-out panel=… surface=… layers=pane,tab,sidebar")` at `triggerFocusFlash` makes this subsystem observable for free. Pattern matches the existing `dlog("sidebar.close ...")` calls already in the file. ✅ Confirmed — Sources/ContentView.swift:11543 already uses this pattern.

#### Experimental

9. **Per-agent flash temperament.** Plumb a `requestedBy: AgentIdentity?` through `triggerFocusFlash` and let it influence color/curve. Speculative, but cheap to prototype: replace `cmuxAccentColor()` at Sources/ContentView.swift:11517 with a tinted variant if the request includes an agent voice. Worth exploring if/when c11 grows an agent identity registry beyond the manifest.

10. **Sidebar shimmer for attention storms.** When `sidebarFlashToken` increments across N workspaces within T seconds, fire a sidebar-wide low-amplitude pulse. Differentiates "one of my agents finished" from "ten of my agents finished." Adds a coarse-grained meta-signal on top of the per-row signal. Risky in that "coalesce into shimmer" is animation-finicky; payoff is subtle but real for operators running many agents.

11. **Attention bidirectionality.** Hovering a sidebar workspace row briefly flashes the focused tab in *that* workspace (using the existing `flashTab` API, not just selection). Closes the loop the other way: operator pointing at workspace → workspace's current focus surfaces visually. Could be a default-off feature behind an "interactive sidebar pointing" toggle.

12. **"Trace this flash" debug command.** Right-click on a flashing tab → context menu entry "Trace flash source" → opens a debug surface listing the last N attention events with stack source (kbd / right-click / socket / notification / OSC / agent). Pure observability play, but the kind of thing that makes the attention bus reasonable to debug as it grows.

### Closing observation

The most undervalued thing in this PR is the *quietness* of channel (c). At peak opacity 0.18, single pulse, 0.6s — it's almost subliminal. That gentleness is what makes the rest of the system trustworthy. If sidebar flashes shouted, operators would silence the toggle and lose all three channels at once. Because it whispers, the operator can leave it on while running thirty agents, and that's the regime where the attention bus actually pays off. Protect that calibration. Don't let future contributors ratchet up the peak opacity in a "make it more visible" PR. It's already at exactly the right place.
