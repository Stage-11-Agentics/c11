# Action-Ready Synthesis: conversation-store-architecture

## Verdict

**revise-then-proceed** — with one significant disagreement to surface to the operator.

The Standard reviewers (Claude, Codex, Gemini) converge on "the architecture is right; tighten a list of specific decisions before implementation starts." Evolutionary reviewers are positive and want the vision expanded. Adversarial reviewers split: Claude-Adversarial pushes hard for "ship 0.44.0 on the hot-fix and defer the architecture to 0.45.0+"; Codex-Adversarial wants identity proofs (Codex same-cwd disambiguation) before implementation; Gemini-Adversarial accepts the direction with caveats. The most cautious position is the Claude-Adversarial "do not let this displace 0.44.0" framing, which is a release-management call rather than an architecture call (see S1 below).

The plan author already enumerated 12 open questions; many of the validated findings below answer them or sharpen them. None of the findings invalidate the architecture's shape — they tighten it.

## Apply by default

### Blockers (plan is not yet executable as written)

- **B1: Autosave cadence is misstated as ~30s; current `SessionPersistencePolicy.autosaveInterval` is 8s.**
  - Where in the plan: §Capture / Pull (fallback + crash recovery) and §Open questions for plan review #1: "Every autosave tick (~30 s, confirm)".
  - Problem: The plan's I/O cost analysis is anchored on a wrong cadence. At 8s, "one stat per TUI per autosave per surface" against directories that grow forever (`~/.claude/sessions/`, `~/.codex/sessions/`) becomes meaningfully more expensive in many-pane workspaces, and contention with autosave fingerprint computation is non-trivial in a typing-latency-sensitive app.
  - Revision: Correct the interval reference to 8s. Pick a bounded scrape strategy explicitly: scrape only the *active surface's declared kind* (not all registered strategies × all surfaces); cap directory scans at top-N most-recent by mtime; reuse filename-as-id where the TUI's filename encodes the session id; introduce a separate scrape scheduler/debounce rather than piggybacking on autosave. State the chosen strategy in §Capture.
  - Sources: standard-codex (§Weaknesses, "autosave cost is understated"; §Hard Questions 14–15), standard-claude (§Weaknesses 2 "Pull-scrape directory-watching cost is not bounded"; Q15), adversarial-codex (§Blind Spots: 30 surfaces × 4 strategies; Q14, Q15), adversarial-claude (§Assumption 16; §Hindsight Preview 3), standard-gemini (§Weaknesses "Pull-Scrape I/O Cost"; Q1).

- **B2: `shutdown_clean` is written at the wrong time and is not safely scoped.**
  - Where in the plan: §Crash recovery: "c11 writes `~/.c11/runtime/shutdown_clean` (a one-byte file) at the start of `applicationWillTerminate`, deletes it at the end of `applicationDidFinishLaunching`."
  - Problem: Writing the marker at the *start* of termination means a crash between marker-write and final snapshot capture leaves a "false clean" state, recreating the very bug class the marker exists to prevent. The marker is also globally scoped at `~/.c11/runtime/`, which is shared across tagged debug builds, release builds, and concurrent c11 instances.
  - Revision: Invert the marker semantics — write a *dirty* sentinel at launch, replace with a *clean* sentinel only after the final forced scrape and synchronous snapshot have completed (or use a generation counter). Scope per c11 bundle id (e.g., `~/.c11/runtime/shutdown_clean.<bundle_id>`) so debug + release + multi-instance do not cross-contaminate. Optionally encode the clean-shutdown timestamp in the file and treat snapshots whose `capturedAt` is far from the marker time as crash-recovery candidates.
  - Sources: standard-codex (§Architectural Assessment "false-clean window"; §Weaknesses "crash marker is written at the wrong conceptual time"; Q6, Q7), evolutionary-claude (§S6, §6 timestamp-encoded marker), standard-claude (§Weaknesses 4; Q26 multi-instance), adversarial-claude (§Blind Spots 5; §Hard Q9), adversarial-codex (§Assumption 8; Q13).

- **B3: Codex same-cwd identity is not yet established; the architecture does not by itself make wrong-session restore impossible.**
  - Where in the plan: TL;DR ("fixes the codex multi-pane 'last wins' collapse"); §Per-TUI strategies / Codex (cwd + mtime ≥ claim time + ≥ surface activity); §Testing ("we ship the architecture that makes the bug structurally impossible").
  - Problem: For two Codex panes in the same cwd — the exact failure case that motivated the plan — cwd + mtime + surface-activity is heuristic, not deterministic. mtimes drift as the model writes more turns; surface "last activity" is undefined; ties under filesystem mtime granularity are unaddressed. The plan oversells "structurally impossible" while leaving the disambiguation unproven.
  - Revision: Tier the v1 honesty in the plan: (1) Strong resume — Claude Code (push id from hook). (2) Heuristic resume — Codex, with an explicit ambiguity policy. (3) Fresh launch only — Opencode/Kimi until session storage is mapped. Define the Codex ambiguity policy: when more than one candidate session matches the surface filter, *do not auto-resume*; record a diagnostic reason, set state to `unknown` (or a new `ambiguous`), and surface the situation via `c11 conversation get` and a sidebar advisory. Ship a fixture-driven test that reproduces the 2-pane same-cwd staging-QA failure before merge. Drop the "structurally impossible" framing.
  - Sources: standard-codex (§Executive Summary, §Weaknesses "biggest gap", §Architectural Assessment "downgrade Codex"; Q1–Q3), adversarial-codex (§Executive Summary, §Assumption Audit 2–3, §Uncomfortable Truths; Q1–Q4, Q26–Q27), adversarial-gemini (§Reality Stress Test; Q4), adversarial-claude (§Hard Q18), standard-claude (§Weaknesses, gap 8 — failure-mode → test mapping).

- **B4: `isTerminatingApp` query path under shutdown stress is undefined and is the keystone of the SessionEnd-clears-on-quit fix.**
  - Where in the plan: §Per-TUI strategies / Claude Code: "The CLI checks `isTerminatingApp` (queryable via socket) and, if true, no-ops"; §Open questions for plan review #12.
  - Problem: SessionEnd fires from a CLI subprocess at the exact moment c11 is shutting down. The socket may be hung, slow, torn down, or unreachable. The plan does not specify the policy if the query fails: defaulting to "not terminating" recreates the original bug; defaulting to "terminating" silently loses legitimate `/exit` tombstones; timing out and skipping silently loses one of the two.
  - Revision: Specify exactly: (a) which socket method or capability field exposes `isTerminatingApp` (lean: include in the existing `capabilities`/`ping` response so no new dedicated method is added); (b) the policy on socket failure (lean: treat unreachable/timeout as "terminating" so we err on the side of preservation, not deletion — i.e., never tombstone on socket-uncertainty); (c) a bounded query timeout (e.g., 250ms); (d) a regression test that exercises hook-fires-during-shutdown with a slow/dying socket and verifies the ref is preserved. Validate that the c11 socket actually serves requests during `applicationShouldTerminate` before relying on it.
  - Sources: standard-claude (§Weaknesses 1; Q14), standard-gemini (Q8), standard-codex (Q16), adversarial-claude (§Assumption 4; §Hindsight 5; Q9 "we don't know is a problem"), adversarial-codex (§Blind Spots; Q18).

- **B5: `typeCommand` lacks a per-strategy id-validation and shell-quoting contract; opaque ids meet shell text without rules.**
  - Where in the plan: §ResumeAction; §Per-TUI strategies / Claude Code: `typeCommand("claude --dangerously-skip-permissions --resume <id>", submitWithReturn: true)`; Codex: `typeCommand("codex resume <session-id>", submitWithReturn: true)`.
  - Problem: `ConversationRef.id` is opaque to the store but interpolated into a shell command by the strategy. Today, the existing `AgentRestartRegistry` validates Claude session ids as UUIDs. Codex, Opencode, Kimi, and future kinds have no equivalent rule documented. An opaque id passing through a shell-typed command is a command-injection trap.
  - Revision: Add a per-strategy contract: every strategy that emits `typeCommand` must declare an id grammar (regex or validator) and a quoting/escaping rule, applied before synthesis. If a ref's id fails validation, the strategy must return `.skip(reason:)`. Document this in the `ConversationStrategy` interface and add it to the v1 Claude and Codex strategies. Prefer `launchProcess(argv:env:)` over `typeCommand` where the surface model permits, since argv avoids shell parsing entirely.
  - Sources: standard-codex (§Architectural Assessment 2nd point; Q10), adversarial-codex (§Blind Spots, "Security is underdeveloped"; Q9).

### Important (revise before implementation starts)

- **I1: Drop `ResumeAction.replayPTY` from v1.**
  - Where in the plan: §Schema / `ResumeAction`; §ResumeAction execution `case .replayPTY(let scrollback)`; §Open questions #8.
  - Problem: No v1 strategy emits it. Carrying it adds dead switch arms, references `appendScrollback` which may not be a real public terminal API, and invites future misuse (UTF-8 mojibake, control-char bleed, screen-state desync) when a v2 use case appears.
  - Revision: Remove `replayPTY` from the `ResumeAction` enum and from the executor. If a future use case appears, design for that specific case rather than ship a generic primitive now.
  - Sources: standard-claude (Q24), standard-codex (Q12), standard-gemini (§Weaknesses "YAGNI on `ResumeAction.replayPTY`"; Q4), adversarial-claude (§Hindsight 2), adversarial-codex (§Challenged Decisions), evolutionary-claude (§S5, §6), evolutionary-codex (§Defer `replayPTY`).

- **I2: Update `skills/c11/SKILL.md` (and adjacent skill files) as part of the implementation.**
  - Where in the plan: §CLI surface; §Out of scope (does not exclude skill update but plan does not include it).
  - Problem: Per `code/c11/CLAUDE.md` ("the skill is the agent's steering wheel … every change to the CLI, socket protocol, metadata schema, or surface model is incomplete until the skill is updated to match"), the new `c11 conversation claim|push|tombstone|list|get|clear` surface, the no-focused-fallback rule, and the agent-facing inspection workflow must land in the skill in the same change. Plan currently does not name the skill update.
  - Revision: Add a §Skill update section (or a bullet under §Rollout) listing exactly: new CLI verbs documented in `skills/c11/SKILL.md` with examples; the no-focused-fallback rule called out; agent guidance for inspecting `c11 conversation get/list` before debugging resume; deprecation note on `claude-hook` if applicable. Treat the skill update as a merge-blocker, not a follow-up.
  - Sources: standard-codex (§Weaknesses "does not mention updating skills/c11/SKILL.md"; Q18), adversarial-claude (§Uncomfortable Truths 6; Q11), evolutionary-codex (§How It Could Be Better 6; §Concrete 14; Q12).

- **I3: Concurrency primitive: pick actor or serial dispatch queue before implementation.**
  - Where in the plan: §Concurrency; §Open questions #11.
  - Problem: Choice constrains the API shape (sync vs async accessors) across socket handlers, autosave, snapshot capture. Deferring to "decided at impl" lets the implementer pick at 11pm without re-circulating.
  - Revision: Pick. The reviewer-recommended choice is a Swift `actor` for `ConversationStore` (idiomatic for state-isolated per-surface map; aligns with c11's gradual move to actor isolation; clean test seam where every CLI call is one `await store.<verb>()`). If the implementer prefers a serial dispatch queue for compatibility with existing sync socket-handler shapes, document why and treat the actor migration as a tracked follow-up. Either way, name the choice in the plan.
  - Sources: standard-claude (§Weaknesses 5; Q18), standard-gemini (Q3 — actor), evolutionary-claude (§S3 — actor), evolutionary-codex (§Concrete 8 — actor), adversarial-claude (§Hard Q8).

- **I4: Backward-compat for `claude.session_id` reserved metadata is a migration; specify it.**
  - Where in the plan: §Rollout: "No migration. … snapshots in flight that contain it are read once for backward-compat at v1.0 launch (one release window) and dropped from snapshots written after."
  - Problem: PR #89 has shipped opt-in in 0.43.0 and default-on in 0.44.0-pre. Operators (and Atin's testing rigs) have snapshots with `claude.session_id` baked into surface metadata. "No migration" is misleading; "read once" *is* a migration. The exact behavior — which snapshots, what state, what conflicts with conversation refs, when the compat path is removed — is undefined.
  - Revision: Replace "no migration" with an explicit one-release compat bridge: on snapshot read, if `surface.metadata.claude.session_id` is present and `surface_conversations` is empty for that surface, lift the value into a `ConversationRef(kind: "claude-code", id: <value>, capturedVia: .scrape, state: .unknown)` and run the standard reconcile path. New writes drop the metadata key. Name the release window when the bridge is removed (lean: 0.46.0 or v1.1, whichever ships later). Add a unit test for the read-side path.
  - Sources: standard-claude (§Weaknesses 6; Q16), standard-codex (§Weaknesses "rollout/migration note"; Q17), adversarial-claude (§How Plans Fail 6; §Hard Q10, Q14), adversarial-codex (§Assumption 10), evolutionary-codex (§Concrete 11).

- **I5: Wrapper-claim placeholder id needs an explicit recognition predicate.**
  - Where in the plan: §Capture / Wrapper-claim; §Per-TUI strategies / Codex ("mints a placeholder id `<surface-uuid>:<launch-ts>`"); §Open questions #5.
  - Problem: Strategies must distinguish "this id is still a placeholder, replace it with a scraped real id" from "this id is real, do not clobber it." `<surface-uuid>:<launch-ts>` has no explicit marker. A future kind whose real ids contain colons would silently break. Reviewers also note that encoding unresolved state as a fake id forces every downstream consumer to know an undocumented convention.
  - Revision: Choose one of: (a) add a `placeholder: Bool` field to `ConversationRef`; (b) make `id: String?` (nullable) while `state == .unknown` and the wrapper has only claimed; (c) introduce a separate `claim` shape distinct from `ref` and only synthesize a real ref once a captured id arrives. Lean (a) for minimal schema churn. Document the recognition rule in the strategy contract.
  - Sources: standard-claude (§Weaknesses 3; Q17), standard-codex (Q?... see Architectural Assessment), adversarial-codex (§Challenged Decisions "placeholder ID design"), adversarial-claude (§Assumption 7; §Blind Spots 12).

- **I6: Snapshot integration — specify remap and pruning, or embed conversations on `SessionPanelSnapshot`.**
  - Where in the plan: §Snapshot integration / Per-workspace embedded: "every workspace snapshot grows a `surface_conversations: { surface_id: SurfaceConversations }` field alongside the existing `panels` array."
  - Problem: c11 has an `oldToNewPanelIds` remap path because stable panel ids can be disabled. A sibling map keyed by old surface id must remap in lockstep with panel restore or refs orphan. The plan does not specify the remap, the pruning rule for surfaces that no longer exist, or the interaction with the stable-panel-id feature flag.
  - Revision: Either (preferred) embed the active+history conversation refs onto each `SessionPanelSnapshot` so they follow the panel through restore mapping naturally; or keep the sibling map and add an explicit subsection covering: remap behavior under `oldToNewPanelIds`, pruning of orphaned surface entries, behavior when stable panel ids are disabled, and tab/surface moves between workspaces between autosaves. State the chosen approach in §Snapshot integration.
  - Sources: standard-codex (§Architectural Assessment 3rd point; §Alternatives "panel-embedded conversations"; Q8), adversarial-codex (§Challenged Decisions "putting `surface_conversations` at workspace level").

- **I7: Privacy/data-minimization contract for pull-scrape.**
  - Where in the plan: §Capture / Pull (fallback + crash recovery); not addressed elsewhere.
  - Problem: `~/.claude/sessions/` and `~/.codex/sessions/` contain transcripts (prompts, file paths, model outputs, possibly secrets). The plan says "lightweight: stat the directory" but acknowledges the strategy may need to read file contents to extract a session id or filter by cwd. No explicit contract about what is read, what is persisted, what is logged. The c11 PHILOSOPHY ("host and primitive, not configurator") implies a strict data-minimization stance.
  - Revision: Add a §Privacy contract for scrape: metadata-only (filename, mtime, size) where possible; bounded structured parse (e.g., JSON header fields only) when content read is required, with an explicit byte cap; never copy transcript text into c11 snapshots, indexes, diagnostics, or telemetry; never log transcript content. Surface this in the strategy contract so future strategies inherit the rule.
  - Sources: standard-codex (§Weaknesses "privacy boundary"; Q13), adversarial-codex (§Blind Spots "Privacy and data minimization"; Q24).

- **I8: Rephrase the strategy "pure given inputs / stateless" claim — scrape is impure I/O.**
  - Where in the plan: §Mental model: "Both are pure given their inputs. The strategy is stateless. The `ConversationStore` owns lifecycle."
  - Problem: A strategy that performs filesystem scrape (stat, readdir, parse session files), checks mtimes, and consults app state is by definition impure and side-effecting. The "pure" framing obscures testability and concurrency requirements and contradicts the rest of the plan, which describes the strategy doing exactly this kind of I/O.
  - Revision: Replace with the cleaner split (per standard-codex): a *strategy* describes how to interpret already-collected signals and synthesize resume actions; a *scraper/provider* performs bounded I/O and returns typed candidate signals; the *store* reconciles candidates under a single transition rule. Or, if keeping a single strategy interface, replace "pure" with "deterministic given collected signals; I/O is performed via injectable scraper for testability." Either framing, but state it accurately so the testing seam is visible.
  - Sources: standard-codex (§Architectural Assessment 1st point), adversarial-claude (§Assumption 6), adversarial-codex (§Assumption 9).

- **I9: Tombstone semantics — Claude SessionEnd does not distinguish `/exit` from process death.**
  - Where in the plan: §Per-TUI strategies / Claude Code: "SessionEnd hook fires → `c11 conversation tombstone` … if true [isTerminatingApp], no-ops. If false, tombstones."
  - Problem: SessionEnd may fire on user `/exit`, on Claude process crash, on terminal kill, on wrapper failure. Tombstoning on all of these (when c11 is *not* terminating) means the architecture treats a crash as an intentional end and refuses auto-resume of work the user expected to continue.
  - Revision: When SessionEnd fires and `isTerminatingApp == false`, transition to `unknown` (or a new `ended-uncertain`) rather than `tombstoned`. Tombstone only when the hook payload (or, in future, an explicit signal) indicates user-initiated end. Pull-scrape on next launch can then re-evaluate. State the rule in the state machine and add a transition to the diagram.
  - Sources: standard-codex (§Architectural Assessment 4th point; Q5), adversarial-codex (§Assumption 7; §Challenged Decisions "state machine"), evolutionary-codex (§Concrete 12 — non-destructive unknown handling).

- **I10: Failure-mode table → test matrix mapping.**
  - Where in the plan: §Failure modes (eight-row table); §Testing (generic categories).
  - Problem: §Failure modes lists exactly the cases the architecture is supposed to handle. §Testing lists generic unit/integration/manual buckets. There is no commitment that each failure-mode row maps to a specific automated test. This is the difference between "we tested some things" and "every claimed failure mode is exercised."
  - Revision: Add to §Testing a one-test-per-row mapping: a `ConversationStoreFailureModeTests.swift` (or equivalent) with `testHookFiresAfterShutdownBegins`, `testHookEnvStripsCmuxSurfaceId`, `testTuiCrashesBeforeHookFires`, `testCrashRecoveryUnknownTransition`, `testTwoPanesSameTuiSameCwd`, `testSleepPowerOffMidSession`, `testTuiSessionFileDeletedOutOfBand`, `testWrapperNotOnPath`. Plus an explicit fixture-driven test that reproduces the 4-pane staging-QA failure (the bug the plan exists to fix).
  - Sources: standard-claude (§Weaknesses 8; Q19), adversarial-claude (§Challenged Decisions "we ship the architecture"; §Hard Q4, Q16), adversarial-codex (§Blind Spots "Testing is not realistic enough"; Q26, Q27).

- **I11: Capture vs resume — `CMUX_DISABLE_AGENT_RESTART` should disable execution only, not capture.**
  - Where in the plan: §Open questions #9 ("Should the wrapper short-circuit when `CMUX_DISABLE_AGENT_RESTART=1`?")
  - Problem: If the wrapper short-circuits the claim under the disable flag, an operator who turned off auto-resume gets no observability either — the store is empty, `c11 conversation list` shows nothing, debugging resume after re-enabling becomes harder. Disable-resume and disable-capture are different concerns.
  - Revision: Keep capture (claim, push, scrape) running regardless of the disable flag. The flag should gate only `ResumeAction` execution at restore time. Document this distinction in §Wrapper changes and §Rollout. Open question #9's answer becomes "no, the wrapper does not short-circuit."
  - Sources: standard-gemini (Q5 says short-circuit, but reasoning is wrapper-cost-only), standard-claude (Q21 leans yes-short-circuit), evolutionary-codex (§Concrete 10 — execution only); adversarial-codex (§Blind Spots — separate flags). Reviewers split, but the operator-observability argument (codex-evo, codex-adv) is stronger; surface this if uncertain.
  - Note: this is borderline between "apply by default" and "surface to user." Including here because the observability framing is decisive on a debugging-friendly system; if author disagrees, easy revert.

### Straightforward mediums

- **M1: Codex wrapper comment about `--last`/cwd-filter is now misleading.**
  - Where in the plan: References §`Resources/bin/codex` — current wrapper.
  - Problem: After this plan lands, the existing comment in `Resources/bin/codex:13-21` claiming `codex resume --last` filters by cwd as best-effort is misleading or stale. Plan does not name updating it.
  - Revision: Add an implementation step: update `Resources/bin/codex` comments to reflect the new `c11 conversation claim` flow and remove or rewrite the `codex resume --last` justification.
  - Sources: evolutionary-codex (§Concrete 13), standard-claude (§Q29 verifies the cwd-filter assumption is inherited and may be wrong).

- **M2: Name where new code lives.**
  - Where in the plan: §References (lists files that change but not where new code lands).
  - Problem: The plan does not say where the new `ConversationStore`, `ConversationRef`, strategy registry, and per-kind strategy files live in `Sources/`. Naming up front avoids a churn-y move during implementation.
  - Revision: Add to §References the new file paths: e.g., `Sources/Conversation/Store.swift`, `Sources/Conversation/Ref.swift`, `Sources/Conversation/StrategyRegistry.swift`, `Sources/Conversation/Strategies/ClaudeCode.swift`, `Sources/Conversation/Strategies/Codex.swift`, etc. Or whatever the author prefers — but pick.
  - Sources: standard-claude (Q30).

- **M3: Define `SurfaceActivity` (last-activity timestamp) before relying on it.**
  - Where in the plan: §Per-TUI strategies / Codex: filter "modification time ≥ surface's last activity timestamp".
  - Problem: The Codex filter uses a "surface last activity timestamp" that is not defined anywhere in the plan. Does it count user input, terminal output, focus, process start, background TUI writes? The Codex disambiguation can't be tested or implemented without this.
  - Revision: Add a §Surface activity subsection (or expand §Per-TUI strategies / Codex) defining: what events update the timestamp (lean: terminal input + terminal output, debounced); persistence across restore (yes); whether it survives c11 restarts (yes, in snapshot); a tested API to read it. Until then, the Codex strategy filter is incomplete.
  - Sources: standard-codex (Q3 implicitly), adversarial-codex (§Assumption 2; Q6), evolutionary-codex (§How It Could Be Better 4 — `SurfaceActivity` primitive).

- **M4: Clarify Approach C in §Alternatives considered.**
  - Where in the plan: §Alternatives considered (and rejected) — lists A, B, D; C is missing.
  - Problem: Approach C is conspicuously absent. Likely an editorial oversight, but a reader can't reconstruct the original alternatives.
  - Revision: Either restore the missing Approach C (the author knows what was intended) or relabel the remaining options A, B, C so the gap doesn't suggest content was lost.
  - Sources: standard-claude (§Alternatives Considered, "missing C, presumably an oversight").

- **M5: Clarify the per-strategy primary/fallback split — push/pull is per-kind, not global.**
  - Where in the plan: §Capture: "Push primary, pull as fallback and crash-recovery primary."
  - Problem: For Codex, pull is primary on the happy path (the wrapper claim mints only a placeholder). A reader could come away thinking push/pull is a global A/B fallback when it's actually per-strategy.
  - Revision: One sentence in §Capture: "Push vs. pull primacy is per-strategy. Claude Code is push-primary; Codex is pull-primary on the live path because Codex exposes no hook surface. Crash recovery is always pull-primary regardless of strategy."
  - Sources: standard-claude (§The Plan's Intent, drift 3).

- **M6: `history: []` on disk — write the empty array.**
  - Where in the plan: §Conversation history; §Open questions #7.
  - Problem: Open question #7 asks whether to write the empty array or omit. Editorial.
  - Revision: Write the empty array in v1. Reason: stable `--json` output across v1/v2; no special-casing in tooling consumers.
  - Sources: standard-claude (Q20), evolutionary-gemini (§Concrete 1 — populate history immediately would also be defensible if author wants to lean further; but at minimum write `[]`).

- **M7: Strategy missing → log + sidebar advisory, not silent skip.**
  - Where in the plan: §Open questions #4 ("Skip with `Diagnostics.log` (proposal) or hold the ref…").
  - Problem: A snapshot referencing an unregistered `kind` (e.g., a future c11's `claude-code-2` strategy loaded by an older binary) means a surface comes back blank with no operator-visible signal. Silent data-feel-loss.
  - Revision: Skip with `Diagnostics.log` *and* a sidebar advisory ("1 surface skipped resume: unknown agent kind `<kind>`"). Retain the ref in the store with state `unknown` (or a new `unsupported`) — do not tombstone — so a future c11 release with the strategy can promote it.
  - Sources: standard-claude (Q22), standard-gemini (Q7 — silent skip with `Diagnostics.log`), evolutionary-claude (§5 — `unsupported` state), evolutionary-codex (§Concrete 12 — non-destructive).

- **M8: Codex tombstone heuristic — defer for v1; ship absent-on-restore = unresolved (not auto-tombstone).**
  - Where in the plan: §Per-TUI strategies / Codex: "Treat absent-on-restore as `tombstoned`"; §Open questions #2.
  - Problem: Wrong auto-tombstone is worse than no auto-tombstone. A transient unreadable mount, a cwd path change, or an out-of-band file move would silently kill resumability. Reviewers strongly prefer "do not auto-tombstone hookless TUIs."
  - Revision: For hookless strategies (Codex, Opencode, Kimi), absent-on-restore transitions to `unknown`, not `tombstoned`. The CLI/UI surfaces this as "unresumable; cleared on next clean operator action." Operators clear via `c11 conversation clear --surface <id>`.
  - Sources: standard-claude (Q23), adversarial-codex (Q3), adversarial-gemini (§Blind Spots "Tombstone Un-detection"; Q5), standard-codex (§Weaknesses "Tombstone Ambiguity").

- **M9: `c11 conversation push --payload <json>` accepts file path or inline.**
  - Where in the plan: §CLI surface: `--payload <json>`.
  - Problem: Hook authors writing bash struggle with shell-quoting JSON; the existing `Resources/bin/claude` already uses `HOOKS_FILE` to avoid this. Inline-only would recreate the same pain.
  - Revision: Accept `--payload <json>` as inline JSON or `--payload @<path>` to read JSON from a file. Document both forms. Mirror the `HOOKS_FILE` ergonomics already established in `Resources/bin/claude`.
  - Sources: standard-claude (§Weaknesses 7; Q25).

- **M10: `claim` idempotency — write only when existing ref is older AND of equal-or-lower provenance.**
  - Where in the plan: §Capture / Wrapper-claim; not specified.
  - Problem: Operator types `claude` twice in the same surface; the second wrapper-claim might overwrite a scrape-confirmed real id with a fresh placeholder, regressing the ref. "Latest `capturedAt` wins" alone permits this.
  - Revision: Codify: a wrapper-claim only writes if the existing ref is older AND of equal-or-lower provenance (`wrapperClaim` <= existing source). Hooks/scrapes always win over wrapper claims regardless of timestamp. State this exception in §Capture / Reconciliation rule.
  - Sources: standard-claude (Q27), adversarial-codex (§Challenged Decisions "latest `capturedAt` wins").

### Evolutionary clear wins

- **EW1: Add a per-update `diagnosticReason` field to `ConversationRef`.**
  - Where in the plan: §Schema / `ConversationRef`.
  - Problem: When a wrong session resumes, the only artifact is the current ref. Operators and agents need to see *why* the strategy chose this ref over alternatives. The plan's `capturedVia` enum is too coarse (one of four sources) for this.
  - Revision: Add `diagnosticReason: String?` to `ConversationRef`. For Codex scrape results, populate with values like `"matched cwd + mtime after claim"`, `"ambiguous: 3 candidates; chose newest"`, `"placeholder only; no session file found"`. Surface in `c11 conversation get --json`. This is small (one field) and is the operator-visible artifact for the wrong-session debugging path that motivated the plan.
  - Sources: evolutionary-codex (§How It Could Be Better 1), evolutionary-claude (§What's Really Being Built — provenance-as-trust).

## Surface to user (do not apply silently)

- **S1: Rollout / release window — bundle conversation-store with 0.44.0, or sequence to 0.45.0?**
  - Why deferred: author-intent-needed + scope-creep + disagreement.
  - Summary: Standard reviewers tolerate the current "0.44.0 marquee feature" framing but flag that the rollout story is too thin (claude-std lays out three explicit options). Adversarial-Claude argues forcefully that bundling an architectural rewrite with the held PR #94 + 25 upstream picks is how releases slip 2x and quality dips, and recommends shipping 0.44.0 on the existing C11-24 hotfix and landing the conversation-store in 0.45.0 with proper bake time. Evolutionary-Claude makes the same recommendation as a release-management call. Adversarial-Codex echoes the concern under release pressure. The architecture itself is not in dispute; the *timing* is. This is a strategic operator call — the plan should pick explicitly between: (a) ship 0.44.0 on C11-24 hotfix, conversation-store in 0.45.0 (lowest risk); (b) hold 0.44.0 until conversation-store ready, ship together (current implication, highest risk); (c) pull C11-24 from 0.44.0, ship without resume, conversation-store in 0.45.0 (cleanest conceptually).
  - Sources: standard-claude (§Is This the Move? — three options; Q13), adversarial-claude (§Executive Summary, §Challenged Decisions "0.44.0 ships with conversation-store as marquee"; §What I would do instead), evolutionary-claude (§S9 — don't bundle with PR #94), adversarial-codex (§Reality Stress Test #3, §Uncomfortable Truths — release ambition too high).

- **S2: Architecture-level kill switch (`CMUX_DISABLE_CONVERSATION_STORE=1`)?**
  - Why deferred: design-needed + author-intent-needed.
  - Summary: The plan explicitly says "no feature flag for the architecture." Adversarial-Claude argues this is bold and risky — if v1.0 has bugs in the store itself (separate from auto-resume), there is no kill switch. Recommends a kill switch for one release window that falls back to the existing `claude.session_id` reserved-metadata path, double-maintained briefly. Adversarial-Codex makes a similar separate-flags argument (capture vs scrape vs execution as separate gates). Standard reviewers don't flag this. The author's explicit "the new design is the only design" is a deliberate stance; whether to soften it for one release window is a release-risk call.
  - Sources: adversarial-claude (§Challenged Decisions "no feature flag for the architecture"; §Hard Q15), adversarial-codex (§Challenged Decisions "no feature flag" / separate flags; Q23).

- **S3: Should pull-scrape be deferred from v1 entirely (push-only v1, scrape in v1.1)?**
  - Why deferred: disagreement + author-intent-needed.
  - Summary: Evolutionary-Claude (§S7) and Evolutionary-Codex (§Slice 1) recommend cutting pull-scrape from v1 to reduce new-bug surface area; v1 ships push-only Claude + wrapper-claim Codex; pull-scrape lands in v1.1 once push is rock-solid. Standard-Claude implicitly supports this (the fewer moving parts argument). Adversarial-Codex flags the load-bearing nature of scrape and notes that without it, crash recovery degrades to "use stale push values." Standard-Codex insists scrape is necessary for hookless TUIs and crash recovery. The author has explicitly chosen push+pull as the architecture; deferring scrape would change scope materially. Worth the operator's explicit yes/no.
  - Sources: evolutionary-claude (§S7, §Sequencing), evolutionary-codex (§Sequencing Slice 1), adversarial-codex (§Executive Summary — load-bearing assumption); standard-codex (insists scrape is needed).

- **S4: FSEvents/kqueue instead of polling for scrape.**
  - Why deferred: design-needed.
  - Summary: Adversarial-Gemini (§Challenged Decisions, §Reality Stress Test) and Evolutionary-Gemini (§How It Could Be Better; Q3) argue polling is the wrong primitive — FSEvents on `~/.codex/sessions/`, `~/.claude/sessions/` would convert pull-scrape into a near-instant push without the polling cost. No other reviewer raises this. Worth thinking about, but it's a bigger design change than the current v1 scope (FSEvents lifecycle, debounce, multi-instance handling, sandbox concerns under future macOS). Could be raised separately.
  - Sources: adversarial-gemini (§Challenged Decisions, §Blind Spots), evolutionary-gemini (§How It Could Be Better, §Concrete 3, Q3).

- **S5: Namespaced `kind` (`vendor/product[@version]`) at v1.**
  - Why deferred: scope-creep + design-needed (low cost but a deliberate forward-compat bet).
  - Summary: Evolutionary-Claude (§S1, §2) argues namespacing `kind` at v1 prevents a future migration when Claude Code 3.0 ships a breaking SessionStart payload, when Lattice agents need a kind, when user-defined kinds appear. Cost is 5 minutes of design. No other reviewer raises this; it's one reviewer's evolutionary suggestion. The author's intent re: third-party / user-defined strategies is unclear. Worth a one-line decision; default flat strings are fine if the author explicitly chooses scope over forward-compat.
  - Sources: evolutionary-claude (§How It Could Be Better 2, §S1, §Q3).

- **S6: Promote conversation CLI verbs (tag/rename/show/watch/tail) and treat conversation as agent-facing primitive on day one.**
  - Why deferred: scope-creep + author-intent-needed.
  - Summary: Both evolutionary reviewers (Claude, Codex) and Evolutionary-Gemini argue the conversation primitive is the strategic prize and v1 should expose it as a first-class agent-queryable object, not just internal plumbing. Concretely: ship `tag`/`rename`/`show`/`watch`/`tail` verbs in v1, document the integration contract, expose state transitions over the socket. The plan author's explicit "Out of scope" list closes most of these doors. The architecture vs. vision question is the operator's strategic call.
  - Sources: evolutionary-claude (§How It Could Be Better 1, §Mutations, §S2, §Q1), evolutionary-codex (§Mutations A–E, §Concrete 1–5), evolutionary-gemini (§How It Could Be Better, §What It Unlocks).

- **S7: Move `cwd` (and possibly `git_branch`) out of `payload` and into core `ConversationRef`.**
  - Why deferred: design-needed.
  - Summary: Evolutionary-Gemini (§Concrete 2; Q1) argues `cwd` is universally applicable to software-engineering agents and is critical for scrape-pull filtering and cross-workspace routing — promoting it to a first-class field saves every strategy from reading `payload` keys. Evolutionary-Codex hints at the same with `SurfaceActivity` and the per-strategy reason fields. Other reviewers do not raise it. The plan keeps cwd in `payload` to preserve schema flexibility; promoting it is a small bet on cwd being canonical forever.
  - Sources: evolutionary-gemini (§Concrete 2, §Q1).

- **S8: Confidence-scored refs / `ResumePlan` with confidence + reason.**
  - Why deferred: design-needed + scope-creep.
  - Summary: Adversarial-Codex (§Blind Spots "Confidence is missing from the schema") and Standard-Codex argue refs with different provenance have different reliability; Codex scrape ≠ Claude hook in trust. Evolutionary-Codex (§Concrete 2, §Mutation E) proposes `ResumePlan` wrapping `ResumeAction` with `confidence: Double, reason: String, warnings: [String]`. Auto-resume only above a threshold. This is more than a small revision — it adds a confidence model the plan does not currently have. Worth the operator's attention but not silently applicable.
  - Sources: standard-codex (§Architectural Assessment — confidence-scored), adversarial-codex (§Blind Spots "Confidence is missing"; Q4), evolutionary-codex (§How It Could Be Better 3, §Mutation E).

- **S9: Lattice binding for conversations (`c11 conversation tag <id> --lattice <ticket-id>`).**
  - Why deferred: scope-creep + author-intent-needed.
  - Summary: Evolutionary-Claude (§Mutation 1, §Q2) and Evolutionary-Codex (§Mutation B handoff capsules) argue Stage 11's two agent-native primitives (Lattice + c11) are siblings that barely touch and binding them at v1 is a small lift with strategic payoff. The plan does not address Lattice at all. Out of scope today; worth flagging for a v2 conversation.
  - Sources: evolutionary-claude (§Mutation 1, §Q2), evolutionary-codex (§Mutation B).

- **S10: cmux upstream relationship — should this primitive go upstream?**
  - Why deferred: author-intent-needed.
  - Summary: Adversarial-Claude (§Uncomfortable Truths 7; Q12) flags that c11's CLAUDE.md is explicit about bidirectional contributions with cmux, and the plan does not address whether the conversation primitive should land upstream, stay c11-only, or in what shape. If only-c11, the divergence cost on shared code grows. The author's call.
  - Sources: adversarial-claude (§Uncomfortable Truths 7; §Hard Q12).

- **S11: Should the architecture's value be measured? Define a payoff metric.**
  - Why deferred: author-intent-needed.
  - Summary: Adversarial-Claude (§Hard Q13) asks "what metric will tell us the architecture is paying off?" Number of TUIs successfully integrated? Reduction in resume-failure reports? Add-time per new strategy? Without a defined metric, post-implementation it's hard to know if the bet succeeded. Single reviewer; subjective. Worth a one-line answer.
  - Sources: adversarial-claude (§Hard Q13).

## Evolutionary worth considering (do not apply silently)

- **E1: Re-frame the primitive as "the c11 ↔ TUI integration contract" and document `ConversationStrategy` as a public artifact.**
  - Summary: Evolutionary-Claude argues the highest-leverage v1 move is shipping a "how to write a ConversationStrategy" doc as part of the v1 PR, treating the strategy interface as the public integration contract, not an implementation detail. Without it, every future strategy is reverse-engineered from existing ones and the "a new kind is one Swift file" claim stays aspirational. This compounds across every future TUI integration.
  - Why worth a look: The architecture cost is paid once; the strategy contract pays forward every time a new TUI ships. If the goal is a flywheel where new TUI integrations get cheaper, the integration contract is the lever.
  - Sources: evolutionary-claude (§How It Could Be Better, §The Flywheel, §S8, §Q11), evolutionary-codex (§Mutation D — strategy fixture lab).

- **E2: Strategy fixture harness as a deliberate compounding tool.**
  - Summary: Evolutionary-Codex (§Mutation D) proposes a small local harness — `c11-dev conversation-strategy test codex fixtures/codex/two-panes-same-cwd.json` — where a strategy can be fed fixture directories and surface signals. This converts "reverse engineer Opencode/Kimi" from artisanal debugging into a repeatable integration workflow. Pairs naturally with the failure-mode test matrix (I10) and the integration contract doc (E1).
  - Why worth a look: The exact failure that motivated the plan (2 Codex panes, same cwd) is a fixture-shaped problem; the harness exists for that case anyway. Generalizing it now while building it is much cheaper than retrofitting it later.
  - Sources: evolutionary-codex (§Mutation D, §Sequencing Slice 3), adversarial-codex (§Hard Q26, Q27 — automated tests for the staging-QA failure).

- **E3: Split `ConversationState` × `ResumePolicy` (lifecycle vs. what-c11-should-do-on-launch).**
  - Summary: Evolutionary-Claude (§How It Could Be Better 4, §S4) and Adversarial-Codex (§Blind Spots "no per-surface 'do not resume this'") argue that "the conversation is alive" and "c11 should auto-resume it on launch" are different dimensions. v1 only ships `auto` and `never` (the existing global `CMUX_DISABLE_AGENT_RESTART` becomes per-surface), but the seam preserves room for a "prompt before resume" UX, stale-age thresholds, and per-surface opt-out without a future schema migration.
  - Why worth a look: Auto-typing `claude --resume <id>` is a strong opinion that hides operator choice. Splitting the dimension at v1 costs a few enum cases and prevents a retroactive split when a "resume picker" UI eventually ships.
  - Sources: evolutionary-claude (§How It Could Be Better 4, §S4), adversarial-codex (§Blind Spots; Q4).
