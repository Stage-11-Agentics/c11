# Plan Review — C11-27

### 1. Verdict

**FAIL (plan-level)** — one acceptance gate is unrunnable on the operator's machine (the spike preflight false-positives on the daily-driver c11), and the §1.5 audit recipe references a file the plan never produces. Both are concrete blockers a careful implementer would hit on commit 1. Everything else is high-quality and a quick revision unblocks it.

### 2. Summary

Reviewed the C11-27 plan (split `c11Tests` into pure-logic + host-required targets) against the ticket description, the actual repo state (worktree at `c11-27-test-split` rebased on `7e0e0b282`, 101 test files, existing `c11Tests` build settings, three existing schemes, `mailbox-parity.yml` selectors), and the plan-review feedback baked into the plan. The plan is unusually thorough — naming locked, three-tier strategy decision tree, spike-first protocol, mechanical acceptance criteria, every CI file enumerated, verbatim CLAUDE.md rewrite. The blockers are mechanical: the spike's `pgrep` gate matches the operator's running c11 (currently PID 26853 at `/Applications/c11.app/Contents/MacOS/c11`), and §1.5 references `/tmp/c11-27-audit.txt` with a parse pattern that matches nothing the plan generates. Fix those and Strategy B should fly.

### 3. Issues

**[MAJOR] §2.2 / §8 — Spike preflight pgrep pattern matches operator's daily-driver c11**

The preflight check `! pgrep -fl '/c11( DEV)?\.app/Contents/MacOS/c11' || { echo 'pre-existing c11 process'; exit 1; }` aborts immediately on any machine where the operator's main c11 is running. Verified on this workstation right now:

```
26853  /Applications/c11.app/Contents/MacOS/c11
89143  …/DerivedData/c11-c11-26/Build/Products/Debug/c11 DEV c11-26.app/Contents/MacOS/c11
```

Both match the proposed regex. Since the operator runs c11 all day and frequently has tagged debug builds open in parallel, the gate fails on every realistic local invocation — exactly the case C11-27 is solving for. The in-loop monitor (`while kill -0 …; do hits=$(pgrep …) …; done`) has the same problem: it'll fire on every iteration whether or not the test phase launched anything.

**Recommendation:** Scope the pattern to test-spawned hosts only. The xctest host runs out of DerivedData and (under Strategy B) the bundle binary is at `…/DerivedData/.*/Build/Products/Debug/c11 DEV.app/Contents/MacOS/c11`. Either:

(a) Tighten the regex: `pgrep -fl 'DerivedData/[^ ]+/Build/Products/(Debug|Release)/c11( DEV)?( c11-[a-z0-9-]+)?\.app/Contents/MacOS/c11'` — excludes `/Applications/…` and the operator's `c11-26`-style tagged build paths. Verify the regex still catches an actual xctest-launched host before locking it in.

(b) Switch to delta detection: snapshot PIDs matching c11.app once at preflight, treat any *new* PID during the test phase as the failure signal. More robust to path quirks but adds 5 lines.

(c) Track via process ancestry: `pgrep -P $XB_PID -f xctest` then walk children. Cleanest but ties the script to xcodebuild's process tree, which Apple has changed before.

(a) is the smallest diff; (b) is the most robust. The plan should pick one and demonstrate it doesn't false-positive on the operator's current `pgrep -fl c11` output.

---

**[MAJOR] §1.5 — Audit recipe references a file the plan never produces**

The methodology block opens with:

```bash
for f in $(awk -F' ' '/^PURE 0 / || /^HOST 1 / {print $3}' /tmp/c11-27-audit.txt); do
```

`/tmp/c11-27-audit.txt` is referenced nowhere else in the plan and has no recipe for generation. The expected shape (`PURE 0 <file>` / `HOST 1 <file>`) matches neither the §1 markdown table nor any artifact the plan checks in. An implementer following the plan literally hits this on the first invocation of Strategy A and stalls. The §1 table is human-readable but not machine-parseable as written (columns are pipe-separated with spaces).

This blocks Strategy A end-to-end: §1.5 produces `c11-27-deps.txt`, which produces `c11-27-sources.txt`, which `scripts/c11-27-split-tests.rb` requires under `STRATEGY=A` (the script aborts without it). If §1.5 can't run, Strategy A can't run.

**Recommendation:** Either (i) add an explicit "Step 0: regenerate `/tmp/c11-27-audit.txt`" recipe — a one-liner that re-runs the §1 classifier grep and emits the expected `<verdict> <count> <path>` shape — or (ii) rewrite §1.5's input to read directly from the markdown table (e.g., parse the rows where the Verdict column is `PURE` or `VERIFY-PROMOTE`). Option (i) is closer to what the plan author seems to have intended. Either way, commit the audit script to `scripts/` so it's reproducible — re-running grep across 101 files is fast and the artifact has to match the table for the dual-compile inclusion list to be trustworthy.

---

**[MINOR] §3 script — `@testable` block rewrite leaves dangling `#if canImport(...)` if regex misses**

The script does:

```ruby
.gsub(/^@testable import c11(_DEV)?\b.*\n/, '')
.gsub(/^#if canImport\(c11_DEV\)\n@testable import c11_DEV\n#elseif canImport\(c11\)\n@testable import c11\n#endif\n/, '')
```

Verified the actual files (`MailboxIOTests.swift`, `BrowserChromeSnapshotTests.swift`, etc.) use exactly this form, so the regex matches the current corpus. But the validation gate only checks that no `@testable import c11(_DEV)?` line remains — it doesn't check for orphaned `#if canImport(c11_DEV)` blocks. If a future file (or a not-yet-renamed file from another branch) deviates in whitespace, blank lines, or comment placement, the second `gsub` no-ops, the first `gsub` strips just the `@testable` lines, and the validation passes — leaving `#if canImport(c11_DEV)` / `#elseif canImport(c11)` / `#endif` wrapping nothing, which is a compile error per Swift's conditional-compilation rules. Worse, the script claims success.

**Recommendation:** Strengthen the validation gate to also check for `^#if canImport\(c11(_DEV)?\)` left without a following `@testable import` line. Or — simpler — after the gsubs, attempt a `swift -parse` (or `xcrun -sdk macosx swiftc -parse`) on each rewritten file before `project.save`. Catches the orphan structurally instead of pattern-matching every possible deviation.

---

**[MINOR] §3 / §6 — Ruby + xcodeproj gem version unpinned; Ruby 2.6.10 is EOL**

The plan says "`gem list -i xcodeproj` → `true`" but doesn't pin a gem version. Ruby `/usr/bin/ruby 2.6.10` shipped with macOS, end-of-lifed in March 2022, and won't ship in future macOS releases. A fresh clone on a new operator workstation (or CI agent, if this script ever runs in CI) may resolve `xcodeproj` to a newer major that has changed API surface, or may have no Ruby at all on macOS 26+.

The script's API usage (`new_target`, `source_build_phase`, `build_configurations`, etc.) is the stable Xcodeproj surface and won't change soon — but locking the version costs nothing and survives an OS upgrade.

**Recommendation:** Add a one-liner at the top of `scripts/c11-27-split-tests.rb`: `gem 'xcodeproj', '~> 1.27'` (or whatever the resolved version reports today via `gem list xcodeproj`). Mention in the PR description that the script depends on system Ruby — and note that this becomes a re-do item when macOS drops Ruby. Not urgent enough to block C11-27 but worth surfacing so it doesn't surprise the next operator.

---

**[MINOR] §4.6.1 — Under Strategy A the c11-logic scheme drops `<MacroExpansion>`**

The template note says "Strategy A only; under Strategy A this MacroExpansion is omitted so xcodebuild doesn't build c11.app." That's the right intent for the build side — but `MacroExpansion` also drives how the scheme resolves `$()` variables in test target build settings and environment-variable expansion for the test action. Without it, references like `$(SRCROOT)` resolve relative to the test bundle target, which may or may not be what tests expect.

In practice, `c11LogicTests` under Strategy A is self-contained so this likely doesn't matter — none of the PURE tests touch path macros today. But the asymmetry between Strategy A and Strategy B isn't called out as a known difference, and a test that *does* rely on `$(SRCROOT)` would silently behave differently.

**Recommendation:** Either keep `<MacroExpansion>` pointing at `c11LogicTests` itself under Strategy A (cleaner: scheme remains valid for run/debug), or add a one-line note in §4.6.1 documenting the asymmetry and what to verify in the spike if Strategy A is selected.

---

**[MINOR] §5 / CLAUDE.md rewrite — "30 s warm wall time" undersells the win and adds confusion vs ticket's "<5 s"**

The ticket says the new target should "run in <5 seconds (no app launch overhead)." The plan's §8 relaxes to "test phase under 12 s on warm build" (an explicit, flagged renegotiation), and the proposed CLAUDE.md text says "around 30 seconds, dominated by `xcodebuild`'s ~10–15 s of inherent overhead." That's three different numbers in three sections, which an operator reading later won't be able to reconcile:

- Ticket acceptance: <5 s
- §8 acceptance: <12 s (test phase only)
- §5 CLAUDE.md: ~30 s (total wall)

All three are talking about different things (test phase, wall time, ticket aspiration), but the lack of common framing makes the value prop fuzzy. And ~30 s vs c11-unit's ~35 s is only a 5 s wall-time savings — the real win is "no frozen DEV.app window," not "fast."

**Recommendation:** Pick one operator-visible metric (probably wall time, since that's what they experience), state it once in §5 CLAUDE.md, and in §8 reframe the acceptance gate as "no `c11(.app| DEV.app)` process launches during `c11-logic test`" (the absence-of-beachball criterion) plus a secondary "test phase under 12 s" stretch goal. The "<5 s" ticket aspiration should get one line in PR description acknowledging deviation. This also makes the trade-off explicit: the cost of staying in scope is that we save 5 s of wall time, not 30 s — but the freeze goes away, which is the actual operator pain.

---

**[MINOR] §2.3 — Plan switches BUNDLE_LOADER from indirect `$(TEST_HOST)` form to absolute path without noting why**

The existing `c11Tests` target in `project.pbxproj` (lines 1705, 1716, 1724, 1734) uses:

```
BUNDLE_LOADER = "$(TEST_HOST)";
TEST_HOST = "$(BUILT_PRODUCTS_DIR)/c11 DEV.app/Contents/MacOS/c11";  // per-config
```

i.e., `BUNDLE_LOADER` is derived from `TEST_HOST`. The plan's Strategy B sets `TEST_HOST = ""` and `BUNDLE_LOADER = "$(BUILT_PRODUCTS_DIR)/c11 DEV.app/Contents/MacOS/c11"` (explicit absolute) — different shape from the existing pattern. This is *correct* (with `TEST_HOST` empty the indirect form would resolve to empty), but the divergence from the project's existing convention isn't called out. A reviewer skimming the script might flag it as "why doesn't this match c11Tests?"

**Recommendation:** Add one sentence to §2.3 noting the divergence: "Existing `c11Tests` uses `BUNDLE_LOADER = $(TEST_HOST)`; for `c11LogicTests` the indirect form would resolve to empty (since `TEST_HOST` is unset by design), so we set `BUNDLE_LOADER` to the explicit absolute path instead." Saves a reviewer the head-scratch.

### 4. Positive Observations

- **Naming locked at §0 and at the top of the plan** (`c11LogicTests`, `c11-logic`, `com.stage11.c11.logictests`) — eliminates the "what do we call this?" cycle that plan-review v1 apparently surfaced.
- **Three-tier strategy decision tree (§2.1)** with explicit fallback ordering (B → A → C) and a Strategy C escalation defined out of scope. Real risk-register thinking, not just hand-waving.
- **Spike-first protocol (§2.2)** with four representative test files chosen to exercise both easy paths *and* the actual failure mode (Theme/Workspace transitive AppKit). The selection is load-bearing — Mailbox+Stdin alone would falsely validate.
- **Mechanical acceptance criteria (§8)** — every bullet is testable by a concrete command, not a vibe check. The two-form pbxproj count check (test-file membership, not test-method count) avoids the obvious double-count trap.
- **Risk register (§6)** is genuinely a risk register, not a CYA list. Each row pairs likelihood × impact × mitigation × fallback, and the "Was-high, now mitigated" rows show iteration on plan-review feedback.
- **Per-file CI workflow audit (§4.1–4.6)** with line numbers — `ci-macos-compat.yml` and `test-e2e.yml` are explicitly verified as non-test references and "leave unchanged," not just omitted by silence. This is the level of "no surprises" a reviewer wants.
- **Re-audit demoted 6/7 PROMOTE candidates after closer reading** — the table notes explicitly call out the NSColor/AppKit symbol that the first-pass grep missed for each demotion. Demonstrates the author actually read the files instead of trusting grep.
- **Verbatim CLAUDE.md replacement (§5)** with a clear preserve/replace boundary. No interpretation friction at implementation time.
- **Commit separability (§3 workflow, §8 last bullet)** — five commits that each tell their own story, so PR review can read them independently. Spike-then-bulk is the right call.
- **Idempotency in the Ruby script** (target lookup before creation, file-membership check before move) — supports the spike-then-bulk workflow without script gymnastics.
- **Baseline-failure pinning** (`c11-27-baseline-failures.txt` from a CI run against `origin/main@7e0e0b282`) — the 47 pre-existing failures get separated from any regressions C11-27 might introduce. Standard practice, well-applied.

End of review.
