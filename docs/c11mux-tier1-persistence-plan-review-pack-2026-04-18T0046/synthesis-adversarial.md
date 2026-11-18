# Adversarial Review Synthesis — c11mux Tier 1 Persistence Plan

**Plan under review:** `docs/c11mux-tier1-persistence-plan.md`
**Sources synthesized:**
- `adversarial-claude.md` (Claude Opus 4.7)
- `adversarial-codex.md` (Codex)
- `adversarial-gemini.md` (Gemini)
**Timestamp:** 2026-04-18 00:46

---

## Executive Summary

All three adversaries converge on the same diagnosis: **the plan is two plans in a trench coat** — a low-risk persistence/plumbing refactor (Phases 1–3) fused to a speculative, externally-dependent recovery UX (Phases 4–5) — and the fusion is hiding the weakest work behind the strongest. The plan reads as "80% built" only if you don't count identity-contract changes, type-system mismatches, and a heuristic join against Anthropic's undocumented filesystem as real work.

Three issues recur with near-unanimous weight:

1. **Phase 1 ("stable panel UUIDs") is the most dangerous phase, not the cleanest.** All three reviewers flag it as an under-scoped identity refactor that crosses constructors, restore logic, scrollback replay, and the socket API. Claude frames it as a contract change with no spec update; Codex points out that existing constructors hard-generate IDs and no restore-time injection path exists; Gemini echoes the regression risk.
2. **The metadata snapshot schema does not match the live store.** Codex and Gemini independently surface a type mismatch that is fatal on day one: the plan proposes `[String: String]`, but `SurfaceMetadataStore` holds `[String: Any]` with numeric canonical keys like `progress` (NSNumber, 0.0–1.0). This will either fail to compile, silently drop type information, or break canonical keys.
3. **Phases 4–5 depend on Anthropic's undocumented `~/.claude/projects/` layout as if it were a stable API.** All three reviewers flag this as the fragility that erodes trust in the feature the moment Anthropic ships a format change — and none of them believe the plan's fallback story is adequate.

Secondary but shared concerns: autosave fingerprint thrashing under high-frequency agent writes, unsafe `panel.send_text("claude --resume …\n")` injection when the terminal is not at a shell prompt, privacy posture shift from reading transcript files, and the fact that the companion workspace-metadata plan shares the autosave file without a joint-design note.

**Consensus recommendation (implicit across all three):** Split into Tier 1a (durability, Phases 1–3) and Tier 1b (recovery UX, Phases 4–5). Land 1a behind real measurement gates. Re-justify 1b after 1a and after M7 and Tier 2 settle.

---

## 1. Consensus Risks (Flagged by Multiple Models — Highest Priority)

Risks ordered by the strength and breadth of consensus.

1. **Phase 1 "stable panel UUIDs" is an identity-contract refactor, not a cleanup.** (Claude, Codex, Gemini)
   - Claude: deleting `oldToNewPanelIds` is framed as removing overhead but is "a change to an identity contract that crosses AppKit, Bonsplit, scrollback replay, and the socket API." That contract change is not written down and has no rollback switch.
   - Codex: current constructors (`TerminalSurface`, `TerminalPanel`, `BrowserPanel`, `MarkdownPanel`) "hard-generate IDs" and "do not accept restore-time IDs." The plan does not address adding injectable IDs across panel/surface constructors and callsites. This is load-bearing and larger than planned.
   - Gemini: flags UUID stability edge cases (duplicated workspace snapshots, dotfiles-synced sessions across machines) where collisions can occur in active instances.

2. **Metadata snapshot type mismatch with the live store.** (Codex, Gemini — fatal; Claude — indirectly via Codable concern)
   - Gemini: "`SurfaceMetadataStore` holds `[String: Any]` and explicitly validates `progress` as an `NSNumber` (0.0–1.0). This will cause compilation or runtime encoding failures immediately."
   - Codex: the proposed `[String: String]` shape "is structurally incompatible" with canonical numeric keys. Flattening `metadataSources` to `[String: String]` also loses the `{source, ts}` sidecar timestamp semantics.
   - Claude: raises the adjacent Codable concern around defaulting new fields on decode (`staleFromRestart: Bool`, `metadata: [String: String]?`), which would interact badly with any schema drift.

3. **`~/.claude/projects/` is a private, undocumented external dependency.** (Claude, Codex, Gemini)
   - All three flag this as brittle borrow-trouble. Anthropic has shipped format changes before (filename schemes, JSONL structure) and reserves the right.
   - Claude: estimates the stability-over-feature-lifetime assumption at ~40%.
   - Gemini: notes that when Anthropic moves to SQLite or a new path, the resume feature silently breaks, with no alarm, no metric, no fixture covering the new format.
   - Codex: calls it "private-internal dependency creep" — `observe from outside` becomes `depend on another tool's private on-disk format`.

4. **Autosave fingerprint thrashing under high-frequency metadata writes.** (Claude, Codex, Gemini)
   - Claude: OSC parsers and agent status pings can write every second; fingerprint bumps turn the 8s autosave into continuous writes with no instrumentation to detect it.
   - Codex: no real write-rate telemetry; hooking high-frequency metadata writes to autosave invalidation without measurement causes constant snapshot churn.
   - Gemini: explicitly names the "thundering herd" pattern — an agent spamming 10–20 `progress` updates per second guarantees a large payload hits disk every 8s, burning CPU, SSD life, and battery.

5. **`panel.send_text("claude --resume <id>\n")` is unsafe when the terminal is not at a shell prompt.** (Codex, Gemini)
   - Both flag the same failure mode: Vim, `nano`, a Python REPL, or a half-typed command line turns "Resume Claude session" into unintended execution or typing text into a user's code. No prompt detection, no confirmation, no dry-run, no safe-execution gate.

6. **Persisting "full contents" of the metadata blob without a whitelist is a responsibility/bloat trap.** (Claude, Codex, Gemini)
   - Claude: the metadata blob is open-ended (Module 2 spec), so c11mux becomes a durability provider for agent-chosen data — secrets, tokens, PII. Picked on implementation-simplicity grounds, not deliberated.
   - Codex: alternative is canonical keys + explicitly allowlisted custom keys first.
   - Gemini: rogue or sloppy agents can bloat the session file, "practically guaranteeing the 32 MiB worst-case scenario." Suggests ≤4 KiB cap for non-canonical keys.

7. **Schema version stays at v1 despite materially expanded semantics.** (Claude, Codex)
   - Claude: refusing to bump forces every future reader to special-case `nil` forever; a v2 bump now creates a branch point for future readers.
   - Codex: version neutrality now increases future ambiguity; bump and codify fallback decoding paths.
   - Gemini raises an adjacent version concern — no inner-payload versioning for the `metadata` dictionary.

8. **Agent-specific canonical keys (`claude_session_id`, `codex_session_id`) lock vendor naming into the reserved namespace.** (Claude, Codex)
   - Both recommend a neutral envelope (`agent_kind`, `agent_session_id`, and/or `resume_command`) so c11mux doesn't become an Anthropic/OpenAI compatibility shim.
   - Claude: "canonical keys are reserved namespace. Tying them to vendor names puts c11mux in the business of being an Anthropic/OpenAI compatibility shim."

9. **32 MiB snapshot ceiling is "accepted" without performance work.** (Claude, Gemini)
   - Claude: "not a decision, it's a capitulation." `JSONEncoder.encode` on 32 MiB is double-digit ms; atomic writes under memory pressure can spike to seconds.
   - Gemini: "synchronous JSON encoding is fast enough" is a dangerous assumption — `SessionPersistenceStore.save` appears to run synchronously for snapshot data construction, which will cause UI stuttering and frame drops.

10. **Companion workspace-metadata plan coordination is nominal, not designed.** (Claude, Codex)
    - Two independent persistence expansions writing to the same file, sharing the same autosave debounce, with no joint throughput/race analysis and no shared schema-change proposal.

11. **Phases 4–5 rely on a cwd-slug heuristic that is lossy and under-specified.** (Claude, Gemini)
    - Claude: `/` → `-` and leading `-` is lossy; `/foo-bar/baz` and `/foo/bar/baz` can collide; no mention of symlinked paths, worktrees, or cwds containing hyphens.
    - Gemini: plan assumes the slug algorithm is simple `/`→`-`; what about spaces, special characters, Unicode? If we don't know Anthropic's exact slugification rules, Phase 4 is "built on sand."

12. **Privacy posture shift from reading transcript files.** (Claude, Codex)
    - Transcripts contain user prompts, tool outputs, and code. Today c11mux doesn't read user documents; after Phase 4 it does — with no opt-out, no threat model, and no enterprise-data-handling story.

13. **Phase 5 title-bar chip collides with in-flight M7 work on the same file.** (Claude, Codex)
    - `SurfaceTitleBarView.swift` is already being churned by M7 (markdown rendering, chevron, hit targets). Shipping Phase 5 on top is a real coordination load the plan budgets as "coordinate via PR review" and nothing more.

14. **Value/effort asymmetry across phases.** (Claude, Codex)
    - Plumbing phases (1–3) are rigorously specified; user-visible recovery phases (4–5) are heuristic-heavy and underspecified. The phases that actually deliver the plan's motivating value are the weakest.

---

## 2. Unique Concerns (Raised by Only One Model — Worth Investigating)

### Claude-only

1. **Remote-daemon workspaces silently get no resume affordance.** `WorkspaceRemoteDaemonManifest` puts `~/.claude/projects/` on the remote, not the Mac. The plan scans local `~/.claude/` only — users will file this as a bug.
2. **Worktree / cwd-no-longer-exists fallback is unspecified.** If an agent was in `~/src/foo-wt-fix` and the worktree was deleted, "Reopen in `<dir>`" fails silently. No directory-existence check, no parent fallback, no recovery flow.
3. **`staleFromRestart` as a UX concept has no mock, no staleness threshold, and risks being louder than useful.** A sidebar with 15 workspaces half-italicized after restart may be worse than an empty sidebar.
4. **Scope-rot via canonical keys.** No single spec for what is canonical vs. custom; `<agent>_session_id`, `<agent>_session_started_at`, `<agent>_last_command` will proliferate.
5. **`SessionPersistenceStore.load` returns `nil` on decode failure — total snapshot loss.** No partial recovery for "one field is malformed, load the rest."
6. **First-save-after-upgrade erases pre-upgrade in-memory metadata.** Technically fine (it wasn't persisted before), but an undocumented migration-from-nothing story.
7. **Race between `SurfaceMetadataStore.removeSurface` (async) and the snapshot builder walking panel IDs.** Survivable, but the new `snapshot(for:)` method needs to be written with this race in mind.
8. **Transient metadata persistence window at panel close.** Metadata removed just before the 8s autosave tick is still on disk until the next save — a crash mid-window restores metadata for a deliberately-closed panel.
9. **`titleBarCollapsed` is locked as ephemeral with no real rationale.** "Simpler; revisit if users ask" is a deferral. Two years out, we'll wish we persisted it now.
10. **Filesystem watcher (`DispatchSource.makeFileSystemObjectSource`) is cheaper than the 30s cache.** Zero staleness, same code complexity. Not considered.
11. **`ClaudeSessionIndex` concrete-first instead of a `SessionIndex` protocol with one implementation.** The second agent integration already exists in the plan's own text — the abstraction is not premature.
12. **Fallback priority Claude > Codex > directory encodes an opinion about ownership** when a surface may have been started with Claude and restarted with Codex; recency-based fallback (`last_focused_at`) would be more honest.
13. **Phase 4 scan-timing is unspecified for restored surfaces.** Restored surfaces are neither created nor focused until user interaction — is the chip available before first focus?
14. **"External write wins" muddles Module 2's precedence model** (`explicit > declare > osc > heuristic`). c11mux's inference should be `heuristic`, not override explicit user writes.
15. **Localization is absent from the plan** ("Resume Claude session", "Reopen in `<dir>`", "Restore cwd"). Project CLAUDE.md requires Japanese + English in `Resources/Localizable.xcstrings`.
16. **CI wiring for `tests_v2/` additions is unaddressed.** Tests require a running cmux socket; the tagged-socket harness and CI wiring are not mentioned.
17. **No telemetry / early-warning metrics** for autosave frequency, snapshot size, session-index hit rate, or resume-chip click rate.
18. **"Observe from outside" principle is being spiritually compromised.** Reading agent-internal file layouts violates the spirit of `no-agent-hooks` even if it satisfies the letter. A public-channel alternative (stdin/MCP/CLI flag) is not considered.
19. **"Plan Phases 1–3 first" closing line is doing a lot of work** — the psychological commitment is to finish all five. Actually stopping at Phase 3 is not planned for.

### Codex-only

20. **Status entry fidelity loss on restore.** Persisted `SessionStatusEntrySnapshot` omits `url`, `priority`, and `format` that exist on runtime `SidebarStatusEntry` — either an intentional loss or an unnoticed one. The plan is silent.
21. **Autosave fingerprint blind spots beyond metadata.** The fingerprint currently hashes counts, not full values; status value changes at the same cardinality are already missed. Adding metadata revision alone leaves the adjacent blind spots.
22. **M2 spec amendment is required but not included.** Module 2 spec states metadata is in-memory only; this plan changes that contract without an explicit spec amendment / migration note.

### Gemini-only

23. **No garbage collection or aging for `staleFromRestart=true` chips.** Zombie status entries from crashed or uninstalled agents persist forever. Suggests a 24h drop rule or "drop when agent hasn't re-asserted."
24. **Disk wear and battery cost on laptops.** Continually serializing up to 32 MB every 8s during active agent sessions is hostile to SSD lifespan and battery. No user-visible opt-out.
25. **Main-thread blocking on encode.** `SessionPersistenceStore.save`'s snapshot construction is not safely on a background queue; large JSON encodes will block UI.
26. **"Restore historical context" vs. "drive active command execution" is not distinguished.** Those are two different trust bars — and Phase 5 conflates them under a single primary action.

---

## 3. Merged Assumption Audit (Deduplicated)

Assumptions, merged across all three reviews. For each, the consensus likelihood and load-bearingness.

1. **`oldToNewPanelIds` is pure overhead, not load-bearing.** *Load-bearing for Phase 1; failure cascades into 2–5.* Claude: ~80%. Codex: the remap exists to isolate a real ID-injection gap that this plan does not close. **Likely under-stated risk.**
2. **Panel/surface constructors can be retrofitted to accept restore-time IDs without a wider identity refactor.** *Load-bearing for Phase 1.* Codex: ID injection across `TerminalSurface`, `TerminalPanel`, `BrowserPanel`, `MarkdownPanel` and all restore callsites is not in the plan.
3. **Metadata values are strings.** *Fatal on day one.* Codex and Gemini: `SurfaceMetadataStore` stores `[String: Any]`; canonical `progress` is numeric. The proposed `[String: String]` either won't compile or will silently drop type info.
4. **`metadataSources` flattens to `[String: String]` without losing semantics.** *Load-bearing for Phase 2 correctness.* Codex: the live sidecar is `{source, ts}` per key; flattening loses timestamp, weakens precedence/debug behavior.
5. **Persisted `SessionStatusEntrySnapshot` is fidelity-complete for restore.** *Load-bearing for Phase 3.* Codex: URL, priority, format are missing from the persisted shape.
6. **`~/.claude/projects/` format is stable enough to key on.** *Load-bearing for Phases 4–5.* Claude estimates ~40% over feature lifetime; Gemini: "highly fragile"; Codex: "undocumented external storage format."
7. **Anthropic's cwd-to-slug algorithm is a simple `/` → `-` transform.** *Load-bearing for Phase 4 matching.* Claude: lossy on hyphens, symlinks, worktrees. Gemini: unknown behavior on spaces, special chars, Unicode. If we don't know the algorithm, Phase 4 is "built on sand."
8. **`claude --resume <id>` is a stable CLI contract.** *Load-bearing for Phase 5.* Claude: acknowledged by plan but hand-waved; no timeout, no failure detection, no test.
9. **Terminal is at a shell prompt when the resume chip fires.** *Load-bearing for Phase 5 safety.* Codex + Gemini: Vim/REPL/nano/half-typed text turn `send_text` into destructive noise.
10. **UUIDs are unique across time and machines.** *Load-bearing for Phase 1.* Gemini: dotfiles-sync across machines or duplicated workspace snapshots break this.
11. **Autosave fingerprint can absorb metadata mutations without thrashing.** *Load-bearing for I/O behavior across all phases.* Claude ~30% it degrades noticeably; Gemini: pathological for fast-progress agents; Codex: no telemetry exists.
12. **32 MiB worst case is acceptable.** *Load-bearing for perf.* Claude ~15% risk; Gemini: "not O(1) and will block the main thread unless explicitly moved to a background queue."
13. **Schema v1 survives additive optional dictionaries without decode surprises.** *Load-bearing for forward/backward compat.* Claude ~20% decode failure on version mixing (`staleFromRestart: Bool` default in Codable).
14. **Operators want a one-tap Claude resume.** *Load-bearing for Phase 5 justifying the effort.* Claude ~50/50 — no evidence, design guess dressed as requirement.
15. **`staleFromRestart` UX helps rather than clutters.** *Load-bearing for Phase 3 trust.* Claude: ~60% helpful, ~30% actively confusing. Gemini: no aging → permanent ghost accumulation.
16. **Synchronous JSON encoding of the full snapshot is fast enough.** *Load-bearing for UI responsiveness.* Gemini: dangerous; Claude: ~15% performance bite. Plan has no measurement gate.
17. **Agent updates to canonical keys are low-frequency.** *Load-bearing for I/O and battery.* Gemini: spinners/progress bars can easily hit 10–20 writes/sec.
18. **Persisting full arbitrary metadata blobs is safe.** *Load-bearing for snapshot size bounds and privacy.* Claude + Gemini: rogue or careless agents can bloat to the 32 MiB ceiling.
19. **Phase 4 tests against synthetic fixtures are adequate.** *Load-bearing for catching format drift.* Claude: no real-format test; when Anthropic rev's the format, nothing alarms.
20. **Reading transcript files is within c11mux's current privacy posture.** *Load-bearing for rollout safety.* Claude + Codex: no threat model, no opt-out, no enterprise story.
21. **The companion workspace-metadata plan and this plan can ship independently.** *Load-bearing for coordination.* Claude + Codex: shared file, shared debounce, no joint design.
22. **Cache invalidation at 30s is sufficient for the session index.** *Load-bearing for Phase 4 freshness.* Claude: filesystem watchers are cheaper and near-zero staleness; 30s is instinct not analysis.
23. **Stable panel UUIDs are not a socket-API contract change.** *Load-bearing for external consumers.* Claude: the implicit contract ("panel IDs may change on restart") is reversed by this plan and not documented anywhere.
24. **`statusEntries` and `agentPIDs` were dropped on restore for no good reason.** *Load-bearing for Phase 3.* Claude: the existing code comment ("ephemeral runtime state tied to running processes") is a message from the past; the plan reverses it in one paragraph.
25. **The plan's 5 phases will actually be delivered together by one agent.** *Load-bearing for the overall framing.* Claude + Codex: the likely outcome is that Phases 1–3 ship and 4–5 stall or ship half-built.

---

## 4. The Uncomfortable Truths (Recurring Hard Messages)

Messages that appear, in some form, in two or three of the reviews.

1. **The plan is two plans.** Durable metadata (easy, mostly done) and agent-specific crash recovery (hard, trust-sensitive, externally coupled) are merged into one Tier, which lets the easy half tow the hard half across the finish line with a flimsy joint. (Claude + Codex)
2. **Phases 4–5 are speculative UI on a private external dependency.** Building a durable affordance on top of `~/.claude/projects/` is borrowing trouble. The plan acknowledges this in passing and then builds the chip anyway. (Claude + Codex + Gemini)
3. **Phase 1 is the most dangerous phase and gets the lightest risk treatment.** Framed as a deletion, it is an identity-contract change touching the socket API and cross-cutting constructors. (Claude + Codex + Gemini)
4. **The "80% built" framing is true for plumbing and false for identity stability and recovery UX.** (Claude + Codex)
5. **The plan will likely ship durable metadata before it ships reliable recovery** — producing a perception gap between what the motivation promises and what users get. (Codex + Claude)
6. **`SurfaceMetadataStore` is being asked to become a durable database but is architected like an ephemeral cache** (`[String: Any]`). The type system hasn't caught up to the plan. (Gemini + Codex)
7. **The 32 MiB ceiling is a capitulation, not a decision.** Nobody did the work to think about streaming, per-panel files, or incremental writes. (Claude + Gemini)
8. **"Observe from outside" is being spiritually compromised by reading another tool's private on-disk format.** The principle was a guideline; the plan treats it as a constraint that closes off better designs (cooperative channels). (Claude + Codex)
9. **The "ship small, Phases 1–3 first" closing line sounds like restraint but isn't.** The plan lists five phases with concrete deliverables; the psychological commitment is to finish all five. Actually stopping at Phase 3 is not planned for. (Claude, echoed by Codex's split recommendation)
10. **This can become a maintenance burden disguised as a reliability feature.** Without stronger guardrails, the feature trends toward a long-tail of subtle inaccuracies that erode trust in c11mux as an agent host. (Codex + Claude)

---

## 5. Consolidated Hard Questions for the Plan Author

Deduplicated, grouped by theme, and numbered. Questions that appeared in multiple reviews are tagged with source initials in parentheses (C = Claude, X = Codex, G = Gemini).

### A. Phase 1 — Stable Panel UUIDs

1. Why was `oldToNewPanelIds` added originally? What did the original author know that isn't in this plan? (C)
2. How exactly will restored panel IDs be injected, given current constructors (`TerminalSurface`, `TerminalPanel`, `BrowserPanel`, `MarkdownPanel`) always generate UUIDs? (X)
3. What is the rollback switch if stable-ID restore causes regressions in focus/scrollback/layout flows? Why is there no feature flag (e.g., `CMUX_DISABLE_STABLE_PANEL_IDS=1`) for the first release or two? (C, X)
4. Does the new ID-stability contract need to be written into the socket-API reference doc? Who is the named owner for that spec update? (C)

### B. Phase 2 — Metadata Persistence Schema

5. How will you serialize `progress` (an `NSNumber`, 0.0–1.0) into `var metadata: [String: String]?` without crashing or breaking compilation? More generally, how does `[String: String]` survive contact with `[String: Any]`? (X, G)
6. Why does the plan's proposed `metadataSources: [String: String]` drop the `{source, ts}` sidecar timestamp that the live store maintains? (X)
7. Why is the schema version not bumped when snapshot semantics expand materially? What does the future v2 reader do with a v1 snapshot that has implicit `nil` metadata? (C, X)
8. Why persist "full contents" with no whitelist instead of canonical keys + explicitly-allowlisted custom keys (or a ≤4 KiB cap for non-canonical)? What's the answer when a rogue agent bloats snapshots toward 32 MiB? (C, X, G)
9. What is the Module 2 spec amendment for moving metadata from "in-memory only" to durable? Where does it live? (X)

### C. Phase 3 — Status Entry Restoration

10. Are you intentionally dropping `url`, `priority`, and `format` from `SessionStatusEntrySnapshot` on restore, or is that an unnoticed fidelity loss? (X)
11. How do we purge `staleFromRestart=true` entries if the agent never runs again? Do zombie chips stay forever, or is there a 24h / next-write aging rule? (C, G)
12. What is the UX-quality threshold for `staleFromRestart`? A sidebar with 15 workspaces half-italicized after restart — is that a feature or a regression? Where is the mock? (C)
13. The existing code comment (`Workspace.swift:246`) said `statusEntries` and `agentPIDs` are "ephemeral runtime state tied to running processes." What changed about that reasoning? (C)

### D. Phase 4 — Claude Session Index

14. What is Anthropic's stability commitment on the `~/.claude/projects/` layout? If the answer is "none," where is the fallback when they change it? What is the alarm, what is the metric, what is the test fixture? (C, X, G)
15. What is the exact algorithm Claude uses to convert a cwd to a slug? What is the behavior on spaces, Unicode, hyphens, symlinked paths, and git worktrees? If "we don't know," why is Phase 4 not gated on finding out? (C, G)
16. What privacy/threat-model review has been done for c11mux reading transcript files (prompts, tool outputs, code snippets)? Is there a user-visible opt-out (e.g., `CMUX_DISABLE_SESSION_INDEX=1`)? (C, X)
17. How does Phase 4 behave on a remote-daemon workspace, where `~/.claude/` is on the remote and not on the Mac? (C)
18. Why a 30s polling cache instead of a `DispatchSource` filesystem watcher with near-zero staleness? (C)
19. What test harness runs against the real Claude file format, not synthetic fixtures? When is format drift detected, and how? (C, X, G)
20. What happens when the 32 MiB worst case actually occurs — concretely, `JSONEncoder.encode` + atomic write cost on an 8-core Mac mini under memory pressure? If "we don't know," add a measurement gate to Phase 2. (C, G)
21. What are the concrete correctness metrics for Claude association — precision, recall, and false-positive rate of cwd-slug matching? (X)
22. What is the explicit precedence rule when inferred session IDs conflict with declared/explicit writes? Does "external write wins" override the Module 2 model (`explicit > declare > osc > heuristic`)? (C, X)

### E. Phase 5 — Resume Chip / Recovery UX

23. How do we guarantee that `panel.send_text("claude --resume <id>\n")` won't execute destructively if the terminal is not at a clean shell prompt (Vim, nano, Python REPL, half-typed text)? What's the prompt-detection, confirmation, or dry-run policy? (X, G)
24. Is there actual evidence that operators want a one-tap Claude resume — user interviews, issue reports — or is this a designer's hypothesis? If the latter, where is the telemetry stub to measure use? (C)
25. Is the intended outcome "restore historical context" or "drive active command execution"? Those are different trust bars and should not share the same default action. (G)
26. Why a title-bar chip rather than a command-palette menu that gives operators the full recovery menu (resume, reopen cwd, copy last command, view transcript, start fresh)? (C)
27. What is the fallback chain policy when multiple agents ran on a surface (Claude then Codex)? Why priority Claude > Codex > directory instead of recency-based? (C)
28. What localizations are needed for Phase 5 strings, and are they planned for `Resources/Localizable.xcstrings` (English + Japanese)? (C)
29. What happens when `<dir>` in the "Reopen in `<dir>`" fallback no longer exists (deleted worktree, moved project)? (C)
30. What phase exit criteria prove Phases 4–5 are trustworthy enough to expose as a primary recovery affordance? (X)

### F. Architecture, Coordination, and Naming

31. Why commit to agent-specific canonical keys (`claude_session_id`, `codex_session_id`) now instead of a neutral session envelope (`agent_kind`, `agent_session_id`, `resume_command`)? Has this been debated, or is it the expedient default? (C, X)
32. Why is `ClaudeSessionIndex` concrete rather than a `SessionIndex` protocol with one implementation, given Codex and Gemini are already named as follow-ons in the same plan? (C, X)
33. How will this plan coordinate with the companion workspace-metadata plan so autosave/fingerprint behavior stays coherent? Two writers, one file, one debounce — where is the joint design note? (C, X)
34. When M7 ships and `SurfaceTitleBarView.swift` is in a different shape than you expect, who owns the rebase? Is there a named owner for the Phase 5 / M7 coordination? (C, X)
35. What is the plan if Tier 2 PTY persistence lands earlier and changes the value proposition of Phase 5? Have Phases 4–5 been re-justified against that scenario? (C, X)
36. What is the commitment (week? quarter?) for Codex and Gemini parity? The asymmetry will be visible the moment an operator uses Codex and sees no resume chip. (C)
37. Have you considered *not* building Phases 4 and 5? Phases 1–3 stand on their own; what's the plan if after Phase 3 the team decides recovery UX should live elsewhere (Lattice, Spike)? (C)

### G. I/O, Perf, Telemetry

38. What is the current lived rate of `surface.set_metadata` writes in a typical session? Without that, autosave-fingerprint-thrashing risk is unquantified. If "we don't know," make a week-1 measurement a precondition for Phase 2. (C, X, G)
39. What happens to battery life and SSD wear when an agent updates `progress` 10–20 times/sec for hours? (G)
40. Is snapshot encoding moved to a background queue? Today `SessionPersistenceStore.save` appears to do snapshot construction synchronously — what's the UI-latency budget on 32 MiB? (G)
41. What early-warning metrics exist (autosave writes/min, snapshot size >10 MiB, resume-chip click rate, session-index hit rate, inferred-session overwrite rate)? None are in the plan. (C, X)

### H. Testing, Tooling, CI

42. Are the `tests_v2/` additions CI-wired? Per project CLAUDE.md, socket tests run on CI/VM, not locally. What's the story for `test_panel_id_stability.py` and siblings? (C)
43. What's the test plan against the *real* Claude file format, not synthetic fixtures? Who updates fixtures when Anthropic rev's, and when is that update detected? (C, X, G)
44. What is the safe-execution gate for Phase 5 command injection, and where is it tested? (X, G)

### I. Lifecycle, Recovery, Data Hygiene

45. What is the partial-recovery policy when `SessionPersistenceStore.load` finds a snapshot with one malformed field? Today the whole thing is discarded — what's the minimum-viable partial restore? (C)
46. What happens to pre-upgrade in-memory metadata on first-save-after-upgrade? (C)
47. What is the race policy between `SurfaceMetadataStore.removeSurface` (`queue.async`) and the snapshot builder walking panel IDs? (C)
48. What's the policy for the 8s window between panel close and autosave, where the on-disk snapshot still has stale metadata for a deliberately-closed panel? (C)
49. Why is `titleBarCollapsed` locked as "stay ephemeral"? What would change that decision, and why not now while you're already in the snapshot code? (C)

---

**Closing.** The convergence across three independent adversaries is strong enough to act on without deliberation: (a) split durability (1–3) from recovery UX (4–5); (b) fix the `[String: Any]` vs. `[String: String]` mismatch before any Phase 2 code is written; (c) scope Phase 1 as the identity refactor it actually is, with a rollback flag and a socket-API contract update; (d) gate Phase 4 on measurement of Anthropic's slug algorithm and on a privacy opt-out; (e) gate Phase 5 on a safe-execution policy for `send_text` injection and on evidence that operators actually want the affordance. Everything else in this synthesis is downstream of those five moves.
