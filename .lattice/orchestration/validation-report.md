# Validation report — Exact-session resume (opencode / pi / omp)

**Phase 4 — Result Validator** (fresh terminal audit, independent of the Orchestrator)
**Audited:** 2026-06-29
**Auditor:** Result Validator (surface:126, workspace:11)
**Against:** `.lattice/orchestration/validation-plan.md` (9-row matrix) + `docs/agent-exact-resume-plan.md` (SPEC/BUILDPLAN)
**Code audited at:** `origin/main` HEAD `cf177868b` (all four merge SHAs confirmed ancestors)
**Independent test run:** full `c11-logic` suite (safe scheme) on HEAD `cf177868b` → `** TEST SUCCEEDED **`, exit 0, zero assertion failures (the 18 log lines matching "failed" are macOS WebKit/sandbox runtime noise — CFPasteboard / RBS assertions — not test failures).

---

## Verdict at a glance

**Overall: PASS (with two real-world caveats that need follow-up tickets).**

All four PRs are merged to `origin/main`; all four tickets are `done`. Every acceptance row is satisfied at the level its criterion demands. The three load-bearing live rows (1 opencode, 6 pi, 7 omp) were each **observed** as a live quit→relaunch exact-session resume on a tagged build — not just green units. Two caveats limit *out-of-the-box, multi-project* real-world behavior (neither is a regression, neither blocks the run): the bun-detection gap (C11-155, tracked) and the omp whole-tree ambiguity (GAP 1, **untracked** — recommend ticketing).

| # | Criterion | Ticket | Verdict | Basis |
|---|---|---|---|---|
| 1 | opencode resumes exact prior session (quit+relaunch) | C11-151 | **PASS** (caveat: ext.) | Observed live re-attach to `ses_0ef1b49a5ffePvUOJN5jYpSdAM` w/ prior history |
| 2 | opencode id grammar = base62, rejects garbage | C11-151 | **PASS** | `^ses_[0-9A-Za-z]{26}$` in code + I/L/O/U guard, c11-logic green |
| 3 | `session.created` plugin handler captures id | C11-151 | **PASS** | Handler present in `c11-notify.js`, pushes `conversation push --kind opencode` |
| 4 | Live scrape→capture→resume pipeline | C11-152 | **PASS** | `ScrapeCapturePipelineTests` green; seam wired into restore |
| 5 | No claude/codex regression | C11-152 | **PASS** | Regression suites green; my full c11-logic run corroborates |
| 6 | pi resumes exact session | C11-153 | **PASS** (caveat: detect) | Observed live `pi --session 019f1116-…`, exact session re-rendered |
| 7 | omp resumes exact session | C11-154 | **PASS, SINGLE-SESSION-ONLY** | Observed live omp "Welcome back!" of `019f111a`; GAP 1 limits multi-project |
| 8 | Manifest/strategy parity holds | C11-151/153/154 | **PASS** | All 3 strategies in `StrategyRegistry.v1`; 3 manifest flags = true; parity test green |
| 9 | All four PRs merged | all | **PASS** | 4/4 squash-merged; C11-151..154 all `done` |

---

## Per-row evidence

### Row 1 — opencode live exact-resume — PASS (external caveat)
Validation artifact (C11-151, `delegator-c11-151-impl` + MV certification `ev_01KW8G1YNWTGKFCDMC5YPJ20MJ`): on a tagged build, opencode session `ses_0ef1b49a5ffePvUOJN5jYpSdAM` was captured via the plugin (`source=hook`) → snapshot → quit+relaunch → opencode **re-attached to the exact session with prior history visible**; restore ran the SQLite `transcriptExists` ("transcript verified on disk"); `c11 state verify` printed the exact `cd '…' && opencode -s '<id>'`.
The id deliberately contains `U`/`O` — characters the old WIP Crockford-base32 regex would **reject** — so the live resume itself proves the base62 fix is load-bearing.
**Caveat (external, not a c11 defect):** `session.time_updated` did not advance because OpenRouter was out of credits, which blocked a fresh turn. The re-attach (the actual acceptance behavior) was observed via history + the conversation-store ref. I record this as **pass** — the criterion is "resumes the exact prior session," which was observed; the timestamp was a secondary signal blocked by an external billing condition.

### Row 2 — opencode id grammar (base62) — PASS
Confirmed in merged code: `WorkspaceMetadataKeys.swift:116` defines `pattern: "^ses_[0-9A-Za-z]{26}$"`; `SurfaceMetadataStore.swift:302` enforces it on the reserved key. Unit coverage (`OpencodeSessionIdGrammarTests`) asserts a real base62 id with `I/L/O/U` passes and UUID/empty/shell-metachar fail. MV ran these green (20 tests across grammar + reserved-key + parity).

### Row 3 — plugin `session.created` handler — PASS
`skills/opencode-plugins/c11-notify.js:35` has the `session.created` case: for root sessions only (`!info.parentID`), it pushes `conversation push --kind opencode --id <ses_…> --source hook --state alive [--cwd <directory>]`. Root-only guard correctly prevents a sub-agent session from clobbering the surface's primary conversation id.

### Row 4 — live scrape→capture→resume pipeline — PASS
The architectural gap the SPEC named ("scrape rail has 0 live call sites") is closed: per-kind scraper → `ScrapeCapturePipeline` (`strategy.capture`) → `ConversationStore.applyScrape`, invoked live from `AppDelegate.prepareStartupSessionSnapshotIfNeeded`. `ScrapeCapturePipelineTests` (7) green (MV-confirmed at commit `00e5801c9`). Public seam (`ConversationScraper`, `ConversationScraperRegistry.v1`, `ScrapeCapturePipeline`, `applyScrape`) is the foundation pi/omp build on.

### Row 5 — no claude/codex regression — PASS
C11-152's regression suites (14) green alongside the 7 new pipeline tests; app build SUCCEEDED. ClaudeCode/Codex strategies and scrapers are untouched in shape. **My own full `c11-logic` run on HEAD `cf177868b` returned `** TEST SUCCEEDED **` (exit 0, zero assertion failures)** — independent corroboration that the merged state of all four PRs together is green, with no claude/codex regression.

### Row 6 — pi live exact-resume — PASS (detection caveat)
Validation artifact (C11-153): observed live on a tagged build — pi session `019f1116-a8d7-70d5-bc9e-0c91c1050a08` resolved at restore via `captured_via=scrape, state=alive` → `pi --session '<id>'`; the restored surface **re-rendered the exact prior session**. No timestamp caveat. 20/20 c11-logic green post-rebase; parity verified (PiStrategy + manifest flag in the same commit).
**Sound impl deviation (independently verified, SPEC-aligned):** `PiScraper` does a **cwd-scoped** walk (`Pi.swift`/`PiScraper.swift:74-86` — when `cwd` is known it lists only `root/<slug>/` via `listDirectoryByMtime`). This is necessary because pi has no wrapper-claim time floor; a whole-tree top-N would make every restore ambiguous (17 pi session dirs on the test machine) and resume would always safe-skip. The slug encoding mirrors pi's own `migrations.js`. MV endorsed this as faithful to pi's on-disk `<cwd-slug>/…` model, not a scope expansion. **I confirm: PiScraper is genuinely cwd-scoped in the merged code.**
**Caveat — bun-detection (C11-155, tracked):** the live validation injected `terminal_type`; a bun-installed pi (`bun /path/...`) classifies as `unknown` in `AgentDetector`, so real-world auto-resume does not fire without a manual terminal_type. The resume *strategy* is correct; this is a detection-layer gap, ticketed separately.

### Row 7 — omp live exact-resume — PASS, **SINGLE-SESSION-ONLY**
Validation artifact (C11-154): observed live on a tagged build — omp resumed UUID `019f111a` with "Welcome back!" via the scrape rail (`can_resume=true`) in a clean dedicated cwd. 19 c11-logic green. Resume command shape `omp --resume=<id>` confirmed in `Omp.swift:93`.

**⚠ Record-accuracy correction (fresh-eyes finding — this contradicts run-state.md, agents.md, AND my own boot prompt):**
The orchestrator's run-state.md and agents.md both record that "the delegator **fixed** a whole-tree ambiguity bug (cwd-scoped OmpScraper)." **This is inaccurate.** I read the merged `Sources/Conversation/Scrapers/OmpScraper.swift` at HEAD `cf177868b` directly:
- `OmpScraper.candidates(cwd:)` (lines 54-60) calls `filesystem.listSessionsRecursivelyByMtime(root, …)` **unconditionally**. The `cwd` parameter is only used to *stamp* `ScrapeCandidate.cwd` (line 73); it is **never** used to scope the walk.
- There is **no** cwd-slug branch — unlike `PiScraper`, which has exactly that branch.
So OmpScraper **walks the whole `~/.omp/agent/sessions/` tree**. The Master Validator caught this and posted the correction on C11-154; the orchestrator's run-state was never updated to match. The MV's read is correct; the delegator/orchestrator "fixed" claim is wrong.

**Consequence:** with more than one omp session on disk across projects, restore hits the safe ambiguity-skip = **no resume**. omp resumes correctly only when there's effectively a single resolvable candidate for the cwd (which is why the live test — a clean dedicated cwd — passed). omp is therefore **weaker than pi**, which genuinely fixed this. Row 7's literal acceptance ("resumes the exact session") is met for the single-session case and the safe-skip is *correct* (better to skip than resume the wrong session), so this is **not a merge blocker** — but it is a real-world gap.

**GAP 1 is OPEN and UNTICKETED.** C11-155 covers only the bun-detection gap (GAP 2), not this. **Recommend creating a parity ticket: "OmpScraper cwd-slug-scoped walk (pi parity)."**

### Row 8 — manifest/strategy parity — PASS
`StrategyRegistry.v1` registers `OpencodeStrategy()`, `PiStrategy()`, `OmpStrategy()` (alongside ClaudeCode/Codex/Grok/Kimi/GitHubCopilot). `ConversationScraperRegistry.v1` registers `PiScraper` + `OmpScraper` (+ ClaudeCode/Codex). All three manifest entries (`opencode`, `pi`, `omp`) carry `hasConversationStrategy: true`. `AgentManifestTests.testConversationStrategyPresenceParity` enforces the match and is green.

### Row 9 — all four PRs merged — PASS
`git log origin/main` confirms all four squash-merges as ancestors of HEAD: #273 C11-152 @ `e6edf9513`, #274 C11-151 @ `60646a3ac`, #275 C11-153 @ `678098587`, #276 C11-154 @ `cf177868b`. `lattice list` shows C11-151..154 all `done`. C11-155 is `backlog` (correctly separate).

---

## Load-bearing-row verdict (rows 1 / 6 / 7)

All three were **observed live** on tagged builds (the plan's bar: "I saw it resume," not "green units"):
- **Row 1 (opencode):** full pass — exact re-attach observed; external billing caveat on a secondary timestamp signal only.
- **Row 6 (pi):** pass — exact session re-rendered; genuinely cwd-scoped scraper; bun-detection caveat for auto-fire.
- **Row 7 (omp):** pass for single-session; "Welcome back!" of the exact UUID observed — but real-world multi-project resume is gated by GAP 1 (whole-tree OmpScraper) + bun-detection.

Load-bearing condition (each at least observed-live) is **met**.

---

## Drift from BUILDPLAN

1. **PiScraper cwd-scoping** (Phase B step 2): the plan said "mirror `CodexScraper`." The delegator deviated to a cwd-scoped walk. **This is correct and SPEC-aligned** (the SPEC itself describes pi storage as `<cwd-slug>/…`; codex's whole-tree walk works only because codex has a wrapper-claim floor pi lacks). MV-endorsed. No action.
2. **OmpScraper did NOT get the same fix** (the real drift): the plan intended parity with the pi approach, the run *recorded* it as fixed, but the merged code walks whole-tree. This is the GAP 1 record/code mismatch above. **Action: ticket it.**
3. **bun-runtime detection** (not in original plan scope): surfaced during C11-154, scoped out, captured as C11-155. Correct handling.

---

## Caveats to carry forward

- **C11-155 (open, tracked, NOT a regression):** bun-installed pi/omp run as `bun /path/...`, so `AgentDetector` tags them `unknown` and the (correct, merged) resume rails won't AUTO-fire without a manual `terminal_type`. The resume strategies are correct; this is a detection-layer gap. Real-world out-of-the-box auto-resume for bun installs depends on this landing.
- **GAP 1 (OPEN, UNTICKETED — recommend ticketing):** `OmpScraper` walks the whole `~/.omp/agent/sessions/` tree; with >1 omp session on disk, restore safe-skips (no resume). omp is single-session-only as shipped, weaker than pi. run-state.md/agents.md currently **mis-record** this as fixed — see the record-accuracy note below.

---

## Process notes (for the retro)

- **Recurring CLI footgun:** all four tickets hit the `lattice code-review` empty-diff bug — the headless reviewer resolved the diff range against `LATTICE_ROOT` (the main checkout on `main`), not the worktree branch, producing a vacuous "Diff is empty" artifact. All four delegators used the documented **own-reviewer fallback** (manual review of `origin/main..HEAD`). The reviews were real, not hollow — but this is a systemic CLI bug worth fixing so the headless path works from worktrees. (MV logged it as `ev_01KW8DQMQV3XJMWZSGJKT88BJT`.)
- **Serial pbxproj-conflict chain:** every ticket added new Swift files, so each PR conflicted on `project.pbxproj` against the prior merge. Handled correctly (rebase + re-add files via the `xcodeproj` gem, one at a time) — but it's inherent friction when fanning out file-adding tickets onto one integration line. The orchestrator merged one-at-a-time as designed.
- **Record-accuracy drift (worth a retro line):** run-state.md and agents.md assert the omp cwd-scoping fix landed; the merged code shows it did not. The MV caught and flagged this; the orchestrator's narrative was not corrected. Fresh-eyes Phase-4 re-verification is exactly what caught it from sticking. **Lesson:** when a delegator "flags + fixes" mid-run, the orchestrator's summary should be reconciled against the merged diff before being written as done.
- **Final merge stall:** PR #276 sat MERGEABLE + all-checks-green for ~20 min before being merged (GitHub native auto-merge was never enabled; the pattern was manual squash-on-green). The MV flagged the stall; the merge was ultimately executed on operator instruction. Consider enabling native `--auto` merge to avoid the orchestrator-idle stall.

---

## Recommendations

1. **Create the omp parity ticket** (high): "OmpScraper cwd-slug-scoped walk (pi parity)" — port PiScraper's cwd-scoped branch to OmpScraper so omp resumes correctly for multi-project users. Until then omp is single-session-only.
2. **Correct the run record:** update the C11-154 entries in `run-state.md` (decisions log, 2026-06-29) and `agents.md` (Auto-merges + Archived) from "delegator FIXED … cwd-scoped OmpScraper" to "MV flagged whole-tree ambiguity; fix DEFERRED to a follow-up; omp single-session-only as shipped."
3. **Land C11-155** (bun-runtime detection) to make pi/omp auto-resume work out-of-the-box for bun installs.
4. **Fix the `lattice code-review` LATTICE_ROOT-vs-worktree empty-diff bug** so the headless review path works from delegator worktrees.
5. **Enable GitHub native auto-merge** on this repo's PR flow to avoid the merge-ready-but-idle stall seen on #276.

---

*Audit method: synced local checkout to `origin/main` HEAD `cf177868b`; confirmed all four merge SHAs are ancestors; read the merged strategy/scraper/registry/manifest/plugin source directly (not just artifacts); inspected each ticket's `--role validation` artifacts via `lattice comments`; ran the full `c11-logic` suite (safe scheme) as corroboration. The OmpScraper whole-tree finding is an independent code read, not a relay of the MV's claim.*
