# C11-164: Crash-resume completion — the force-kill scenario as the acceptance gate

**Wave 2 · sub-agent-full · SPEC RES-1..RES-5 · stops at `pr_open` (operator merges).**
Contract: `docs/cycles/2026-07-truth-and-stability/{SPEC,EVALUATION,BUILDPLAN}.md`.
Design inputs: `docs/conversation-store-architecture.md`, `docs/c11-state-save-load-and-crash-resume.md`.

---

## 0. Governing insight — this is a completion + acceptance gate, not a greenfield build

The cold read of the codebase (three read-only surveys, 2026-07-07, main @ post-`aee698a4f`) found that the
crash-resume **machinery is already implemented and merged**, across C11-131 and C11-151..154 plus follow-on
fixes (PRs #239, #273, #274, #275, #276, #289, #300). Specifically, already on main:

- `Sources/Conversation/` — full store (`Store.swift` actor), 8 strategies (claude-code, codex, pi, omp,
  opencode, kimi, grok, github-copilot), 4 registered scrapers (claude-code, codex, pi, omp),
  `ShutdownSentinel`, `SnapshotBridge`, `ScrapeCapturePipeline`, `SurfaceActivity`, `Ref`, `ResumeAction`.
- **Crash fix landed**: `ConversationStore.reclassifyAfterCrash(registry:filesystem:)` (`Store.swift:246`)
  replaces the old blanket `markAllUnknown`; wired at `AppDelegate.swift:3319-3334` on the dirty-sentinel branch
  (stat-only transcript verify → `.suspended` / `.unknown`).
- **Pull-scrape rail wired into live restore (C11-152)**: `AppDelegate.swift:3277-3289` runs
  `ScrapeCapturePipeline(scrapers:.v1(), strategies:.v1)` via `ConversationStore.runScrapeCapture` on every
  restore that has a snapshot (seed → scrape-capture → reclassify-on-dirty).
- **CLI/socket surface complete (C11-131)**: `c11 conversation {claim,push,tombstone,list,get,clear}`,
  `c11 state save`, `c11 state verify`, `c11 app restart [--no-resume]`, socket `session.save`.
- **Tests exist**: Tier-1 `ConversationCrashRecoveryTests.swift` (+ `ShutdownSentinelTests`,
  `WorkspaceConversationResumeTests`, per-strategy suites); Tier-2 `tests_v2/test_crash_resume_e2e.py`
  (kill-9 relaunch harness, C11-131).

**Therefore RES-2's discipline governs the whole ticket: "Whatever the scenario requires is in scope … anything
the scenario does not exercise is out of scope."** The definition of done (RES-1) is the multi-kind force-kill
scenario passing, not a feature checklist. The plan is: **build the multi-kind scenario harness first, run it
against a tagged build, and let the red rows tell us which subsystems still need wiring** — then close exactly
those gaps and nothing more.

Three gaps are already identified by the cold read and are **named explicitly in RES-2**, so they are pre-cleared
as in-scope the moment the harness demonstrates the need (it will, for at least the first two):

- **G1 — the harness itself is single-kind.** `test_crash_resume_e2e.py` only drives claude-code (fake `claude`
  PATH shim + fake transcripts). RES-1 requires ≥10 conversations, ≥3 workspaces, ≥3 kinds incl. claude-code +
  codex + one of pi/omp/opencode. This is the central build.
- **G2 — SurfaceActivityTracker persistence is dead code.** `SurfaceActivity.swift:70/79` define `seed(from:)` /
  `snapshot()` but **nothing calls them**; `SessionPanelSnapshot` (`SessionPersistence.swift:315`) has no activity
  field. So `lastActivityTimestamp` is in-memory only and is lost across a crash. Named in RES-2.
- **G3 — Codex cwd recovery is a structural no-op.** `CodexScraper` stamps the surface's own cwd onto every
  candidate (`ClaudeCodeScraper.swift:117-121`), so `Codex.swift:31`'s `cwd != candCwd` filter never
  discriminates; codex disambiguation rests entirely on mtime/claim-time/activity floors. Named in RES-2.

---

## 1. Approach per SPEC ID

### RES-3 — the repeatable multi-kind harness (do this FIRST; it is the oracle for everything else)

Extend the existing Tier-2 harness into a new file `tests_v2/test_crash_resume_multikind_e2e.py` (keep the
claude-only `test_crash_resume_e2e.py` intact as the RES-4 regression anchor; the multi-kind file reuses its
discovery/launch/kill helpers — factor shared helpers into `tests_v2/crash_resume_support.py` rather than
copy-paste).

Shape (mirrors `docs/c11-state-save-load-and-crash-resume.md` §3 Tier 2, generalized to N kinds):

1. **Per-kind fake shims** on the tagged instance's PATH, one per kind, each: (a) `c11 set-agent --type <kind>`
   so the surface's `terminal_type` resolves the kind for `ScrapeCaptureContext`, (b) `c11 conversation claim
   --kind <kind> --cwd "$PWD"` (mimics the real wrapper-claim), (c) for claude-code only, additionally emulate
   the SessionStart hook via `c11 conversation push --kind claude-code --id <uuid> --source hook` (claude is
   push-primary), (d) record its own argv to `<run>/<kind>-invocations.log`, (e) block like a TUI. Codex/pi/omp
   are **scrape-primary** — the shim does NOT push an id; the id is resolved from fake session files on disk.
2. **Per-kind fake session fixtures** at each scraper's real path, with known UUIDs and mtime > claim time:
   - claude-code → `~/.claude/projects/<cwd-slug>/<uuid>.jsonl`
   - codex → `~/.codex/sessions/<uuid>.jsonl`
   - pi → `~/.pi/agent/sessions/<cwd-slug>/<ISO-ts>_<uuid>.jsonl`
   - omp → `~/.omp/agent/sessions/<cwd-slug>/<ts>_<uuid>.jsonl`
   Fixtures are minimal metadata-only files (never real transcripts). Isolate to the tagged bundle's own temp
   HOME-relative dirs where possible; where a scraper reads a fixed `~/.<tool>/…` path, create + clean up only
   the run's own UUID-named files (never touch operator sessions).
3. **Topology**: ≥10 conversations across ≥3 workspaces spanning ≥3 kinds. Concrete default:
   `claude-code ×4, codex ×3, pi ×2, omp ×1` = 10, distributed over 4 workspaces (exceeds the ≥3/≥3/≥3 minimums
   with margin). **opencode is deliberately excluded** (its scraper is not in `ConversationScraperRegistry.v1`
   and needs SQLite fixturing — pi+omp already satisfy the "+1 of pi/omp/opencode" clause; adding opencode is
   out of scope per RES-2 unless a red row forces it).
4. **`c11 state save`** to force a synchronous snapshot, then assert the snapshot JSON carries per-panel
   `surface_conversations` for every kind.
5. **`kill -9`** the tagged instance (isolated bundle id / socket / snapshot — never the operator's prod c11;
   assert the target PID's `PROC_TOKEN` before signalling, exactly as the existing harness does).
6. **Relaunch** the same tagged build with `C11_QA_LAUNCH=resume` (or `launch-tagged-automation.sh <tag> --qa
   resume`), poll socket ready.
7. **Oracle (per-surface resume/diagnostic table)** — the decisive assertion is the **shim argv logs**, not screen
   text (screen-scraping is banned by CLAUDE.md + skill). For each surface, exactly one of:
   - **Resumed correctly**: the kind's shim was re-invoked with its resume form and the expected id —
     `claude … --resume <id>` / `codex resume <id>` / `pi --session <id>` / `omp --resume=<id>`.
   - **Honest diagnostic**: `c11 conversation list --json` shows the surface's ref in a non-resumable state
     (`unknown`/`tombstoned`) **with a non-empty `diagnostic_reason`**, and the shim was NOT re-invoked with a
     resume form.
   **Zero silent fresh-launches**: fail if any surface both (a) shows a resumable/`suspended` ref and (b) has no
   resume-form invocation in its shim log — i.e. a fresh launch masquerading as a resume.
8. **Scenario variants** (same harness, parametrized), extending the design-doc matrix to multi-kind:
   all-present (acceptance), one-transcript-missing-per-kind (that surface → honest diagnostic, others resume),
   clean `c11 app restart` (all resume), double kill-9 (idempotent), kill-switch
   `CMUX_DISABLE_CONVERSATION_STORE=1` (no resume, no error).
9. **Reruns green twice consecutively** (RES-3) — harness is idempotent: fresh run dir + UUIDs per invocation
   (vary by index/timestamp, never leak state between runs), full fixture teardown in `finally`.

### RES-1 — run the scenario, produce the recorded proof

Execute the RES-3 harness against a tagged build (`./scripts/reload.sh --tag res-post`). Produce and attach: the
per-surface resume/diagnostic table (harness stdout + the merged `c11 conversation list --json`), the shim argv
logs, and a screen recording / screenshots of the relaunched multi-workspace layout (operator spot-checks one
live run per EVALUATION). Gate: every one of the ≥10 surfaces is in the "resumed" or "honest diagnostic" column;
zero silent fresh-launches.

### RES-2 — close exactly the gaps the scenario surfaces (scope trace)

Run order: harness green on claude-code path first (proves the rig), then add codex, then pi/omp. Each newly-added
kind that fails to hit its declared tier gets a scope-traced fix:

- **G2 (SurfaceActivityTracker persistence)** — expected required for codex/pi/omp to hit their deterministic tier
  after a crash, because their scrape disambiguation uses `mtime ≥ activityFloor` and the floor is lost on
  restart, widening the candidate set → false ambiguity → `unknown`/skip. Wire it: add an activity map to the
  snapshot round-trip and seed it on restore (file map below). If the harness proves single-session-per-cwd
  fixtures never trigger false ambiguity even without it, downscope to just documenting the seam — **decide from
  the red/green rows, not speculation.**
- **G3 (Codex cwd recovery)** — only if the multi-workspace codex rows land as false-`ambiguous` (multiple codex
  sessions across workspaces colliding). Fix via a **bounded, privacy-contracted** first-line JSONL parse in
  `CodexScraper` to recover each candidate's real cwd (byte cap + field allowlist per
  `conversation-store-architecture.md` §Privacy contract), so `Codex.swift`'s cwd filter becomes real. Respect the
  structural Mirror test on `ScrapeCandidate` (no transcript-bearing fields). If the floors already disambiguate
  in the harness, leave cwd recovery out (RES-2: not exercised → out of scope) and note it as a chartered
  follow-up.
- **Crash-path ordering / forced scrape** — the design doc's "forced final scrape at quit" and "dirty-gated
  forced scrape at launch" are **not** separately wired (the restore-time scrape runs unconditionally instead).
  Do NOT add them speculatively. Add only if a harness row shows a ref that should resolve but doesn't because of
  ordering. Contingency, likely no-op.

Deliver a **scope-trace artifact**: a short table mapping each subsystem touched → the exact scenario row that
required it (RES-2 verification is "each wired subsystem maps to a scenario need").

### RES-4 — no regression to clean-shutdown resume

Keep `test_crash_resume_e2e.py` (claude-only) and every Swift conversation/resume suite green. New activity-field
in `SessionPanelSnapshot` must be **additive + optional** (decode-tolerant of old snapshots; a missing field is
empty, not an error) so existing snapshot round-trip tests and the legacy `claude.session_id` bridge still pass.

### RES-5 — docs reflect post-cycle truth

Rewrite `skills/c11/references/conversation.md`: it currently describes v1 as "snapshot-only, pull-scrape is a
v1.1 follow-up" (lines 74-92, 128-141) which is **stale** — the pull-scrape rail, per-kind exact resume (pi/omp/
opencode), and crash reclassify have all landed. Update: (a) mark pull-scrape / reclassify / state-CLI as shipped,
(b) per-kind crash-recovery guarantee table (claude-code deterministic via hook+transcript; codex/pi/omp
deterministic-with-ambiguity-policy via scraper; opencode via plugin push; grok/kimi/copilot fresh-launch), (c)
what a crash now guarantees per kind, (d) SurfaceActivity persistence + any Codex cwd change if made. Then run
`scripts/sync-installed-skills.sh c11` (HARD RULE) and verify the installed copy. Same PR.

---

## 2. File-level change map (against POST-`C11-159` extraction layout)

**Key post-extraction fact:** conversation socket handlers moved to `Sources/SocketHandlers/ConversationHandlers.swift`
and `session.save` moved into the extracted misc/snapshot handlers. **RES adds no new socket verb and touches no
`Sources/SocketHandlers/` file** — the CLI/socket seam is already complete. RES work lives in `Sources/Conversation/`,
`SessionPersistence.swift`, `AppDelegate.swift`, `Workspace.swift`, the wrappers/tests, and docs — all orthogonal to
the dispatcher extraction, so merge-conflict risk against C11-159 is low.

| Area | File(s) | Change |
|---|---|---|
| **Harness (RES-3/1)** | `tests_v2/test_crash_resume_multikind_e2e.py` (new), `tests_v2/crash_resume_support.py` (new, factored from existing) | Multi-kind build/kill/relaunch/assert; per-kind shims + fixtures; per-surface oracle table; scenario variants; twice-green idempotency |
| **Harness fixtures** | `tests_v2/fixtures/crash_resume/` (new, if non-trivial) | Fake session-file templates per kind; per-kind shim scripts |
| **G2 activity persistence** | `Sources/SessionPersistence.swift` | Add optional `surfaceActivity` (or per-panel `lastActivityAt`) to `SessionPanelSnapshot`; additive/decode-tolerant |
| | `Sources/WorkspaceSnapshotStore.swift` | Round-trip the new field on read/write |
| | `Sources/AppDelegate.swift` | On restore, `SurfaceActivityTracker.shared.seed(from:)` from the loaded snapshot (near the `seedFromSnapshot` call, ~3266); on save, populate from `SurfaceActivityTracker.shared.snapshot()` |
| | `Sources/Conversation/SurfaceActivity.swift` | Fix the stale "persisted in step 8" docstring; confirm `seed`/`snapshot` API shape |
| **G3 codex cwd (conditional)** | `Sources/Conversation/Scrapers/ClaudeCodeScraper.swift` (holds `CodexScraper`) | Bounded first-line JSONL parse to recover real cwd per candidate (byte cap + field allowlist); stop stamping surface cwd |
| | `Sources/Conversation/Strategies/Codex.swift` | cwd filter now discriminates real candidate cwd |
| **Tier-1 tests** | `c11Tests/ConversationCrashRecoveryTests.swift` or new `SurfaceActivityPersistenceTests.swift` | Activity round-trip (seed→snapshot→restore); codex cwd-recovery unit test if G3 done (fixture-backed, injected FS) |
| **Docs (RES-5)** | `skills/c11/references/conversation.md` | Rewrite to post-cycle truth; then `scripts/sync-installed-skills.sh c11` |
| **Wrappers (only if a red row demands)** | `Resources/bin/{codex,pi,omp}` | Untouched unless the harness shows a claim/terminal_type gap; not expected |

No changes to: `Sources/SocketHandlers/*`, `CLI/c11.swift` conversation/state verbs, the strategy registry list,
blueprint schema. (Explicitly out per RES-2.)

---

## 3. Test plan per EVALUATION row

| Row | Tag | Verification in this ticket |
|---|---|---|
| **RES-1** | autonomous (recorded) + operator-assisted | Multi-kind harness run on tagged `res-post` build → per-surface resume/diagnostic table + shim argv logs + screen recording of relaunched layout attached `--role validation`; operator spot-checks one live run |
| **RES-2** | autonomous | Scope-trace artifact: table mapping each subsystem changed (activity persistence, codex cwd if done) → the scenario row that required it; untouched subsystems listed as "not exercised → out of scope" |
| **RES-3** | autonomous | Harness file committed + documented (module docstring + a `references`/README pointer); CI/validator re-run shows **green twice consecutively** (capture both run logs) |
| **RES-4** | autonomous + external-oracle | `xcodebuild -scheme c11-logic … test` green (all `Conversation*`/`ShutdownSentinel`/`WorkspaceConversationResume` suites); existing `test_crash_resume_e2e.py` (claude-only) still green on tagged build; CI green |
| **RES-5** | autonomous | `references/conversation.md` diff in the same PR; `sync-installed-skills.sh c11` run + installed copy verified |

**Local loop**: Tier-1 via the safe `c11-logic` scheme (`xcodebuild … -scheme c11-logic … test
-only-testing:c11LogicTests/…`); never `open` an untagged DEV.app. Tier-2/3 harness against a **tagged** build's
socket (`C11_SOCKET=/tmp/c11-debug-res-post.sock`). Tier-3: wire the multi-kind harness into `test-e2e.yml` as a
job (`gh workflow run test-e2e.yml`; never locally) — mirrors the design doc's Tier-3 note.

**Build lock discipline**: every xcodebuild/reload.sh/test acquires the `xcodebuild` Lattice resource (≤2
concurrent across the run, operator is on the machine), heartbeats every ~10 min, releases immediately.

---

## 4. Validation-artifact plan (what gets recorded and attached, `--role validation`)

1. **Harness source** (committed) + its module docstring documenting how to run it.
2. **Recorded scenario run** — harness stdout, the merged `c11 conversation list --json` per-surface table, and the
   per-kind shim argv logs, for the all-present acceptance run.
3. **Twice-green proof** — two consecutive full-run logs (RES-3), timestamped.
4. **Screen recording / screenshots** — the relaunched 4-workspace, 10-pane layout after kill-9, showing panes
   back in place (operator live spot-check per EVALUATION RES-1). `c11 tree --no-layout` capture confirming panes
   are readable.
5. **Scope-trace table** (RES-2).
6. **CI evidence** — c11-logic green run + the e2e workflow run link.
7. **PR** attached `--type reference`; completion comment; then STOP (operator merges — Wave 2 gate).

---

## 5. Risks / seams

- **TEL ↔ RES seam on SurfaceActivity + SessionPanelSnapshot (HIGH — coordinate).** The TEL ticket (C11 telemetry
  truth) derives `working/idle` from PTY output/prompt and may also touch `SurfaceActivityTracker` and add fields to
  the metadata/snapshot store. RES-G2 also adds an activity field to `SessionPanelSnapshot` and seeds the tracker.
  Both run concurrently in Wave 2 on isolated worktrees. **Flag to the orchestrator**: keep the RES activity-field
  additive and namespaced so it merges cleanly with any TEL derived-state field; if TEL lands a persisted activity
  timestamp first, RES consumes it instead of adding a second one. Watch for double-definition on merge.
- **Privacy contract (Codex cwd, G3).** Any JSONL parse must be bounded (byte cap + field allowlist) and must not
  put transcript text into refs/snapshots/logs; the structural `ScrapeCandidate` Mirror test forbids
  transcript-bearing fields. Treat that test as a merge-blocker gate on G3.
- **Hot paths.** `SurfaceActivityTracker.recordActivity` is called on terminal output (`GhosttyTerminalView.swift:3777`)
  — already 250ms-debounced. Persistence must add work only at **save/restore** time (`snapshot()`/`seed`), never
  per-keystroke/per-output. No new work in `hitTest`/`TabItemView`/`forceRefresh` (CLAUDE.md hot-path list untouched).
- **Off-main + dlog.** Any store/persistence work stays off the telemetry main path; all `dlog` calls `#if DEBUG`-gated.
- **kill-9 safety.** The harness must kill only the **tagged** build (assert `PROC_TOKEN`/bundle id + socket before
  signalling) — never the operator's production c11. Fixture files under fixed `~/.<tool>/…` paths are created and
  torn down by UUID; never delete operator sessions.
- **Scope creep.** RES-2 is a discipline, not a suggestion. Do not "finish the v1.1 tail" wholesale
  (forced-scrape-at-quit, opencode scraper registration, global index on disk) — only what a red harness row
  demands. Everything else is a logged out-of-scope note.
- **Snapshot back-compat.** New field must decode-tolerate pre-cycle snapshots (missing field = empty), or RES-4
  regresses.

---

## 6. Localization needs

Minimal. The harness/tests carry no user-facing strings. Internal `diagnostic_reason` strings are diagnostic (not
localized today; keep consistent). **Only new user-facing string risk**: if G3 adds a sidebar advisory for codex
ambiguity, wrap it in `String(localized: "…", defaultValue: "…")` at the call site and delegate the six-locale
pass (ja/uk/ko/zh-Hans/zh-Hant/ru) to a translator sub-agent per CLAUDE.md. Not expected otherwise — the ambiguity
advisory path already exists; RES is unlikely to add net-new strings.

---

## 7. Execution decomposition (sub-agent-full — for the RESUME phase)

Buckets, mostly independent, coordinated by this delegator with own status bumps:

1. **Harness bucket (keystone, do first)** — `crash_resume_support.py` + `test_crash_resume_multikind_e2e.py`,
   per-kind shims/fixtures, run claude-only → codex → pi/omp incrementally. Produces the red rows that scope 2–3.
2. **Activity-persistence bucket (G2)** — `SessionPersistence.swift` + `WorkspaceSnapshotStore.swift` +
   `AppDelegate.swift` + Tier-1 test. Gated-in by harness red rows (expected).
3. **Codex-cwd bucket (G3, conditional)** — scraper bounded-parse + strategy filter + Tier-1 test + privacy gate.
   Only if harness shows false-ambiguity across workspaces.
4. **Docs bucket (RES-5)** — `references/conversation.md` rewrite + skill sync. Can run in parallel once behavior
   is settled.

Sequence: 1 → (2 and 4 in parallel) → 3 if needed → full validation run + artifacts → PR → `pr_open` → STOP.

---

## 8. Definition of done (this ticket)

- Multi-kind harness (≥10 conv / ≥3 workspaces / ≥3 kinds incl. claude-code + codex + pi/omp) passes on a tagged
  build; per-surface table shows every surface **resumed or honestly-diagnosed**, zero silent fresh-launches;
  reruns green twice (RES-1, RES-3).
- Exactly the scenario-required subsystems wired, with a scope-trace artifact (RES-2).
- Existing resume suites + claude-only e2e still green; CI green (RES-4).
- `references/conversation.md` updated + synced in the same PR (RES-5).
- All validation artifacts attached `--role validation`; PR opened `--base main`; ticket at `pr_open`; **operator
  merges** (Wave 2 barrier).

---

## 9. Plan-Review Cycle 1 Resolutions (AUTHORITATIVE — overrides earlier text on conflict)

The board's trident plan-review could not spawn (its c11 panes failed with `pane_too_small` in the orchestrator
workspace — an infra failure, flagged to the orchestrator, not a plan defect). An own-reviewer fallback ran two
independent headless reviewers (technical/eng lens + scope/acceptance lens) against the plan, contract, and live
code. Their findings converged and are triaged below. **These override §1–§8 on any conflict.**

### R1 [BLOCKER→resolved] — Replace the shim-argv resume oracle with a STORE-STATE oracle.
The decisive per-surface assertion in §1 step 7 ("the shim was re-invoked with its resume form") is **not
buildable**: the existing `test_crash_resume_e2e.py` deliberately does NOT assert on the resume keystroke because
restored panes re-source the operator's `~/.zshrc` and the shim does not shadow the restored PTY; its author fell
back to store-state + a separate real-binary smoke (see that file's own comments ~lines 219-224, 382-397). It also
relaunches with **auto-resume disabled** (`CMUX_DISABLE_AGENT_RESTART=1`) and reads `state` + `diagnostic_reason`
from `conversation list --json`.
- **New oracle (all kinds, uniform):** relaunch with auto-resume disabled; for each surface read the reclassified
  ref from `conversation list --json`. Define the two acceptable columns as: **(a) resolved** — ref `state ==
  suspended` with `diagnostic_reason == "crash recovery: transcript verified on disk"` (this is the strategy's
  proof it *would* resume with the correct id — the resume DECISION is the automated oracle); **(b) honest
  diagnostic** — ref in `unknown`/`tombstoned` with non-empty `diagnostic_reason`. **Zero silent fresh-launch** =
  no surface with a resumable/`suspended` ref that lacks the verified-transcript reason, and no surface left at
  `alive`/placeholder.
- **Keystroke proof** (that the typed `--resume <id>` / `codex resume <id>` / `pi --session <id>` /
  `omp --resume=<id>` actually fires) becomes a **small separate real-binary smoke** on a subset, exactly as
  C11-131 did — recorded but not the per-surface gate. Drop the claim that shim-argv proves resume "the same way"
  for scrape-primary kinds.

### R2 [MAJOR→resolved] — Fixtures MUST be adversarial; invert the fix-gating default to "ship unless disproven."
As written, the default topology (one clean session per cwd) never triggers the ambiguity policy or the lost
activity-floor, so G2/G3 get scoped out as "not exercised" while the real chartered bug (two same-cwd codex panes,
`conversation-store-architecture.md:36`) survives to the operator's live spot-check against a real `~/.codex`.
That is a false-green.
- **Amend the acceptance topology** to include, in addition to the cross-workspace spread: **≥1 workspace with two
  same-cwd codex panes**, and **≥1 cwd whose session dir carries stale+fresh files**, so the ambiguity policy AND
  the activity floor are actually exercised. Place `pi ×2` deliberately (one same-cwd pair) to exercise pi's
  ambiguity path too.
- **Invert the decision rule (overrides §1 RES-2 / §5 "gate on red rows"):** **pre-commit to shipping G2 and G3
  unless an adversarial harness row affirmatively proves the fix unnecessary.** "Ship the fix unless disproven,"
  not "skip unless a red row forces it."

### R3 [MAJOR→resolved] — G3 (Codex real-cwd recovery) is effectively MANDATORY, not conditional.
`CodexScraper.candidates` stamps the *querying* surface's cwd onto every candidate, so when a placeholder is
resolved at restore with N concurrent codex sessions present, ALL N pass the (no-op) cwd filter → `state=.unknown`
"ambiguous" → codex never reaches "resolved." So for any codex surface to land in column (a) when >1 codex session
exists, either (i) the codex real id was resolved **while alive** (live scrape) so the snapshot already carries the
specific id and `reclassifyAfterCrash`'s `transcriptExists(id)` verifies it directly — the cwd no-op does not bite
this path; or (ii) G3 is implemented so restore-time resolution disambiguates.
- **The harness MUST make the codex resolution timing explicit** and test both: a path where the id resolved while
  alive (mirrors a real long-running operator session) and the restore-time-resolution path. If the repo exposes
  no way to force/await the live scrape before `state save`, treat G3 as **required** (build it) so restore-time
  resolution works; do not rely on a 30s scheduler firing inside a fast harness.
- Reconfirmed facts: pi resume `pi --session <id>`, omp `omp --resume=<id>`, codex `codex resume <id>` — all
  ambiguity-aware deterministic (`.skip("ambiguous")` on `.unknown`). Scrapers registered in
  `ConversationScraperRegistry.v1`: claude-code, codex, pi, omp only (opencode absent — kind selection stands).

### R4 [MAJOR→resolved] — G2 wiring gap + snapshot `CodingKeys` trap.
- **G2 is a no-op as scoped.** `ScrapeCaptureContext.contexts(from:)` (AppDelegate:3277, the sole builder)
  hardcodes `lastActivityTimestamp: nil`, so even the live-populated `SurfaceActivityTracker` is never consulted at
  restore. Persisting the field + `SurfaceActivityTracker.shared.seed(from:)` accomplishes nothing **unless
  `contexts(from:)` is ALSO edited to thread the seeded floor into `ScrapeCaptureContext.lastActivityTimestamp`.**
  Add that edit to the §2 file map as a required part of G2.
- **`SessionPanelSnapshot` has an explicit `CodingKeys` enum** (`SessionPersistence.swift:355-360`). A new
  `Date?` field that is NOT added to `CodingKeys` compiles and decode-tolerates but **silently never encodes** — a
  persistence no-op that a naive round-trip test (nil on both sides) passes. **Require:** the new key is added to
  `CodingKeys`, and the Tier-1 round-trip test asserts a **non-nil** activity value survives save→load.
- **Scope note:** the activity floor helps the *same-cwd multi-session* case; it is NOT the fix for cross-workspace
  codex (that's G3). Keep both, with G3 doing the structural work.

### R5 [MAJOR→flagged to orchestrator] — TEL↔RES `SessionPanelSnapshot` collision under the pr_open barrier.
Both TEL and RES stop at `pr_open`; neither merges autonomously, so "consume TEL's field if it lands first"
(§5) is unactionable — whichever the operator merges second inherits a double-definition/rebase that a stopped
delegator won't fix. **Resolution:** raise with the orchestrator NOW to agree a single shared field name + single
writer + a named owner for the post-merge reconciliation commit (sent via mailbox `ts-orchestrator` at plan close).
Until an answer lands, RES uses a clearly RES-namespaced key and records the open coordination item in the PR body
so the operator is not silently handed a conflict.

### R6 [MINOR→adopted] — Restore-time scrape/reclassify ordering under multi-kind load.
The restore scrape (`sema.wait(.now()+1.0)`, AppDelegate:3288) and `reclassifyAfterCrash` (3333) are two
independent detached tasks each on a 1s main-thread budget. Under ≥10 surfaces walking `~/.claude`, `~/.codex`,
`~/.pi`, `~/.omp`, the scrape can exceed 1s and reclassify can race ahead of a late scrape apply. Promote this from
"contingency" to a **real risk**: the harness asserts resolution completes within budget; if it doesn't, chain
scrape→reclassify sequentially rather than two independent timed waits (small, contained fix).

### R7 [MINOR→adopted] — Harness preconditions & margin.
- Assert the pre-crash snapshot carries a `placeholder==true` wrapperClaim entry for each codex/pi/omp surface (so
  a restore-resolution failure is diagnosed as claim-capture vs resume, not conflated).
- **Provision 12–13 conversations**, not exactly 10, so one fixture/shim flake doesn't drop below RES-1's literal
  ≥10 floor.

### R8 [MINOR→adopted] — Acceptance / artifact discipline.
- `pr_open` is gated on the **autonomous recorded proof** only; the RES-1 operator-assisted live spot-check is the
  operator's at merge. Include a crisp **operator spot-check checklist** in the validation artifact (expected
  4-workspace / 12-pane layout, which panes to eyeball, which one is the same-cwd ambiguity case). Deconflict
  ownership with the C4 Result-Validator's operator smoke checklist (note the overlap; don't duplicate).
- Make explicit: the recorded scenario proof is attached **`--role validation`** (the board's `pr_open` gate),
  **distinct** from the PR handle attached `--type reference`. Don't conflate them (§4/§Test-plan tightened).
- For ≥1 diagnostic-column surface, assert the diagnostic is **surfaced to the operator (sidebar advisory)**, not
  merely present in `conversation list --json` — "honest" means visible.

### Net
Framing (completion-gate, RES-2 discipline, harness-first, additive snapshot field, privacy-bounded codex parse,
build-lock/kill-9 discipline, RES-5 skill-sync) stands. The material changes for the RESUME phase: **(1)** store-state
oracle not shim-argv; **(2)** adversarial same-cwd fixtures + "ship the fix unless disproven"; **(3)** G3 treated as
required; **(4)** G2 needs the `contexts(from:)` thread-through + `CodingKeys` entry + non-nil round-trip test;
**(5)** TEL seam escalated to the orchestrator for a single-owner decision.
