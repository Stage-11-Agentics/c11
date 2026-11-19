# Adversarial Plan Review — c11mux Tier 1 Persistence

**Plan:** `c11mux-tier1-persistence-plan`
**Model:** Claude (Opus 4.7)
**Role:** Designated Adversary
**Timestamp:** 2026-04-18 00:48

---

## Executive Summary

The plan looks clean because it is mostly a surface on top of machinery that already works (`SessionPersistence`, the 8s autosave, panel snapshots). That cleanness is hiding three things the plan has not actually reckoned with:

1. **"Stable panel UUIDs" is advertised as a trivial simplification but is the riskiest change in the plan.** It is a change to an identity contract that crosses AppKit, Bonsplit, scrollback replay, and the socket API. The plan frames it as "remove the remap," which is exactly the frame that causes this kind of change to ship with a subtle regression.
2. **The "observe from outside" claim for Claude sessions is load-bearing for Phase 4/5 and is the weakest part of the plan.** cwd-slug matching is a soft join. It will be wrong often enough to be a trust problem: agents will get offered resumes to sessions they don't want, and that is worse than no resume at all.
3. **Phases 4 and 5 are the only phases that deliver user value, and they are the phases the plan treats with the least rigor.** Phases 1–3 are plumbing. Phase 4 is "scan a directory and guess." Phase 5 is "render a chip and call `claude --resume`." The plan's effort is inverted relative to the risk.

Single biggest issue: **the plan conflates "persist metadata" (easy, low-risk, mostly done) with "recover work after a crash" (hard, trust-sensitive, agent-specific).** Tier 1 as framed is two plans in a trench coat. Splitting them would make both better; merging them like this lets the easy half drag the hard half across the finish line with a flimsy joint in the middle.

Concern level: **moderate-high.** The plan is likely to ship Phases 1–3 and stall at 4–5, or ship 4–5 in a form that erodes trust in c11mux as an agent host.

---

## How Plans Like This Fail

Patterns I'd apply to this specific plan:

**The "just remove the indirection" trap.** Refactors that delete a mapping layer *always* look cleaner in the plan than in the PR. `oldToNewPanelIds` exists because someone, at some point, needed it — or because the author was defensive. Defensive code that looks unnecessary is frequently load-bearing for a case nobody remembers. This plan's Phase 1 risk section dismisses "concurrent write of a second snapshot with overlapping UUIDs" in one sentence. That's the sentence I would expect to be wrong — not because the UUIDs collide (they won't), but because the *lifecycle assumption* (panels are created in the app, snapshot is source of truth per workspace) does not survive contact with: drag-and-drop of tabs across workspaces, multi-window snapshots, undo/redo, or a race between a mid-flight `newTerminalSurface` and a session restore.

**The "it's already ~80% built" fallacy.** When a plan opens with "this is already mostly there," the last 20% is where three weeks of corner cases live. The plan treats persistence as solved because `SessionPersistence` writes most fields. But the discarded-on-restore fields (`statusEntries`, `agentPIDs`) were discarded *on purpose*, with a clear comment (`Workspace.swift:246`: "ephemeral runtime state tied to running processes"). The plan reverses that decision in one paragraph. That comment is a message from the past saying "we considered this and said no." The plan owes the reader an argument for why that reasoning was wrong, not just a `staleFromRestart` flag.

**The "observer becomes a spy" pattern.** Plans that start with "we observe from outside without cooperation" usually converge over time into "actually we need the tool to cooperate for this to be useful." Once c11mux starts reading `~/.claude/projects/`, it is inheriting Anthropic's file-format as an API contract. That format is not an API. It is an internal detail that Claude Code reserves the right to change. The plan acknowledges this in passing (Open Question 5) but builds the UI chip around it anyway.

**Scope rot via "canonical keys."** Adding `claude_session_id` to the canonical metadata namespace is a Module 2 spec amendment. The plan writes it into metadata without calling that out. In a year, c11mux will have a handful of `<agent>_session_id` keys, a `<agent>_session_started_at`, a `<agent>_last_command`, and no single spec of what is canonical and what is custom. This is how reserved namespaces rot.

**The "autosave covers for us" assumption.** The plan bolts metadata changes into the autosave fingerprint with a monotonic counter. The 8s debounce plus a counter bump per write means every call to `surface.set_metadata` invalidates the fingerprint and triggers a save cycle on the next tick. If the metadata store is being written from heuristic OSC parsers and periodic agent status pings, the fingerprint becomes noisy. At the limit, you've turned an 8s autosave into a continuous write loop, and the plan doesn't analyze this.

**The "we'll localize it later" gap.** Phase 5 introduces user-facing strings ("Resume Claude session", "Reopen in `<dir>`", "Restore cwd") without any reference to `Resources/Localizable.xcstrings`. The project CLAUDE.md is unambiguous: all user-facing strings must be localized in English and Japanese. This is how plans accrue a debt that ships.

---

## Assumption Audit

Load-bearing assumptions, ranked by how much of the plan collapses if they're wrong:

1. **`oldToNewPanelIds` was pure overhead, not load-bearing.** Load-bearing for Phase 1; Phases 2–5 inherit the breakage if this is wrong. The plan's argument is "UUIDv4 collision is negligible" — correct but answers the wrong question. The real question is: does any code path ever *want* a panel to be re-IDed on restore? E.g., to avoid confusing a live observer that still has the old ID cached. The plan doesn't even ask this question. Likelihood it holds: **~80%**. Not 99%. Someone added that remap for a reason.

2. **`~/.claude/projects/` format is stable enough to key on.** Load-bearing for Phases 4 and 5. Claude Code has shipped format changes in the past (filename schemes, JSONL structure). The plan says "jsonl parsing reads first and last lines only — cheap even for multi-megabyte transcripts" — this assumes jsonl, assumes one session per file, assumes the first line has useful metadata and the last line has a useful timestamp. All true today. Likelihood it holds **over the lifetime of this feature** (months to years): **~40%**. Anthropic reserves the right.

3. **The cwd-slug transform is bijective enough to trust.** `/` → `-` and leading `-` is lossy: `/foo-bar/baz` and `/foo/bar/baz` both map to something involving `-foo-bar-baz`. The plan assumes the slug uniquely identifies a cwd. Likelihood: **~85%** on common cwds, but there are edge cases (symlinked paths, worktrees with `/` in branch names, cwds with hyphens) where it silently fails. The plan has no mention of this.

4. **Operators want session resume at all.** Load-bearing for Phase 5 justifying the effort. An operator who lost ten panes to a crash may not want to "resume the Claude session" — they may want to see what the agent was doing, decide whether to continue or redirect, and then act. A one-tap resume is an opinionated UX choice that assumes continuation is the default. Likelihood operators want this specific affordance (vs. "reopen cwd + show last transcript summary"): **~50/50**. The plan has no evidence either way — this is a design guess dressed as a requirement.

5. **`staleFromRestart` conveys the right thing.** Load-bearing for Phase 3's trust model. A restored status chip with italicized styling is supposed to tell the operator "this is old." In a sidebar with 15 workspaces, half italicized after a restart, the visual noise is worse than an empty sidebar. The plan has no mock, no visual threshold for "how much staleness before we just hide it," and no rule for when a pre-restart status "Running" should be shown vs. suppressed. Likelihood the UX actually helps: **~60%**. Likelihood it actively confuses: **~30%**.

6. **Autosave fingerprint can absorb metadata mutations without thrashing.** The plan picks option (1) — monotonic counter. Assumes the counter bumps at a rate that won't force constant writes. If M1's heuristic detector or an agent that polls progress/status writes every second, we're saving every 8s regardless of whether the user touched the app. Likelihood this degrades I/O behavior noticeably: **~30%**, and there's no instrumentation plan to detect it.

7. **The 64 KiB × 512 panels = 32 MiB ceiling is acceptable.** The plan says "accepted" without showing the work. 32 MiB JSON on every 8s autosave cycle is not free. `JSONEncoder.encode` on a 32 MiB graph is double-digit milliseconds; atomic writes through the filesystem can spike to seconds under memory pressure. The plan has no plan for measuring the actual distribution. Likelihood it becomes a performance concern: **~15%** (most sessions won't hit it), but the plan has no guardrail if it does.

8. **Schema v1 truly survives adding two optional dictionaries.** Older app versions reading newer snapshots work *if* they ignore unknown keys, which `JSONDecoder` does by default. But the plan also says "new fields are optional, decoded with defaults." Defaulting a `[String: String]?` to `nil` is fine; defaulting `staleFromRestart: Bool` on `SidebarStatusEntry` requires a Codable custom init or a default value. The plan doesn't specify which. Likelihood of a subtle decode failure when an old snapshot meets a new binary: **~20%**.

Cosmetic assumptions (not load-bearing):
- Phase 1 tests in `cmuxTests/` will catch the remap-removal regression. Probably won't — the failure mode is spatial/layout, which these tests don't exercise.
- Phase 4's 30s cache is sufficient. Probably fine for the scan cost.
- `agentPIDs` are safe to keep cleared. Correct.

---

## Blind Spots

What the plan doesn't mention and should:

**Privacy and multi-user.** `~/.claude/projects/` contains *conversation content* — user prompts, tool outputs, code snippets. The plan has c11mux reading it, caching first/last lines, and displaying previews (`firstUserMessagePreview: String?` for hover tooltip). On a machine with multiple users, or with sensitive prompts, this is a privacy posture change for c11mux. Today c11mux doesn't read user documents. After Phase 4, it does. No threat model, no opt-out, no mention of what happens in enterprise contexts where session transcripts may be considered sensitive.

**The remote-daemon case.** `Sources/Workspace.swift` has `WorkspaceRemoteDaemonManifest` and remote-daemon machinery. If a workspace is connected to a remote host, `~/.claude/projects/` is on the remote, not on the Mac. The plan scans local `~/.claude/` only. Remote workspaces silently get no resume affordance. This is worth calling out — otherwise a user will file it as a bug.

**Worktrees and git branches.** If an agent was working in a git worktree on branch `fix/foo` and cwd is `~/src/foo-wt-fix`, a session resume that drops the user back into that cwd is useless if the worktree has been deleted. The plan's fallback chain ("Reopen in `<dir>`") fails silently when `<dir>` no longer exists. No mention of directory-existence checking, no fallback to the parent, no "this directory is gone, pick another" flow.

**The `claude --resume` command is unstable.** The plan assumes `claude --resume <id>` works. It works today. The CLI surface of Claude Code is not a stable contract — there's no compatibility guarantee. Open Question 5 acknowledges this but hand-waves: "a small toast + fallback to 'Start fresh Claude session.'" No spec for how the chip detects the failure, no timeout, no test plan.

**Codex and Gemini parity is promised but not planned.** The plan says "plan a parallel `CodexSessionIndex`" for Codex and "investigate" for Gemini. Those are not plans. If Codex session files follow a different shape (which they likely do), the abstraction point isn't obvious yet, and shipping Claude-only in v1 will freeze the metadata-key naming (`claude_session_id` vs. a more neutral key). The plan accepts this freeze without debating it.

**Interaction with the in-flight M7 work.** `SurfaceTitleBarView.swift` is the target for Phase 5's resume chip. The M7 amendment (currently in-flight) is already churning this file — adding markdown rendering, chevron repositioning, hit targets, the expanded-state logic. Phase 5 adds more. The plan mentions "should coordinate via PR review" once and moves on. Two agents editing `SurfaceTitleBarView.swift` at the same time is a real coordination load that the plan doesn't budget for.

**The companion workspace-metadata plan's coverage.** The companion plan (`c11mux-workspace-metadata-persistence-plan.md`) introduces `Workspace.metadata: [String: String]` and a `workspace.set_metadata` socket method. The Tier 1 plan introduces `SurfaceMetadataStore` persistence. They are claimed to be orthogonal (surface-level vs. workspace-level). But the *observer pattern* ends up being: workspace metadata triggers autosave via workspace mutation, surface metadata triggers autosave via a fingerprint bump. Two mechanisms, shared file, shared debounce. If both land, the interaction (two writers, one file) deserves a design note. The plan has none.

**Testing policy compliance.** Project CLAUDE.md is explicit: "Never run tests locally" — tests run on CI. The plan adds `tests_v2/test_panel_id_stability.py`, `tests_v2/test_m2_metadata_persistence.py`, etc. These all require a running cmux instance's socket. The plan doesn't mention the tagged-socket harness or CI wiring. For an agent writing these tests, this is a non-trivial gap — the plan implies they'll "just run," and they won't.

**CI / autosave I/O on battery.** cmux is a desktop app. On battery, 32 MiB writes every 8s when metadata is churning is a power-consumption pattern worth testing. No mention.

**Snapshot corruption recovery.** `SessionPersistenceStore.load` returns `nil` on decode failure. Fine. But if the new fields are somehow malformed (e.g., a crash mid-write produces a partial file, even with atomic write the contents could be valid JSON but missing required fields), the whole snapshot is discarded and all workspaces evaporate. The plan doesn't reason about partial recovery — "our new field is malformed, but the rest of the snapshot is fine; load the rest." That pattern gets more important as the snapshot grows.

**Upgrade path from in-memory to on-disk.** First launch after shipping Phase 2: everyone's snapshot has no `metadata` field. That's handled (optional). But first *save* after upgrade: the metadata store is empty in memory (since the app just launched), so the snapshot's `metadata` is also empty. The user's pre-upgrade metadata is... gone. Technically fine since it wasn't persisted before, but the plan doesn't explicitly address "nothing to migrate from" — a future reader will assume there's migration logic and there isn't.

**Concurrency with `removeSurface`.** `SurfaceMetadataStore.removeSurface` uses `queue.async` (line 319–324). Snapshots at save time read via `queue.sync` through `getMetadata`. If a `removeSurface` is in-flight when the snapshot builder walks panel IDs, a panel could have its metadata removed between the builder taking the panel list and calling `snapshot(for:)`. The result is a missing key, which is survivable, but the plan's new `snapshot(for:)` method should be written with this race in mind and the plan should say so.

**What happens to metadata on panel close during a session.** `pruneSurfaceMetadata` runs on restore. During a running session, when a panel closes, `removeSurface` fires. Today metadata is in-memory, so this is fine. After Phase 2, the *next* autosave will persist the absence. But between close and autosave, the on-disk snapshot still has the metadata. On a crash in that 8s window, the restored surface has stale metadata for a panel that was deliberately closed. Minor, but undocumented.

---

## Challenged Decisions

**Decision: "Full contents, no whitelist" for the metadata snapshot.**
Counterargument: the metadata blob is open-ended. Agents can write arbitrary JSON (per Module 2 spec). Persisting that verbatim means c11mux becomes a durability provider for agent-chosen data — secrets, tokens, PII, anything an agent decides to stash. A whitelist (canonical keys only, plus `c11mux:`-prefixed custom keys) would put c11mux back in control of what it durably stores. The plan picks "full contents" on implementation-simplicity grounds without weighing the responsibility tradeoff. This feels like a default, not a deliberate choice.

**Decision: "Schema stays at v1."**
Counterargument: version numbers exist so that *future* code can make different decisions about how to read *past* data. By refusing to bump the schema even as the shape changes materially, the plan is optimizing for the convenience of today's migration story at the cost of tomorrow's branch point. A v2 bump now (even with identical field contents) gives the next change room to say "on v2, we assume `metadata` is present; on v1 we default it." The plan's current stance forces every future reader to special-case nil forever.

**Decision: Canonical key `claude_session_id` (agent-specific) rather than a neutral `agent_session_id`.**
Counterargument: canonical keys are reserved namespace. Tying them to vendor names (`claude_*`, `codex_*`) puts c11mux in the business of being an Anthropic/OpenAI compatibility shim. A neutral schema (`agent.type = "claude-code"`, `agent.session_id = "<uuid>"`) cleans this up and composes with `terminal_type` which already exists. The plan picks the expedient name without debating the schema.

**Decision: Phase 5 title-bar chip over Phase 5 command palette.**
Counterargument: "Resume Claude session" in the title bar is a committed UX slot for one command. A restored surface likely needs multiple options (resume Claude, open cwd, copy last command, see transcript, start fresh). A title-bar chip forces all of that into a single primary action with a fallback chain. A command-palette-style menu (Cmd+Shift+R on a restored surface → pick your recovery action) gives operators the full menu without burning title-bar real estate. The plan doesn't consider alternatives to the chip.

**Decision: The `ClaudeSessionIndex` is concrete, "avoid premature abstraction."**
Counterargument: the author already names Codex and Gemini as follow-ons. The abstraction isn't premature — the second instance exists in the plan's own text. Shipping `ClaudeSessionIndex` as a concrete module means the second integration will be written by a different author (or the same author months later) with different intuitions, and the generalization will be awkward. Naming the protocol now (`AgentSessionIndex`) with one implementation is cheaper than retrofitting it later.

**Decision: Cache `ClaudeSessionIndex` results for 30s.**
Counterargument: 30s is a number pulled from instinct. If an operator starts a new Claude session and then opens c11mux to check on it, 30s of staleness shows "no session" when one just started. A file-system watcher (`DispatchSource.makeFileSystemObjectSource`) on the `~/.claude/projects/` directory would give you near-zero staleness without polling. The plan didn't consider watch-driven invalidation.

**Decision: `staleFromRestart` as a visual treatment only.**
Counterargument: stale entries also pollute sidebar status counts, filtering, and any future automation that reads status. Treating them as a display-only flag means consumers downstream still see them as current. An entry that is "in snapshot but not re-affirmed by the runtime" could just not be exposed until re-affirmed, with a separate "last known state" API for debugging. The plan picks the more visible-in-UI approach, which also has a higher blast radius if the flag is interpreted inconsistently.

**Decision: Fallback chain in Phase 5 prioritizes Claude > Codex > directory.**
Counterargument: the priority encodes an opinion about which agent "owned" the surface. But a surface might have multiple runs — started with Claude, restarted with Codex. The metadata records both if both wrote. The fallback chain picks Claude. A recency-based fallback (`last_focused_at` on each `<agent>_session_id`) would be more honest. The plan's chain is a default, not a considered design.

---

## Hindsight Preview

Two years out, the things we'll wish we'd done:

1. **"We should have persisted `titleBarCollapsed`."** Locked decision #4 parks it as "simpler; revisit if users ask." Users will ask. Or worse, they'll silently notice it resets every time and lose trust in the app's "remember my state" behavior. The cost to persist it now is two fields on a snapshot; the cost to add it later is the same two fields plus a commit explaining why we changed our mind. Do it now.

2. **"We should have defined a `SessionIndex` protocol up front."** Claude-only will ship, Codex will appear 2–3 months later, and the second author will write a parallel module instead of generalizing. The abstraction debt compounds.

3. **"We should have watched the filesystem instead of polling."** `DispatchSource` watches would have been ~same code complexity and zero staleness. 30s cache will cause at least one "why didn't my session show up?" bug report.

4. **"We should have kept metadata writes out of the autosave fingerprint by default."** Once we're triggering autosave on every heuristic/status write, the autosave becomes non-idle-aware. Moving heuristic-source writes to a lower-priority "lazy persist" bucket is the thing we'll wish we'd done before the I/O pattern calcified.

5. **"We should have namespaced `claude_session_id` under `agent:`."** Canonical key proliferation is a known trap; we entered it willingly.

6. **"We should have made Phase 4 opt-in."** Users who don't want c11mux reading `~/.claude/projects/` have no switch. A `CMUX_DISABLE_SESSION_INDEX=1` env var costs nothing to add and covers the privacy-conscious case.

Early warning signs the plan should watch for but doesn't build mechanisms to detect:

- Autosave fingerprint changes per second — watch for this exceeding some threshold (e.g., > 2/s sustained) as a signal that metadata writes are pathological.
- Snapshot file size over time — add a metric, log a warning above 10 MiB.
- `ClaudeSessionIndex` hit rate — if > 5% of focus events fail to find a session despite agents running, the cwd-slug heuristic is broken; if > 1% of matches come back with wildly-different timestamps, the recency window is wrong.
- User rejections of the resume chip — if the chip is offered N times and clicked <5%, it's noise; suppress.

None of these metrics are in the plan.

---

## Reality Stress Test

Three likely disruptions, hitting simultaneously:

**Disruption A: M7 amendment agent ships a privatization of `sanitizeDescriptionMarkdown` / `titleBarMarkdownTheme`, and reflows `SurfaceTitleBarView.swift`.**
Phase 5 wants to add a resume chip to the same file. Merge conflicts in a file that just had its structure churned by M7 will be painful. Phase 5 loses a day or two to rebase.

**Disruption B: Anthropic ships a Claude Code update that changes `~/.claude/projects/` layout.**
The layout change might be: new filename scheme, embedded metadata moved to a sidecar file, transcripts split into multiple files. `ClaudeSessionIndex` breaks silently (scan returns empty), Phase 5 chip disappears on every surface, resume feature is dead until someone notices. No alarm, no metric, no test fixture that would have caught the change — the tests all use synthetic fixtures of the *old* format.

**Disruption C: A Tier 2 agent lands PTY ownership in `cmuxd` ahead of schedule.**
Tier 2 (live PTY resume) obsoletes a lot of Tier 1's rationale — if you can actually resume the process, you don't need a metadata-guess recovery flow. Phase 5's chip becomes the *worse* option of two. The plan doesn't reason about Tier 2 arriving early, even though it names it explicitly in the opening.

**All three together:** M7 has reshaped the title bar file, Claude has rev'd its on-disk format, and the PTY-resume path is close to landing. Phase 5 is the wrong feature on the wrong file with the wrong backend. The work shipped in Phases 1–3 survives; Phases 4–5 are wasted.

The scenario isn't unlikely. "Tier 2 arrives early" is a real risk given the pace of cmuxd work; Anthropic rev'ing file formats is routine; M7 is already in-flight. The plan has no resilience to this combination.

---

## The Uncomfortable Truths

**Phase 4 is speculative work dressed as a plan.** Reading `~/.claude/projects/` is a hack that works today because nobody's changed it. Building persistent UI on top of a private, undocumented, vendor-owned file tree is borrowing trouble. The plan doesn't say this out loud, but we know it's true.

**The "observe from outside, no agent hooks" principle is being slightly compromised here.** `feedback_c11mux_no_agent_hooks.md` says c11mux reads pane content itself rather than asking agents to emit data. Phase 4 is consistent with that principle *mechanically* (no hooks), but the spirit of the principle — "don't depend on agent-internal behavior" — is violated by reading agent-internal file layouts. A more principled approach: detect the agent type (already done by M1) and send the agent a message that asks for its session id via a public channel (stdin, an MCP tool, a CLI flag). That's a design the plan doesn't consider because "observe from outside" was taken as a constraint rather than a guideline.

**Phases 1–3 don't need Phases 4–5 to justify them, and Phases 4–5 don't need the durability of 1–3 as hard as the plan implies.** The plan coats a plumbing-refactor with a user-visible feature to make the whole thing feel like a product win. That's a presentation move, not a technical necessity. Splitting the PRs would let 1–3 land behind a low-risk review and 4–5 get the harder review they deserve.

**The 64 KiB × 512 panels = 32 MiB ceiling is not a decision, it's a capitulation.** "Accepted" means nobody wanted to do the work to think about streaming, per-panel files, or incremental writes. At some scale — maybe not this year — single-file atomic writes of tens of MiB every 8s will bite.

**"Stable panel UUIDs" is being sold as a simplification, but it's a contract change that touches the socket API.** Any consumer that was told "panel IDs are per-session and may change on restart" now has a different contract. That contract is not written down. The plan doesn't update the docs that document it (there aren't any, because the contract was implicit). New contract, no spec — someone builds against it, the contract breaks, blame flies. The plan should explicitly commit the new contract to the socket-api-reference doc.

**The "ship small, Phases 1–3 first" closing line is doing a lot of work.** It *sounds* like restraint, but the plan lists five phases with concrete PR-level deliverables. The psychological commitment is to finish all five. Actually stopping at Phase 3 and waiting to see if Phase 4/5 are still the right moves is the disciplined play — and it's not planned for.

**The companion workspace-metadata plan and this plan were written at the same time by the same author in the same conversation.** That's fine, but it means they share blind spots. Neither plan has a plan for "what if the other plan doesn't land." Neither plan has a joint-schema-change proposal. The coordination is described as "separate PRs" and nothing more.

---

## Hard Questions for the Plan Author

1. **Why was `oldToNewPanelIds` added originally?** Git blame the remap. If the answer is "because multi-window snapshots needed it," your single-workspace tests don't cover the failure mode. What did the original author know that isn't in this plan?

2. **What is the current lived rate of `surface.set_metadata` writes in a typical session?** Without that, the autosave-fingerprint-thrashing risk is unquantified. *We don't know* is an acceptable answer, but then the plan needs a week-1 measurement as a precondition for Phase 2.

3. **What is Anthropic's stability commitment (if any) on `~/.claude/projects/` layout?** If the answer is "none — they can change it any time," why is the plan willing to build durable UI on this foundation? Where is the fallback when they change it?

4. **What's the privacy/threat-model review for c11mux reading conversation transcripts?** Is there one? Has the user consented to c11mux reading Claude transcripts? If c11mux is used in enterprise contexts, does this conflict with data-handling policies?

5. **Why is `claude_session_id` a canonical key and not a custom key namespaced like `agent.claude.session_id`?** This locks vendor naming into the reserved namespace forever. Has this been debated, or is it a default?

6. **Is there actually evidence that operators want a one-tap Claude resume?** User interviews, issue reports, Slack complaints? Or is this a designer's hypothesis? *We don't know* is an acceptable answer, but then Phase 5 should ship with a telemetry stub to measure use.

7. **What does the test plan look like against the real file format, not synthetic fixtures?** Every Phase 4 test described uses "synthetic `~/.claude/projects/` tree into a temp HOME override." Who runs against the real format, and when is that update detected?

8. **When M7 ships and `SurfaceTitleBarView.swift` is in a different shape than you expect, who owns the rebase?** Phases 4–5 are blocked on this coordination. Is there a named owner?

9. **What happens when the 32 MiB worst case actually occurs?** Not in the abstract — concretely, what does `JSONEncoder.encode` + atomic write cost on a 32 MiB snapshot on an 8-core Mac mini under memory pressure? If the answer is "we don't know," add a measurement gate to Phase 2.

10. **What's the rollback plan if Phase 1 ships a regression?** The plan assumes Phase 1 is low-risk and doesn't propose a feature flag. Given it's an identity contract change, shouldn't `CMUX_DISABLE_STABLE_PANEL_IDS=1` exist as an escape hatch for the first release or two?

11. **Why was `titleBarCollapsed` locked as "stay ephemeral"?** The stated rationale ("simpler; revisit if users ask") is not a rationale — it's a deferral. What would change that decision, and why not make it now when you're already in the snapshot code?

12. **What is the interaction between this plan's metadata persistence and the companion workspace-metadata plan's workspace metadata?** Two separate mutation paths, one autosave file. Is there a joint-design document? If not, why are they shipping independently?

13. **How does Phase 4 behave on a remote-daemon workspace?** The cwd is on the remote; `~/.claude/` is on the local Mac. Silent no-op, loud failure, or routed through the daemon? The plan has no answer.

14. **What's the policy for `<agent>_session_id` keys written by agents vs. inferred by c11mux?** Open Question 4 says "external write wins." Is this the right call? An operator who explicitly sets `claude_session_id = X` in the UI is more authoritative than an agent who writes their current session. The precedence model in Module 2 (`explicit > declare > osc > heuristic`) suggests agent writes use `declare`, user writes use `explicit`, and c11mux's inference should use `heuristic`. The plan's "external write wins" blurs this. Which is it?

15. **How do `statusEntries` that were stale-on-restore interact with a fresh agent session that writes different keys?** If pre-restart status `{running: true, progress: 0.4}` is restored, and the agent writes `{running: true}` post-restart (without a fresh `progress`), does `progress: 0.4` persist as stale? Stale on what timeline? The plan's "next write clears stale" is per-key, but operators will read it as per-entry.

16. **Are the `tests_v2/` additions CI-wired?** Project CLAUDE.md says E2E/socket tests run on CI or VM. What's the story for `test_panel_id_stability.py` and siblings? Does the existing workflow pick them up, or does someone need to add them?

17. **What localizations are needed?** Every user-facing string in Phase 5 ("Resume Claude session", "Reopen in `<dir>`", etc.) needs `Resources/Localizable.xcstrings` entries in English + Japanese. This isn't in the plan. *We don't know* which strings are needed is the current answer, and that's a problem — it's a hard requirement per project CLAUDE.md.

18. **Does Phase 4 scan on startup or on first surface focus?** The plan says "Surface focus (debounced 1s)" and "Surface creation for terminals — record immediately." What about restored surfaces? They're neither created nor focused until the user clicks, which could be hours. Is the resume chip available *before* first focus on a restored surface?

19. **What's the commitment to Codex and Gemini?** Phase 4 ships Claude-only with a promise to "revisit." Is that a week? A quarter? The asymmetry will be visible to operators the moment they use Codex and see no resume chip. The silent missing-feature is the worst UX.

20. **Have you considered *not* building Phase 4 and 5?** Phases 1–3 deliver real value (M-series features become durable). Phases 4–5 are speculative. What's the plan if, after Phase 3 lands, the team decides the resume UX should live in a different layer (Lattice, Spike) rather than c11mux? The plan presents 1–5 as a single program. Is it?

---

**Closing note:** The plan is well-organized and the Phase 1–3 work is likely to land cleanly with good testing. The uncomfortable part is that Phases 4–5 — the parts that actually deliver the "turn restart from catastrophe to speed bump" promise in the motivation — are the weakest-justified and most externally-dependent parts of the plan. If I were scoping this work, I'd split: Tier 1a = Phases 1–3 (durable metadata, land fast), Tier 1b = Phases 4–5 (recovery UX, needs more design work, more telemetry, more coordination with M7). The current framing asks one agent to deliver all five, and that's the shape that usually ships the easy parts and leaves the hard parts as half-built.
