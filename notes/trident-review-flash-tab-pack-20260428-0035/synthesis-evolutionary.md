## Evolutionary Synthesis — flash-tab

- **Date:** 2026-04-28
- **Branch:** c11-flash-tab-and-workspace
- **Latest Commit:** 9b1e1f62
- **Inputs:** evolutionary-claude.md, evolutionary-codex.md, evolutionary-gemini.md
- **Type:** Synthesis (read-only)

---

### Executive Summary — Biggest Opportunities

All three models converged with unusual force on a single reframing: this PR is not a flash feature, it is the seed of an **attention routing primitive** for c11 — a one-call API for "draw the operator's eye to surface X across every layer of the workspace UI without disturbing what they are doing." The unique product value is *"locate without selecting"* — separating "where attention is" from "where focus is." The three biggest opportunities, in priority order:

1. **Name and formalize the attention bus.** `Workspace.triggerFocusFlash(panelId:)` is already the de-facto fan-out point (keyboard, right-click, v2 socket, notification routing all converge there). Rename or wrap it as an explicit attention API (intensity tiers, layer choices, optional cause/source). This is the highest-leverage move because the API will accumulate callers fast and rename cost grows with each one.
2. **Extract a single shared generation-token animation runner.** The "reset → asyncAfter loop → generation guard → withAnimation" choreography now appears in MarkdownPanelView, BrowserPanelView, sidebar TabItemView, and Bonsplit's TabItemView. One timing bug currently needs three or four fixes. A single `@MainActor` helper (or SwiftUI ViewModifier) is the canonical "fire-and-forget transient signal under typing-latency-sensitive equatability" pattern and unlocks cheap addition of future channels.
3. **Open the agent-facing flywheel.** Once the attention bus is named and exposed via the v2 socket and CLI (e.g., `c11 attention <surface> --intensity ambient`), every Lattice review agent, build watcher, and autonomous loop gets a polite way to say "look here, don't yell." Calibrated low-intensity signals (the 0.18 / single-pulse sidebar channel especially) are the regime where 30-agent operation becomes legible — and the operator's trust in those signals compounds.

The undercurrent across all three reviews: **protect the calibration of the quietest channel.** The sidebar pulse at peak opacity 0.18 / single pulse / 0.6s is what makes the whole system trustworthy. Lose that gentleness and operators silence the toggle, taking the other two channels with it.

---

### 1. Consensus Direction — Evolution Paths Multiple Models Identified

1. **"Locate without selecting" is the core primitive.** All three reviews independently flagged that the deepest thing in the PR is the separation of attention from focus/selection. Claude calls it "a separation of where focus is from where attention is." Codex calls it "an attention routing fabric" whose semantic boundary is "look here, but do not move me." Gemini calls it a "Selection-Free Attention Routing Primitive." Same insight, three voices.
2. **Promote `triggerFocusFlash` from a method to an attention dispatch.** Claude proposes `drawAttention(panelId:intensity:layers:)`. Codex proposes a `WorkspaceAttentionSignal { kind, intensity, panelId, preservesSelection }` struct dispatched behind the existing call. Gemini proposes a generic pub/sub `AttentionRouter`. Different shapes, identical direction: one semantic event, multiple channel subscribers, policy at the workspace boundary.
3. **Generation-token + `.onChange` + per-row `==` skip is now an idiomatic pattern that needs a name.** The shape repeats four times in this branch alone (pane content, sidebar row, Bonsplit tab, plus the original BrowserPanelView). All three reviews call out the duplication as the single highest-leverage refactor. Codex and Gemini specifically flag it as the cheapest path to the next N attention channels.
4. **An intensity vocabulary is already implicit.** Peak opacities of 1.0 / 0.55 / 0.18 and pulse counts of 2 / 2 / 1 across pane / tab / sidebar are not animation aesthetics — they are an emerging "spatial distance from gaze" gradient. Claude, Codex, and Gemini all suggest formalizing this into named tiers (ambient / normal / urgent or polite / assertive / breathing).
5. **Bonsplit's `flashTab(_:)` is genuinely upstreamable.** All three reviews note the public API is selection-neutral and host-agnostic. Codex explicitly recommends preparing a narrow upstream PR (avoiding c11 terminology — "requestTabAttention" or similar). Claude proposes a `flashPane` companion to round out the primitive at the pane level.
6. **Numeric envelope mirroring across module boundaries is the main drift risk.** `FocusFlashPattern`, `SidebarFlashPattern`, and `TabFlashPattern` are intentionally similar but uncoupled. Claude and Codex both flag this — Codex calling it "drift-prone if c11 adds more attention channels," Claude proposing a `FlashEnvelope.from(values:keyTimes:duration:curves:)` factory. The fix is small now and expensive later.
7. **Debug-counter validation seam should extend to the new channels.** The pane channel already exposes a debug flash count consumed by `tests_v2/test_trigger_flash.py`. Codex (most specifically) and Claude both propose adding `debug.flash.tab_count` and `debug.flash.sidebar_count` so CI can assert fan-out happened without inspecting pixels or source text — the c11 test-quality policy explicitly forbids the latter.

---

### 2. Best Concrete Suggestions — Most Actionable Across All Three

1. **Extract `runFlashAnimation(envelope:generation:isCurrent:apply:)` as a `@MainActor` helper.** All three models converged on this as the highest-value low-risk refactor. Lives near `FocusFlashPattern` / `SidebarFlashPattern` in `Sources/Panels/Panel.swift`. c11's two callers (sidebar `runSidebarFlashAnimation` at `ContentView.swift:11604` and the existing panel methods) collapse to one. Bonsplit keeps its own copy for module isolation. Gemini's variant — wrap it as a `.transientFlash(generation:pattern:color:)` ViewModifier — is worth considering but must not introduce `@EnvironmentObject` / `@ObservedObject` reads in `TabItemView` (typing-latency invariant).
2. **Add per-channel debug counters and extend `tests_v2/test_trigger_flash.py`.** Mirror the existing `debug.flash.count` pattern in `GhosttyTerminalView.swift:7581`. Add counters for tab and sidebar fan-out. Closes the validation gap without violating the "no source-text tests" policy. Off the typing hot path, debug-only recording.
3. **Formalize `FlashEnvelope` as a single struct or factory.** `FocusFlashPattern` and `SidebarFlashPattern` share the values / keyTimes / duration / curves / `var segments` shape with the same `min(curves.count, values.count - 1, keyTimes.count - 1)` boilerplate. One factory removes ~12 lines per envelope and makes adding urgent / agent-voice / storm tiers a 5-line affair.
4. **Introduce `WorkspaceAttentionSignal` privately behind `triggerFocusFlash`.** Codex's framing is the cleanest: keep the existing public method as a compat shim, route internally through a `.focusFlash` signal. Do not over-generalize until a second signal kind exists. This is the one-step preparation for the named attention bus without requiring naming dialogue first.
5. **Add `lastFlashedAt: Date?` next to `Workspace.sidebarFlashToken`.** One published property, one assignment in `triggerFocusFlash`. Unlocks: sidebar decay overlay, "what flashed while I was away?", per-workspace mute by recency, attention audit log.
6. **Move the typing-latency invariant comment onto `==`.** The wall-of-`//` warning at `ContentView.swift:10905-10915` should be a `///` doc-comment on the `==` function so Xcode quick-help surfaces it the moment someone touches the comparator. Pure relocation, zero risk.
7. **Prepare a narrow upstream Bonsplit PR for `flashTab`.** Self-contained submodule diff, host-agnostic public API. Use upstream-friendly naming (e.g., `requestTabAttention` rather than c11's "flash"). Codex confirms parent pointer already references `78d09a44`.
8. **Add a `#if DEBUG` attention log.** A single `dlog("attention.fan-out panel=… layers=pane,tab,sidebar")` at `triggerFocusFlash` matches the existing `dlog("sidebar.close ...")` pattern. Subsystem becomes observable for free.

---

### 3. Wildest Mutations — Creative / Ambitious Ideas Worth Exploring

1. **OSC sequence handler for "attention from inside the terminal."** (Claude.) A c11-specific OSC (e.g., 1338) so `make` finishing, `pytest` first-failure, or `claude --dangerously-skip-permissions` finishing a turn can flash their own surface without the operator scripting anything. Routes through `triggerFocusFlash`. Requires checking collision with upstream Ghostty/cmux conventions before claiming a number.
2. **Per-agent flash temperament.** (Claude.) Plumb `requestedBy: AgentIdentity?` through the attention dispatch and let it influence color/curve. Gregorovitch's flashes slow and gold-tinted; a build watcher's sharp and red. Agent identity registers visually in the sidebar.
3. **Sidebar shimmer for attention storms.** (Claude, Gemini "Heatmaps".) When N workspaces flash within T seconds, fire a coalesced sidebar-wide low-amplitude pulse — the meta-signal "lots happened, look at the dashboard." A coarse-grained signal layered on top of the per-row signal.
4. **Attention as a recordable / replayable channel.** (Claude, Codex, Gemini all touched this.) Persist every fan-out event with surface id, timestamp, source. Becomes a *gaze record* — "what was the system trying to tell me in the last hour?" Composable with Lattice retro-AARs. Codex's "Attention Replay" debug command falls here.
5. **Agent Presence Radar / Spatial Breadcrumbs.** (Codex, Gemini.) Each agent surface emits typed-cause signals (done / blocked / needs review / error / waiting on human). Sidebar row becomes a compact radar; tab strip becomes a live map of background activity via persistent slow-pulsing auras instead of single transient pulses.
6. **Audio-haptic coupling.** (Gemini.) Tie the generation-token increment to a subtle spatial audio click or a macOS trackpad haptic tap. The polite visual nudge becomes a multi-sensory ambient cue. Most useful for accessibility and ambient awareness when the operator is not looking at the screen.
7. **Attention bidirectionality / "hover to point back."** (Claude.) Hovering a sidebar workspace row briefly flashes the focused tab in *that* workspace. Closes the loop the other way: operator pointing at workspace → workspace's current focus surfaces visually. Same primitive, opposite direction.
8. **Off-screen edge glows instead of forced scroll.** (Gemini.) When the flashed tab is outside `TabBarView`'s visible bounds, apply a transient gradient glow on the leading/trailing edge of the scroll mask rather than yanking the viewport with `proxy.scrollTo`. Less disruptive when the operator is actively reading. Codex's "scroll only on intensity tier" is the more conservative variant of the same insight.
9. **Command Palette Locate Mode.** (Codex.) Searching for a surface, workspace, PR, or process uses the attention fabric to *reveal in place* before navigating. The palette first answers "where is it?" — selection becomes a follow-up.
10. **Sidebar-only flashes for remote teammates.** (Claude.) When other operators in the same Lattice plan touch a surface, fire a sidebar-only ambient pulse on workspaces tied to that plan. The three-channel structure is already shaped for "polite ambient signal" — just connect the wire from Lattice events into `sidebarFlashToken`.
11. **"Trace this flash" debug command.** (Claude.) Right-click a flashing tab → "Trace flash source" → opens a debug surface listing the last N attention events with stack source (kbd / right-click / socket / notification / OSC / agent). Pure observability, pays off as the bus grows.
12. **Differentiated attention semantics as a vocabulary.** (Gemini.) Beyond intensity tiers: "Success Pulse" (green, fast), "Warning Throttle" (yellow, sustained), "Agent Thinking Glow" (slow, breathing). Couples color + rhythm + intensity into a small named lexicon agents can target.

---

### 4. Leverage Points and Flywheel Opportunities

#### Leverage Points (small change, disproportionate value)

1. **The shared `runFlashAnimation` helper** — one helper, four current callers, every future channel for free. Claude, Codex, and Gemini all rank this #1.
2. **Naming the attention bus now (privately or publicly)** — Codex's framing of "introduce the language now, restrain the API surface" is the cheapest path. Once codebase prose says "attention signal," future features route through the same primitive instead of scattering UI-specific verbs.
3. **A single `lastFlashedAt: Date?` field on Workspace** — unlocks four downstream features (decay overlay, away-summary, per-workspace mute, audit log) for one published property.
4. **Per-channel debug counters** — closes the validation gap, satisfies the c11 test-quality policy, and makes future channels CI-assertable for free.
5. **CLI surface (`c11 attention <surface>`)** — once exposed, the skill spreads it to every agent in the field. Lowest-friction path from primitive to ecosystem.

#### Flywheels (already spinning + engineerable next loops)

1. **Already spinning: every new trigger path gets all three channels for free.** Single fan-out at `triggerFocusFlash` means keyboard, right-click, v2 socket, notification routing — and any future agent-driven path — automatically light up pane + tab + sidebar. Each new caller increases channel value; each new channel increases caller value. This PR added the third spoke.
2. **Engineerable: agent calibration loop.** Skill teaches agents to call attention with intensity → operators leave low-intensity signals on because they whisper → agents see the operator notice and act → calibration data refines agent attention behavior → trust compounds → operators delegate more work → more attention requests, lower disruption per request. The flywheel is *trust as compound interest*, mediated by the gentleness of the lowest-intensity channel.
3. **Engineerable: shared primitive lowers the cost of every new channel.** Bonsplit tab strip, sidebar row, pane content become channel subscribers, not bespoke endpoints. The fifth and tenth attention surface (badge counts, scroll-to-row, edge glow, audio cue) cost a fraction of the first three because the substrate is in place. Codex's framing.
4. **Engineerable: "locate without selecting" reframes adjacent problems.** Search hits, command palette results, blocked-agent indicators, debug probes, "where did this terminal go?" — all currently solved (or not solved) via focus-stealing jumps — become spatial attention events using the same primitive. Codex calls this out explicitly; the design space "larger than notifications" is the prize.
5. **Engineerable: attention log → retro-AAR signal.** Persisted attention events become "where did the system point me, did I respond, was it right?" — a derivable answer composable with Lattice. Closes the operator-feedback loop on the calibration cycle in #2.

#### Final calibration warning (consensus across all three reviews)

The 0.18 / single-pulse / 0.6s sidebar channel is the load-bearing whisper. It is what makes leaving the toggle on tolerable in a 30-agent regime. **Future PRs that ratchet up peak opacity, pulse count, or duration in the name of "make it more visible" should be scrutinized hard.** The whole flywheel above depends on the gentlest channel staying gentle.
