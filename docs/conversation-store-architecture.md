# Conversation Store Architecture

**Status:** v1 implemented; reviewed 2026-04-27 (`notes/trident-review-C11-24-pack-20260427-2343/`); shipping with explicit scope reduction (see "v1 scope vs v1.1" below).
**Owner:** delegator agent on C11-24.
**Supersedes:** `notes/session-resume-fix-plan.md` (the C11-24 hot-fix plan, now obsolete).
**Related:** PR #89 (current C11-24 implementation, shipped in 0.43.0 opt-in / 0.44.0-pre default-on), PR #94 (held release).

## v1 scope vs v1.1 (post-review)

The post-implementation Trident review (2026-04-27) found that the strategy machinery (capture, resume, scrapers, ambiguity policy) is complete and unit-tested but the **production restore path is snapshot-only** in v1: refs that were captured into the snapshot at last clean shutdown resume; refs lost between snapshots do not. The forced pull-scrape pass that would re-discover them on dirty shutdown / first launch ships in v1.1.

**In v1.0 (this plan):**
- Wrapper-claim → snapshot persistence → snapshot-driven resume across the four kinds (Claude Code, Codex, Opencode, Kimi).
- `claude-hook session-start` push captures the real id while c11 is alive.
- Inverted dirty/clean shutdown sentinel; `markAllUnknown` on dirty (post-review fix sequenced after `seedFromSnapshot`).
- All v2 socket verbs + CLI surface + privacy contract + skill update.

**Deferred to v1.1 (0.45.0+) with explicit TODO markers:**
- **Forced pull-scrape pass** in `AppDelegate.applicationDidFinishLaunching` after `seedFromSnapshot`. The pieces (`ClaudeCodeScraper`, `CodexScraper`, `strategy.capture(inputs:)`) are built and tested; only the production caller is missing.
- **`SurfaceActivityTracker` snapshot persistence** (`seed(from:)` / `snapshot()` exist; no callers in `SessionPersistence.swift`). The Codex `mtime ≥ surface lastActivityTimestamp` filter relies on this.
- **Codex cwd recovery** via bounded JSONL metadata parse — pending privacy-contract design call (the structural Mirror test on `ScrapeCandidate` is built to forbid transcript-bearing fields; opening the JSONL even for first-line metadata needs a guarded carve-out).
- Workspace partitioning on `c11 conversation list`. v1 stores process-wide; `--workspace` is rejected with a clear error.

The §"Failure modes" table and §"Strategies" table below describe the **v1.1 target behaviour** for completeness; rows that depend on the deferred pull-scrape pass are explicitly marked. Until v1.1, the legacy `AgentRestartRegistry` remains in tree as the kill-switch fallback (`CMUX_DISABLE_CONVERSATION_STORE=1`), so operators don't lose resume capability if v1 regresses.

**Why scope-down rather than wire it up before merge:** the Codex scraper today stamps the surface's cwd into every candidate (`Scrapers/ClaudeCodeScraper.swift:108`), which makes the strategy's `cwd != candCwd` filter a structural no-op. Wiring the pull-scrape pass without first solving cwd recovery would surface "ambiguous, skip" on every restart for every operator with multiple recent Codex sessions — strictly worse than the snapshot-only v1. The privacy-contract design call for cwd parsing is the right gate for v1.1.

## TL;DR

c11 grows a first-class `Conversation` primitive decoupled from any specific TUI process. Each surface that hosts an agent has one or more `ConversationRef`s persisted across c11 restarts. Per-TUI **strategies** in c11 own how to capture and resume conversations using whatever signals each TUI provides: hooks where available, on-disk file scrape as fallback. Wrappers shrink to "declare the kind." This replaces the per-TUI bespoke wrapper pattern that ships in 0.43.0/0.44.0-pre, fixes the SessionEnd-clears-on-quit race, replaces codex's `codex resume --last` global lookup with per-pane session-id resume (Claude is push-id deterministic; codex is heuristic with an explicit ambiguity policy for same-cwd cases that aren't yet disambiguable), and opens a path to remote/cloud agents and conversation history without re-architecting again.

## Why we're doing this

Three concrete failures, observed in 0.44.0 staging QA on 2026-04-27:

1. **Two Codex panes opened in the same project, both restored to the most-recent global Codex session ("B")** — not their own. The current registry hardcodes `codex resume --last\n`. The wrapper has no mechanism to capture per-pane Codex session ids (Codex 0.124 has no `--session-id` injection flag, no SessionStart-style hook).
2. **Two Claude panes both restored blank.** Capture today writes `claude.session_id` to per-surface metadata via the SessionStart hook. The SessionEnd hook clears that key when claude exits. On Cmd+Q, c11 kills terminals; claude exits; SessionEnd fires; metadata cleared, racing the snapshot capture in `applicationShouldTerminate`. By next launch, per-surface session ids are gone.
3. **Opencode and Kimi do not resume at all.** Their wrappers launch fresh because neither TUI exposes an injection flag or hook surface that the bespoke wrapper pattern can hang off.

(1) and (3) are not bugs in the implementation. They are the inevitable consequences of the architecture: the wrapper-only pattern cannot capture what the TUI does not expose. (2) is a race between the TUI's lifecycle hook and c11's shutdown sequence; patching it inside the current architecture means special-casing "is the parent c11 dying?" inside a hook handler that has no visibility into c11 state.

The fix that moves us forward replaces the architecture, not the patch.

## Structural problems with the current pattern

1. **N TUIs = N bespoke wrappers + N capture surfaces.** Every new agent (opencode, kimi, future LLM CLIs) is a fresh integration. Many TUIs offer no lifecycle hook; the wrapper has nothing to hook into and chooses between "fresh launch" or "best-effort by side channel."
2. **Capture and clear go through the same hook.** SessionEnd clears what SessionStart wrote. There is no architectural difference between "TUI ended because user typed `/exit`" and "TUI ended because c11 killed it during shutdown." Both fire the same hook. The first should clear; the second should not.
3. **The ref lives in a single place: per-surface metadata of one snapshot.** No global awareness, no history, no portability. Once you delete the snapshot or the workspace, the conversation is unreachable even if the TUI's own session file on disk still exists.
4. **The wrapper-set ref is opaque to c11.** c11 only knows about `claude.session_id` because SessionStart writes that exact key. A future agent that uses `conversation_id` instead would need another hook handler with another reserved key. The naming is per-TUI rather than per-c11; reserved keys keep growing.
5. **Fragile against env-var loss.** The hook writes to "the surface identified by `CMUX_SURFACE_ID` in the hook process's environment, falling back to focused-surface if missing" (`CLI/c11.swift:7238-7266`). The fallback is silent. Any env-stripping shell behavior between c11-launched shell → TUI → hook subprocess routes the write to whichever surface happens to be focused at hook-fire time.

## Alternatives considered (and rejected)

- **Approach A: Harden the current pattern.** Skip-clear when `isTerminatingApp` is set; document codex degenerate case more loudly. Cheapest path. Rejected because it does not address the structural problems above; we would re-confront them with the next TUI integration and the next race condition.
- **Approach B: PTY hibernation (tmux model).** A long-running c11d daemon keeps TUI processes alive across c11 GUI restarts; the GUI re-attaches on launch. Rejected because OS sleep, kernel panic, power loss, or system reboot all kill the daemon and lose every conversation. The point of resume is to survive *those* events.
- **Approach C: Operator-marked checkpoints.** Explicit user action to checkpoint a conversation. Rejected as the primary mechanism because it puts the burden on the operator for what should be transparent. Worth keeping as a future *additional* mechanism (manual `c11 conversation push --source manual`) on top of the auto pipeline.

## Mental model

c11 grows an internal `Conversation` primitive. A Conversation is a persistable pointer to *a continuation of agent work*. It is owned by c11, lives across TUI process death, and is keyed by an opaque id whose interpretation is delegated to a per-kind strategy.

```
Surface ──hosts──▶ Conversation ──interpreted-by──▶ ConversationStrategy
                        │
                        └── carries: kind, id, capturedAt, capturedVia, state, payload
```

A surface hosts at most one *active* Conversation at a time (v1). It may carry a history of past Conversations. A Conversation belongs to a kind (`claude-code`, `codex`, `opencode`, `kimi`, `claude-code-cloud`, …) and the kind selects the strategy.

The interpretation layer is split into three roles for testability and concurrency:

- A **scraper/provider** (per kind) performs bounded filesystem I/O — `stat`, `readdir`, optional bounded structured parse — and returns typed candidate signals. Side-effecting; isolated so it can be mocked.
- A **strategy** (per kind) is `capture(surface, signals) -> ConversationRef?` and `resume(surface, ref) -> ResumeAction`. Strategies are deterministic given collected signals; they do not perform I/O directly. They take signals from the scraper, push values from hooks, and wrapper-claim values, and emit a `ConversationRef` and a `ResumeAction`.
- The **`ConversationStore`** owns lifecycle and reconciliation across signal sources under a single transition rule.

The split lets unit tests cover pure reconciliation (store + strategy with synthetic signals) separately from fixture-backed scrape tests (scraper against fixture session-storage layouts).

## Schema

### `ConversationRef` (persisted)

```swift
struct ConversationRef: Codable, Sendable {
    let kind: String                                 // "claude-code", "codex", future… Flat strings; namespacing deferred until we hit a real collision.
    let id: String                                   // Opaque to c11; strategy interprets. Validation grammar is per-strategy (see §Per-TUI strategies).
    let placeholder: Bool                            // True while only a wrapper-claim has been seen and the real id has not been resolved yet. Strategies must replace before any ResumeAction is emitted; resume() returns .skip if placeholder remains true.
    let cwd: String?                                 // Working directory at capture time. Universal for local-process software-engineering agents and load-bearing for the Codex scrape filter; promoted to core for type-safety and `c11 conversation list --cwd` ergonomics. Nil for cloud/remote/MCP strategies that don't have a meaningful cwd.
    let capturedAt: Date                             // When this ref was last refreshed.
    let capturedVia: CaptureSource                   // hook | scrape | wrapperClaim | manual
    let state: ConversationState                     // alive | suspended | tombstoned | unknown | unsupported
    let diagnosticReason: String?                    // Strategy-set short reason populated on every update. Examples: "matched cwd + mtime after claim", "ambiguous: 3 candidates; chose newest", "placeholder only; no session file found yet". Surfaced via `c11 conversation get --json` so operators can answer "why did this pane resume that session?" without instrumentation.
    let payload: [String: PersistedJSONValue]?       // Kind-specific extras (model, transcript path, git_branch, …). cwd is NOT in payload — it's promoted to core above.
}

enum CaptureSource: String, Codable { case hook, scrape, wrapperClaim, manual }
enum ConversationState: String, Codable { case alive, suspended, tombstoned, unknown, unsupported }
```

`unsupported` is reserved for refs that arrive in a snapshot whose `kind` is not registered in this binary's strategy registry. The store retains the ref (not tombstoned), skips resume, and surfaces a sidebar advisory; a future c11 release with the strategy can promote it.

### `ResumeAction` (transient, returned by strategy)

```swift
enum ResumeAction: Sendable {
    case typeCommand(text: String, submitWithReturn: Bool)
    case skip(reason: String)
}
```

Every strategy that emits `typeCommand` MUST validate `ConversationRef.id` against a documented grammar (regex or validator) and apply explicit shell-quoting/escaping before interpolation. If the id fails validation or the ref is still a placeholder, the strategy MUST return `.skip(reason:)` rather than synthesizing a command. See §Per-TUI strategies for each kind's grammar.

`.composite` and `.launchProcess` removed in v1; reintroduce when a strategy demonstrably needs semantics that `.typeCommand` cannot express. The argv-form fresh-launch case (Opencode, Kimi) collapses to `.typeCommand` of the shell-quoted binary name, since v1's executor already routed `.launchProcess` through `TextBoxSubmit.send`.

### Surface ↔ Conversation mapping (persisted)

A surface persists a *list* even though v1 only ever populates one entry. List shape leaves room for history without a schema break.

```swift
struct SurfaceConversations: Codable, Sendable {
    let active: ConversationRef?
    let history: [ConversationRef]   // v1: always empty.
}
```

This lives separately from `surface.metadata`. Surface metadata stays for surface configuration (`terminal_type` as a kind hint, `cwd`, agent role). Conversations have their own store and lifecycle.

## Capture

Three signal sources, fused inside the store under per-strategy reconciliation rules. **Push vs pull primacy is per-strategy, not global.** Claude Code is push-primary on the live path because the SessionStart hook reports the real session id. Codex is pull-primary on the live path because it exposes no hook surface; the wrapper-claim mints only a placeholder. Crash recovery is always pull-primary regardless of strategy (push values may be stale and the on-disk file may have advanced).

### Push (primary for hooked TUIs)

When a TUI exposes a lifecycle hook, the wrapper proxies it into c11 via a thin CLI command:

```
c11 conversation push --kind <k> --id <id> --source hook [--payload <json> | --payload @<path>]
```

`--payload` accepts inline JSON or `@<path>` to read JSON from a file (mirrors the existing `HOOKS_FILE` ergonomics in `Resources/bin/claude` so hook authors writing bash do not have to shell-quote JSON).

The CLI command uses `CMUX_SURFACE_ID` from its env. **It does not fall back to focused-surface** (the fallback is the silent-misroute footgun documented above). Errors out cleanly if `CMUX_SURFACE_ID` is unset. The store writes the ref immediately, marks `capturedVia = .hook`.

### Pull (primary for hookless TUIs and crash recovery)

A per-kind scraper performs bounded filesystem I/O on demand:

- **On a dedicated scrape scheduler**, not piggybacked on snapshot autosave. Current `SessionPersistencePolicy.autosaveInterval` is 8 seconds; running an unbounded scrape against a forever-growing `~/.claude/sessions/` or `~/.codex/sessions/` on every autosave is too costly in many-pane workspaces and contends with autosave fingerprinting. The scrape scheduler runs on its own debounced cadence (target ≥ 30 s on the happy path; debounced down on pull-on-demand events).
- **Bounded by the surface's declared kind only.** A surface declared as `terminal_type=codex` runs only the codex scraper, not all registered strategies. A surface with no declared kind runs no scrape.
- **Bounded by top-N most-recent files by mtime** within the kind's session directory. The scraper does not scan the entire directory; it reads the directory entries, sorts by mtime, and considers at most the top N (default 16) candidates.
- **Filename-as-id where possible.** Where a TUI encodes the session id in the filename (Claude does; codex's `<uuid>.jsonl` does), the scraper reads only filename + mtime + size and never opens the file unless content parsing is required.
- **At quit** (`applicationWillTerminate`), forced one-shot scrape per surface. Captures any session the hook might have missed.
- **At launch on crash recovery** (no clean-shutdown marker found), forced. Replaces any cached push value.

#### Privacy contract for scrape

`~/.claude/sessions/`, `~/.codex/sessions/*.jsonl`, and any future TUI's session storage may contain transcripts (prompts, file paths, model outputs, possibly secrets). The scraper MUST:

- Read metadata only (filename, mtime, size) where the session id is recoverable from metadata.
- Where structured parse is required (e.g., to pull a session id from the first line of a JSONL), perform a bounded structured parse — header fields only, with an explicit byte cap (default 4 KiB) and explicit field allowlist.
- NEVER copy transcript text, prompts, or model output into c11 snapshots, the conversation store, the global derived index, diagnostics, or telemetry.
- NEVER log transcript content. `Diagnostics.log` calls in scraper code are limited to filenames, file sizes, mtimes, candidate counts, and match reasons.

Future strategies inherit this rule; new kinds do not get to relax it without an explicit plan-review-level decision.

### Wrapper-claim (lowest priority)

The wrapper, at launch, issues `c11 conversation claim --kind <k> --cwd "$PWD"` so the surface has *something* before the TUI fires its first hook. The store mints a placeholder ref with `placeholder: true`. For TUIs that never fire hooks, this is the only push-side signal the strategy ever sees; the scraper is responsible for replacing the placeholder id with the real one once a candidate session file appears.

Wrapper-claim is **idempotent and conservative**: a wrapper-claim only writes if the existing ref is older AND of equal-or-lower provenance (`wrapperClaim` ≤ existing source). Hooks and scrapes always win over wrapper claims regardless of timestamp. This prevents an operator who types `claude` twice in the same surface from regressing a scrape-confirmed real id back to a placeholder.

### Reconciliation rule

Latest `capturedAt` wins, with source-priority tiebreaker on close timestamps (`hook > scrape > manual > wrapperClaim`). `manual` outranks `wrapperClaim` because explicit operator action should override automatic placeholder claims. Provenance is recorded on every write via `capturedVia` and `diagnosticReason`, so debugging is possible without instrumentation. (Wall-clock timestamps and filesystem mtimes are weak ordering tools under close races; if reconciliation correctness becomes an issue post-v1, escalate to monotonic store-side sequence numbers.)

## State machine

```
            ┌──────────────────────────────┐
            │                              │
            ▼                              │
    ┌────────────┐   wrapper claim   ┌────────────┐
    │ (no ref)   │ ─────────────────▶ │  unknown   │
    └────────────┘                    └────────────┘
                                            │
                          first hook /      │
                          first scrape      ▼
                                       ┌────────────┐
                                       │   alive    │
                                       └─────┬──────┘
                                             │
                                             ├── TUI process ended
                                             │   (isTerminatingApp == false)
                                             ▼
                                       ┌────────────┐
                                       │  unknown   │  ← scrape on next launch
                                       └────────────┘   reclassifies
                                             │
                                             ├── c11 shutting down (isTerminatingApp)
                                             │   OR c11 crashed
                                             ▼
                                       ┌────────────┐
                                       │ suspended  │  ← auto-resume on next launch
                                       └────────────┘
```

`unknown` is the resting state when c11 came up after a crash and found a ref it cannot classify, OR when a TUI's lifecycle hook fires "ended" but cannot distinguish user-initiated `/exit` from process crash, terminal kill, or wrapper failure. Strategy re-runs pull-scrape, then transitions to `suspended` (session file present, resumable) or `tombstoned` (session file is gone or operator explicitly ended).

`alive → tombstoned` is the conservative path: only fires when the strategy can determine "user explicitly ended this" *and* preservation is not safer. SessionEnd-from-hook with `isTerminatingApp == false` is **not** sufficient on its own — the hook payload typically does not distinguish user `/exit` from Claude crash, terminal kill, or wrapper failure, and tombstoning on all of these would refuse auto-resume of work the user expected to continue. The store transitions such cases to `unknown` and lets the next-launch scrape make the call. Tombstone fires explicitly via `c11 conversation tombstone --reason <text>` (e.g., from an explicit operator-initiated "end this conversation" UX) or when next-launch scrape confirms the session file is gone. For codex (no hook), the strategy never tombstones autonomously; absent-on-restore session-file transitions to `unknown` (not `tombstoned`), and operators clear via `c11 conversation clear --surface <id>`.

`alive → suspended` fires when c11 starts shutting down. The store walks all surfaces, sets active refs to `suspended`, then the snapshot is written.

## Crash recovery

**The marker:** inverted dirty/clean semantics, scoped per c11 bundle.

- At launch, c11 writes a *dirty* sentinel `~/.c11/runtime/shutdown.<bundle_id>.dirty` containing the launch timestamp.
- During termination, c11 runs forced final scrape across all surfaces, writes the snapshot synchronously, and **only after** both succeed, replaces the dirty sentinel with `~/.c11/runtime/shutdown.<bundle_id>.clean` containing the clean-shutdown timestamp.
- On next launch, c11 reads the prior-shutdown sentinel: `.clean` means clean shutdown; `.dirty` (or missing) means crashed/sleep-killed/power-died/kernel-panicked between launch and final-snapshot completion.

Writing the marker only after both forced scrape and snapshot have completed eliminates the false-clean window of the original `shutdown_clean`-at-start design.

Bundle-scoping (`shutdown.<bundle_id>.*`) prevents debug builds, release builds, and concurrent c11 instances from cross-contaminating each other's crash markers. Encoding the clean-shutdown timestamp in the file lets recovery treat snapshots whose `capturedAt` is far from the marker time as crash-recovery candidates even when a `.clean` is present.

**On crash:**

1. Load the most recent snapshot.
2. For every active ref in the snapshot, transition state to `unknown`.
3. Run pull-scrape for every `unknown` ref. Update or transition to `tombstoned` only if the session file is gone *and* the strategy is confident (Claude with hook history); otherwise leave at `unknown`.
4. Proceed with normal restore, including resume only for refs that landed at `suspended`.

The pull-scrape on crash recovery is the "primary source on death." Push values are not trusted until they are fresh again.

## Per-TUI strategies

The v1 strategies ship in three honest tiers:

1. **Strong resume** — Claude Code. The wrapper injects `--session-id` and the SessionStart hook reports the real id. Identity is deterministic.
2. **Heuristic resume** — Codex. cwd + mtime + surface activity is heuristic, not deterministic. The strategy ships an explicit ambiguity policy: when more than one candidate session matches the surface filter, **do not auto-resume**; record `diagnosticReason`, set state to `unknown`, surface a sidebar advisory.
3. **Fresh launch only** — Opencode, Kimi. Their session storage has not been mapped. Wrapper-claim mints a placeholder; resume launches a fresh process.

A merge-blocking fixture-driven test reproduces the 2-pane same-cwd staging-QA failure (the bug the plan exists to fix) and verifies the Codex strategy's behavior under ambiguity.

### Claude Code

- **Capture push:** SessionStart hook → `c11 conversation push --kind claude-code --id <session_id> --source hook`. Writes the ref with `state = .alive`, `placeholder = false`.
- **Capture pull:** Scrape `~/.claude/sessions/` (path verified at impl) for the most recent session matching the surface's cwd. The strategy stores cwd in the ref payload to narrow the scrape; transcript content is NEVER read (filename + mtime carry the session id).
- **State transitions:** SessionEnd hook fires → `c11 conversation push --kind claude-code --id <session_id> --source hook --state ended`. The CLI checks `isTerminatingApp` (see below); if true, no-op (preserve ref). If false, transition to `unknown` (not `tombstoned`) — SessionEnd does not distinguish user `/exit` from Claude process crash, terminal kill, or wrapper failure. Next-launch scrape reclassifies.
- **`isTerminatingApp` query path:** Exposed via the existing socket capabilities/ping response (no new dedicated method); the field is present on every response and can be read by the CLI without an extra round-trip. CLI policy on socket failure: **treat unreachable/timeout as terminating** so we err on the side of preservation, never tombstone on socket-uncertainty. Bounded query timeout: 250 ms. A regression test exercises hook-fires-during-shutdown with a slow/dying socket and verifies the ref is preserved.
- **Id grammar:** UUID v4 (matches the existing `AgentRestartRegistry` validation). Ids that fail validation cause `resume()` to return `.skip(reason: "invalid id")`.
- **Resume:** `typeCommand("claude --dangerously-skip-permissions --resume <id>", submitWithReturn: true)` — id is shell-quoted via the strategy's quoting helper before interpolation.

### Codex

- **Capture push:** Wrapper at launch issues `c11 conversation claim --kind codex --cwd "$PWD"`. The store mints a ref with `placeholder: true`, `id = "<surface-uuid>:<launch-ts>"` (placeholder format is irrelevant; recognition is via the `placeholder` field, not id parsing). No hook surface from codex itself.
- **Capture pull:** Scrape `~/.codex/sessions/*.jsonl` (path verified at impl). Filter: same cwd as the surface AND mtime ≥ wrapper-claim time AND mtime ≥ surface's last-activity timestamp (see §Surface activity). Filename pattern `<uuid>.jsonl` carries the session id; the scraper does not parse transcript content.
- **Ambiguity policy:** if more than one candidate session matches the surface filter, the strategy returns the ref with `state = .unknown`, `placeholder` cleared but `id` left at the most plausible candidate, and a `diagnosticReason` like `"ambiguous: 3 candidates; chose newest"`. `resume()` returns `.skip(reason: "ambiguous")` for `state = .unknown`. A sidebar advisory surfaces the situation; operators clear via `c11 conversation clear --surface <id>` to force a fresh launch.
- **State transitions:** No hook to detect end. Absent-on-restore session-file transitions to `unknown` (NOT `tombstoned`) — a transient unreadable mount, a cwd path change, or an out-of-band file move would otherwise silently kill resumability. Operators tombstone explicitly.
- **Id grammar:** UUID v4 (codex session filenames are `<uuid>.jsonl`). Ids that fail validation cause `resume()` to return `.skip(reason: "invalid id")`.
- **Resume:** `typeCommand("codex resume <session-id>", submitWithReturn: true)` — id is shell-quoted via the strategy's quoting helper before interpolation. The *specific* id, not `--last`.

### Surface activity

The Codex scrape filter relies on a per-surface `lastActivityTimestamp`. Definition for v1:

- Updated by terminal input AND terminal output, debounced to 250 ms.
- Updated by `c11 conversation claim` (so the wrapper-claim establishes a lower bound).
- Persisted in the workspace snapshot; survives c11 restarts.
- Read via the conversation store's strategy-input bundle.

Without this primitive, the Codex disambiguation cannot be tested or implemented. Defining it before strategy implementation is on the merge-blocker list.

### Opencode

- **Capture push:** Wrapper claim only (placeholder ref).
- **Capture pull:** TBD at impl — opencode's session storage needs reverse engineering. If none exists, strategy is fresh-launch-only and `capture()` returns `nil` (the wrapper claim is left as the only ref).
- **Resume:** `.skip(reason: "fresh-launch-only")` if `placeholder: true` (no real id ever resolved); otherwise `.typeCommand(text: conversationShellQuote("opencode"), submitWithReturn: true)`.

### Kimi

Same shape as opencode. Strategy starts as fresh-launch; grows scrape support if/when kimi's session storage is mapped out.

### Future kinds

A new kind is one Swift strategy file plus one scraper file in `Sources/Conversation/Strategies/` and `Sources/Conversation/Scrapers/`, registered in the `ConversationStrategyRegistry`. CLI help, wrapper packaging in `Resources/bin/`, Localizable strings, and a fixture-backed test are part of "implementing a new kind." The `ConversationStrategyRegistry` is a hardcoded enum-shaped struct; we are not building a plugin system.

## Wrapper changes

Wrappers shrink to:

```bash
# Pseudo-shape; real wrappers stay bash.
1. Detect c11 environment (CMUX_SURFACE_ID + live socket). Pass through if absent.
2. c11 conversation claim --kind <my-kind> --cwd "$PWD" >/dev/null 2>&1 &
3. (For TUIs with hooks: inject the necessary flags so hooks fire `c11 conversation push`.)
4. exec "$REAL_TUI" "$@"
```

The current `c11 claude-hook session-start` collapses to `c11 conversation push --kind claude-code --id <id-from-stdin>`. The `claude-hook` CLI subcommand stays as a thin translator (parses the SessionStart JSON payload, calls `conversation push`) so existing hook configurations keep working. Metadata-writing logic (`claude.session_id` reserved key) moves out.

The codex wrapper gains the `claim` call (the current wrapper omits this; it only sets `terminal_type` via `set-agent`). The `set-agent --type` call stays for sidebar chip rendering and other metadata consumers. The wrapper's existing comment block justifying `codex resume --last` becomes stale once this lands and must be rewritten in the same PR to describe the `c11 conversation claim` flow.

`CMUX_DISABLE_AGENT_RESTART=1` continues to gate **resume execution only**, not capture. The wrapper still issues `c11 conversation claim` regardless; hooks still report; scrapers still run. An operator who turned off auto-resume retains observability (`c11 conversation list/get` still works) for debugging when re-enabling.

## CLI surface

```
c11 conversation claim --kind <k> [--cwd <path>] [--id <id>]
c11 conversation push --kind <k> --id <id> --source <hook|scrape|manual> [--payload <json> | --payload @<path>]
c11 conversation tombstone --kind <k> --id <id> [--reason <text>]
c11 conversation list [--surface <id>] [--workspace <id>] [--json]
c11 conversation get --surface <id> [--json]
c11 conversation clear --surface <id>
```

`list` and `get` are observability for operators and agents. `get --json` returns the active ref, state, captured source, captured time, payload summary, `diagnosticReason`, and whether a registered strategy can resume it — this is the operator-visible artifact for the wrong-session debugging path that motivated the plan. `clear` is the explicit "wipe this surface's conversations" escape hatch.

`--payload` accepts inline JSON or `@<path>` to read JSON from a file (mirrors the `HOOKS_FILE` ergonomics in `Resources/bin/claude` so hook authors writing bash do not need to shell-quote JSON).

All commands resolve `--surface` from `CMUX_SURFACE_ID` if unset, **without falling back to focused-surface**. If the env var is missing and no flag was given, the command errors out.

## Snapshot integration

### Per-panel embedded (source of truth)

`SurfaceConversations { active: ConversationRef?, history: [ConversationRef] }` is embedded directly on each `SessionPanelSnapshot`, not as a sibling map keyed by surface id. Embedding makes the conversation follow the panel through `oldToNewPanelIds` remapping naturally, eliminates the orphan-map class of bugs that a sibling map keyed by old surface ids would invite when stable panel ids are disabled, and removes the need for an explicit pruning rule for surfaces that no longer exist.

On capture, the `ConversationStore` is asked for active+history refs for each panel and the result is serialized into that panel's snapshot. On restore, the executor reads the field per-panel, populates the in-memory `ConversationStore` for the new surfaces, then schedules the resume pass that already exists in `Workspace.scheduleAgentRestart` — but the pass now consults `ConversationStore` + strategy registry instead of the inline `pendingRestartCommands` registry lookup.

`history: []` is written explicitly as an empty array in v1 (not omitted) for stable `--json` output across v1/v2 and to avoid special-casing in tooling consumers.

### Global derived index (read-only view)

A `~/.c11/conversations.index.json` aggregates active-and-suspended refs across all known snapshots. It is a *derived* view, rebuilt on launch by scanning `~/.c11-snapshots/`. If corrupted or out of sync, rebuilt without ceremony.

v1 ships the in-memory build only; the on-disk file lands when caching becomes worth it. The persistent file is *not* the source of truth; the snapshots are. This index enables future UI ("bring back any past claude conversation into a new pane") without locking us into that UI now.

## Blueprints

Blueprints stay state-free templates. They do **not** carry conversation refs. Spawning a blueprint creates fresh surfaces with no active conversations; the wrapper-claim flow populates conversations from the moment the user starts the TUI.

The Conversation primitive does not appear in the blueprint schema. If we ever ship "blueprints with pinned conversations" (v2+ feature), it lands as an additive optional field; v1 makes no provision for it but does not foreclose it.

## Conversation history

Persisted shape is `SurfaceConversations { active: Ref?, history: [Ref] }`. v1 only ever populates `active`; `history` is written as an empty array (not omitted) and ignored on reads.

When we ship history (v1.x or v2):

- Tombstoned refs move to `history` rather than being deleted.
- Surface UI surfaces history as a "previous conversations" picker.
- The strategy can resume from history with the same `resume(surface, ref)` call.

No code changes required to v1 to enable this; just do not break the field shape.

## Remote / cloud forward-compat

`ConversationRef.kind` and `ConversationRef.id` are opaque to the store. A future `claude-code-cloud` strategy interprets `id` as a remote conversation URL; its `resume` action would be a `typeCommand` of the appropriate CLI invocation (with shell-quoted id). The `ConversationStore` does not need to know.

The same primitive could host SSH-tunneled remote agents, web-hosted Claude conversations, or future agent services. v1 ships local strategies only; the seam is what matters.

## ResumeAction execution

The current `Workspace.scheduleAgentRestart` already runs on the main actor with a 2.5 s delay (`SessionPersistencePolicy.agentRestartDelay`). It stays. The change is what runs inside it.

```swift
private func scheduleAgentRestart(...) {
    let plans = pendingRestartPlans(from: snapshot)  // [(panelId, ResumeAction)]
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        for (panelId, action) in plans {
            self?.execute(action, on: panelId)
        }
    }
}

func execute(_ action: ResumeAction, on panelId: UUID) {
    switch action {
    case .typeCommand(let text, let submit):
        guard let panel = panels[panelId] as? TerminalPanel else { return }
        if submit { TextBoxSubmit.send(text, via: panel.surface) }
        else      { panel.surface.sendText(text) }
    case .skip(let reason):
        Diagnostics.log("conversation.resume.skipped panel=\(panelId) reason=\(reason)")
    }
}
```

## Concurrency

The `ConversationStore` is accessed from multiple threads:

- Socket handlers (off-main) on every CLI call (`claim`, `push`, `tombstone`, `list`).
- Main actor on snapshot read/write at quit + restore.
- Scrape scheduler thread on pull-scrape ticks.

**The store is a Swift `actor`.** Idiomatic for state-isolated per-surface map; aligns with c11's gradual move to actor isolation; clean test seam where every CLI call is one `await store.<verb>()`. State transitions are the critical-section boundary by virtue of actor isolation; strategy calls (which are deterministic given collected signals) happen outside the actor — the store hands a strategy a snapshot of inputs, awaits the result, and applies it under isolation.

Where existing socket handlers are sync, they call into the store via a small `Task { await … }` adapter. If a measured hot-path shows the actor introduces latency over the existing socket-handler shape, fall back to a serial dispatch queue with sync accessors as a tracked migration; the choice is documented as `actor` for v1.

## Failure modes and how each is handled

Rows marked **(v1.1)** depend on the deferred forced-pull-scrape pass; in v1.0 the listed v1.1 behaviour does not engage and the store falls back to "no resume for that ref" (legacy `AgentRestartRegistry` behaviour via the kill-switch path).

| Failure | Today | With ConversationStore |
|---|---|---|
| Hook fires after shutdown begins | Clears metadata | `isTerminatingApp` check; no transition |
| Hook env strips `CMUX_SURFACE_ID` | Silently routes to focused | CLI errors out; no write; **pull-scrape catches up (v1.1)** |
| TUI crashes before hook fires | No ref captured | **Pull-scrape on next autosave catches it (v1.1)** |
| c11 crashes | Snapshot may be stale | `unknown` transition (v1: post-`seedFromSnapshot`); **+ forced pull-scrape on launch (v1.1)** |
| Two panes same TUI same cwd | "last wins" | Push-id deterministic for Claude (v1: hook fires while alive). **For Codex strategy, multi-candidate triggers ambiguity policy (state → `unknown`, advisory surfaced, no auto-resume) (v1.1, depends on cwd recovery design call).** |
| Sleep / power-off mid-session | Same as crash | Same as crash |
| TUI session file deleted out-of-band | Silent stale resume | **For Claude: pull-scrape returns nothing → `tombstoned`. For hookless (Codex/Opencode/Kimi): pull-scrape returns nothing → `unknown` (operator clears explicitly) (v1.1)** |
| Wrapper not on PATH (system update) | Silent loss of capture | Wrapper-claim absent → strategy degrades to pull-scrape only; no regression |

## Testing

- **Unit tests** for each strategy's `capture` and `resume` against fixture session-storage layouts. No live TUIs.
- **Unit tests** for the state machine: every transition exercised, including the `isTerminatingApp` gate.
- **Unit tests** for crash recovery: simulate missing/dirty shutdown sentinel, verify `unknown` transition + pull-scrape behavior.
- **Failure-mode test mapping (1:1 with §Failure modes table).** A `ConversationStoreFailureModeTests.swift` (or equivalent) with one test per row:
  - `testHookFiresAfterShutdownBegins` (slow/dying socket; verify ref preserved)
  - `testHookEnvStripsCmuxSurfaceId` (CLI errors out; pull-scrape catches up)
  - `testTuiCrashesBeforeHookFires` (pull-scrape on next autosave catches it)
  - `testCrashRecoveryUnknownTransition` (dirty sentinel found; refs → unknown → scrape)
  - `testTwoPanesSameTuiSameCwd` (Codex ambiguity policy: state→unknown, no auto-resume, advisory surfaced)
  - `testSleepPowerOffMidSession` (same as crash recovery)
  - `testTuiSessionFileDeletedOutOfBand` (scrape returns nothing → unknown for hookless, tombstoned for Claude with hook history)
  - `testWrapperNotOnPath` (wrapper-claim absent → strategy degrades to pull-scrape only; no regression)
- **Fixture-driven regression test for the staging-QA bug.** `testCodexTwoPanesSameCwd_2026_04_27` (or similar) reproduces the 4-pane Claude/Codex failure that motivated this plan. Merge-blocker.
- **Integration test** for snapshot round-trip: workspace with N surfaces, each with a different conversation kind, captured + restored, refs match.
- **Manual QA matrix** (operator-driven): the 4-pane Claude/Codex test, crash-recovery (`kill -9 c11`), mixed-kind workspaces, clean Cmd+Q, hook-fires-during-shutdown, user `/exit` tombstone, wrapper-not-on-PATH degradation.

The architecture is designed to make the staging-QA bug class structurally less likely (push-id where available, ambiguity-aware where not), but identity for hookless TUIs remains heuristic; the fixture-driven regression test is what proves the bug stays fixed.

## Rollout

- **One-release backward-compat bridge for `claude.session_id` reserved metadata.** PR #89 has shipped opt-in in 0.43.0 and default-on in 0.44.0-pre, so operators (and Atin's testing rigs) have snapshots where `claude.session_id` is baked into surface metadata. On snapshot read, if `surface.metadata.claude.session_id` is present and the panel's `SurfaceConversations.active` is empty, lift the value into a `ConversationRef(kind: "claude-code", id: <value>, placeholder: false, capturedVia: .scrape, state: .unknown, diagnosticReason: "lifted from legacy claude.session_id metadata")` and run the standard reconcile path. New writes drop the `claude.session_id` metadata key. The bridge is removed in 0.46.0 (or v1.1, whichever ships later). A unit test covers the read-side path.
- **No feature flag for the architecture itself.** The new design is the only design. The current `agentRestartOnRestoreEnabled` policy flag stays as the global on/off for *resume execution* (off-by-default with env-var to flip on, until a v1.0 promotion in a later release). Capture (claim, push, scrape) runs regardless of the flag — see §Wrapper changes.
- **Skill update is part of the change, not a follow-up.** Per c11's `CLAUDE.md`, every change to the CLI, socket protocol, metadata schema, or surface-model is incomplete until the skill is updated. The `c11 conversation claim|push|tombstone|list|get|clear` surface, the no-focused-fallback rule, the agent-facing inspection workflow (`c11 conversation get` before debugging resume), and any deprecation note on `claude-hook` MUST land in `skills/c11/SKILL.md` (and adjacent skill files where appropriate) in the same merge as the implementation. Conversation primitives are agent-facing and warrant **progressive discoverability** per skill.md best practices: a brief mention in the top-level skill so agents know the primitive exists, then deeper reference (CLI verb table, lifecycle states, ambiguity behavior, examples) in a peer reference file (e.g., `skills/c11/references/conversation.md`) loaded on demand. Treat the skill update as a merge-blocker.
- **Architecture-level kill switch.** A `CMUX_DISABLE_CONVERSATION_STORE=1` env var is honored on launch: when set, c11 falls back to the legacy `claude.session_id` reserved-metadata path that the backward-compat bridge already understands, and the new wrapper-claim/push/scrape paths no-op. The kill switch ships only for the v1 release window — removed in 0.46.0 / v1.1 alongside the legacy metadata bridge. This is a rollback rail for store bugs that escape pre-release validation; it does not gate `agentRestartOnRestoreEnabled` behavior, which remains the runtime resume on/off. Scope of the safety net: `claude-hook session-start` no longer writes the legacy `claude.session_id` reserved key regardless of the kill switch, so the kill switch only restores resume capability for already-captured 0.43.0 / 0.44.0-pre snapshots. New sessions captured under the kill switch will not resume on restart. The kill switch is a one-release safety net for already-captured state, not a full rollback.
- **0.44.0 ships with the conversation-store as its marquee feature.** The other 25+ upstream picks ride along. The held PR #94 gets the implementation diff stacked onto its branch (or, more likely, the branch is recreated from main after impl merges to keep history clean). The current 0.44.0 changelog entry for "Claude Code session resume across c11 restarts" gets rewritten to describe the conversation-store version.

## Out of scope (do not ship in this work)

- Cloud / remote agent strategies.
- Conversation history UI ("show me past sessions").
- Plugin system for third-party strategies.
- Cross-machine conversation portability.
- "Resume conversation X in a new pane in a fresh workspace" UX (the global index gets an in-memory build; UI to consume it is a later piece).
- Replacing the current `claude-hook` CLI surface (stays as the hook entry point; just routes to `conversation push`).
- Persisting the global derived index to disk (in-memory only in v1).
- Any change to blueprint schema.

## Success metric

c11 succeeds at this work when an operator can close a c11 window with **15 tabs open, 10 of which are coding-agent surfaces** (Claude Code, Codex, mixed kinds, multi-pane same-cwd), and reopen c11 to find all 10 agent conversations preserved and resumable. That is the bar. Number of TUIs integrated, reduction in support reports, add-time per new strategy — all secondary to this end-to-end "I had ten agents going, they all came back" experience.

## Open questions for plan review

The Trident plan review (2026-04-27, see `conversation-store-architecture-review-pack-2026-04-27T2025/`) resolved most of the original 12 open questions; revisions above bake in the answers. Operator decisions on the surfaced strategic calls (S1–S11):

- **Resolved (applied above):** ship the work in 0.44.0 with the conversation-store as marquee feature (S1); add a `CMUX_DISABLE_CONVERSATION_STORE=1` architecture-level kill switch for the v1 release window (S2); keep pull-scrape in v1, do not defer to v1.1 (S3); polling for v1 scrape (not FSEvents/kqueue — revisit in v1.x if scrape latency becomes a felt problem) (S4); flat `kind` strings, defer namespacing (S5); progressive-discoverability skill update (S6); promote `cwd` to core `ConversationRef` (universal, load-bearing for Codex scrape filter), keep `git_branch` in payload (S7); skip confidence-scored refs / `ResumePlan` for v1 — `state = .unknown` + `diagnosticReason` already cover the "don't auto-resume the uncertain ones" case (S8); stay agnostic to Lattice — this is c11 infrastructure, not Lattice-bound (S9); do not land this primitive upstream in cmux, stays c11-only (S10); success metric defined above (S11).

The remaining strategic call (still open):

1. **Hook payload routing.** Should `c11 claude-hook session-start` keep its full handler (existing telemetry breadcrumbs + sessionStore) or fully collapse to `c11 conversation push`? The latter is cleaner; the former preserves the existing breadcrumb taxonomy. (Original Q3; can be decided at impl time.)

(See `conversation-store-architecture-review-pack-2026-04-27T2025/synthesis-action.md` §"Evolutionary worth considering" for three ideas worth a future look: public strategy-integration contract doc (E1), strategy fixture harness as a deliberate compounding tool (E2), `ConversationState × ResumePolicy` split (E3).)

## References (current code; line numbers will shift)

### Existing files (modified)

- `Sources/AgentRestartRegistry.swift` — current registry; replaced by per-kind strategies.
- `Sources/Workspace.swift:336-426` — current `pendingRestartCommands` + `scheduleAgentRestart`; refactored to consume `ResumeAction`.
- `Sources/AppDelegate.swift:2765-2783` — `applicationShouldTerminate` / `applicationWillTerminate` snapshot capture; gains the inverted dirty/clean shutdown-sentinel write (after final scrape + snapshot).
- `CLI/c11.swift:13244-13582` — current `runClaudeHook`; refactored to route through `conversation push|claim|tombstone`.
- `CLI/c11.swift:7238-7266` — current `resolveSurfaceId`; the `nil → focused-fallback` is the source of the env-loss footgun. Fallback removed for the conversation CLI surface; behavior preserved (with deprecation warning) elsewhere if external callers depend on it.
- `Resources/bin/claude` — current wrapper; rewritten smaller.
- `Resources/bin/codex` — current wrapper; gains `c11 conversation claim` call. The existing comment block justifying `codex resume --last` is rewritten to describe the new flow.
- `Sources/SessionPersistence.swift` — `SessionPanelSnapshot` schema; gains `surface_conversations: SurfaceConversations` field embedded on each panel.
- `Sources/WorkspaceSnapshotStore.swift` — snapshot read/write; round-trips the new field; lifts legacy `claude.session_id` metadata into a `ConversationRef` on read for one release window.
- `skills/c11/SKILL.md` — gains `c11 conversation` documentation, the no-focused-fallback rule, and agent-facing inspection workflow. Merge-blocker.
- `notes/session-resume-fix-plan.md` — the C11-24 hotfix plan, now obsolete.

### New files

- `Sources/Conversation/Store.swift` — `ConversationStore` (Swift `actor`).
- `Sources/Conversation/Ref.swift` — `ConversationRef`, `CaptureSource`, `ConversationState`, `SurfaceConversations`.
- `Sources/Conversation/ResumeAction.swift` — `ResumeAction` enum and executor entry point.
- `Sources/Conversation/StrategyRegistry.swift` — hardcoded enum-shaped `ConversationStrategyRegistry`.
- `Sources/Conversation/Strategy.swift` — `ConversationStrategy` protocol + per-strategy id grammar/quoting contract.
- `Sources/Conversation/Strategies/ClaudeCode.swift` — Claude Code strategy.
- `Sources/Conversation/Strategies/Codex.swift` — Codex strategy (with ambiguity policy).
- `Sources/Conversation/Strategies/Opencode.swift` — Opencode strategy (fresh-launch only in v1).
- `Sources/Conversation/Strategies/Kimi.swift` — Kimi strategy (fresh-launch only in v1).
- `Sources/Conversation/Scrapers/ClaudeCodeScraper.swift`, `CodexScraper.swift` — bounded I/O providers, mockable for tests.
- `Sources/Conversation/SurfaceActivity.swift` — per-surface `lastActivityTimestamp` primitive (terminal input + output, debounced).
- `Tests/ConversationStoreTests/ConversationStoreFailureModeTests.swift` — 1:1 mapping with §Failure modes table.
- `Tests/ConversationStoreTests/Fixtures/codex/two-panes-same-cwd/` — fixture dir for the staging-QA regression test.
