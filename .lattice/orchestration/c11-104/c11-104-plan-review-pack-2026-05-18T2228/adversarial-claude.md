# Adversarial Plan Review — c11-104-plan (Claude)

**Plan:** C11-104 (Surface worktree + branch as derived canonical metadata chips in the sidebar)
**Reviewer mode:** Adversarial (read-only)
**Model:** Claude
**Timestamp:** 2026-05-18T22:28

---

## Executive Summary

The plan is well-shaped on the surface — clear scope, sensible decisions, a real acceptance-criteria rubric — but it leans heavily on **three load-bearing assumptions that the document never seriously stress-tests**:

1. That `(cwd, mtime(.git/HEAD))` is a sufficient cache key.
2. That shelling out to `git rev-parse` 4–10 times per OSC 7 prompt is "free" because it's off-main.
3. That a `derived` tier slots cleanly between `osc` and `heuristic` in a precedence chain that today has no real `derived` notion of its own.

Each of these is plausible. None of them are proven, and several have well-known failure modes the plan elides. The acceptance criteria are written tightly enough to feel rigorous, but at least three of them (AC4, AC10, AC11, AC18) are fudge-able as written — a delegator wanting to declare victory can pass them without the underlying property actually holding.

**Single biggest concern:** the plan treats "derived" as a new tier in a precedence chain whose semantics it never re-specifies. Today's chain (`explicit > declare > osc > heuristic`) has a clean writer-identity story: each tier is a category of *human or agent intent*. `derived` is structurally different — it's c11 deriving facts from the environment. Bolting it in between `osc` and `heuristic` without re-stating the model invites subtle bugs around clears, overwrites, and "who wins" when an agent decides to write `branch` explicitly (which the plan says is permitted but never works through).

The plan is shippable. It is not bulletproof.

---

## How Plans Like This Fail

Plans of this shape — "small UI feature backed by a derived data source, with a precedence model and a cache" — fail in patterns that are very well-attested:

1. **The cache key is almost right but not quite.** Filesystem mtimes lie. `.git/HEAD` is not the only file that changes on a branch operation. Pack files, packed-refs, and ref reorgs can change branch resolution without touching `.git/HEAD` mtime (and conversely, `git gc` can rewrite `.git/HEAD` mtime without changing anything semantic). The plan picks one file's mtime and calls it done.

2. **The thing computed off-main holds locks the main thread cares about.** `git` is not pure CPU. It opens index files, touches filesystem caches, and on slow disks (network mounts, encrypted volumes, Time Machine backups in progress) can stall for seconds. The plan says "off-main" as if that's the end of the discussion. It isn't — backpressure, queue depth, and per-surface fanout all matter and aren't addressed.

3. **The "derived from cwd" pattern decays when cwd lies.** OSC 7 is shell-cooperative. A misbehaving shell, a `cd` inside a subshell, a non-shell process (vim, htop, claude itself), a TUI that doesn't emit OSC 7 — all leave cwd stale. The plan implicitly assumes cwd is fresh. It also handles "cwd doesn't exist" in tests but not the more insidious case of "cwd is stale and points at a now-different repo state."

4. **Two-source-of-truth problems on session restore.** The plan says restore re-derives from cwd. But the workspace snapshot also has `gitBranch` (per the motivation section). Now there are two answers for branch: snapshot-restored `gitBranch` (stale, possibly hours old) and freshly-derived `branch` (fresh, requires OSC 7 to fire). What renders in the gap between restore and first OSC 7? Plan doesn't say.

5. **Precedence-tier additions ripple to clear semantics.** The existing spec says "Clear semantics. `clear_metadata` with `source: explicit` always succeeds. A clear from a lower-precedence writer only succeeds if the current source is at or below the caller's." A `derived` value can be cleared by `derived`, `osc`, `declare`, `explicit`. But what *issues* the clear when the cwd leaves a git repo? The resolver itself. So now c11 internals issue `clear_metadata` calls with `source: derived` against its own surface. The plan does not specify this code path. If it's not written, the chips will stick around after `cd ~/Desktop`.

6. **Hash-collision in tiny palettes is not a hash problem, it's a UX problem.** With 8 colors and 5+ active worktrees, collision probability via birthday bound is already non-trivial (~24% at N=5). The plan flags this for "operator review on PR" but doesn't specify what the operator is supposed to do about it when two worktrees collide — re-hash? Salt? Just live with it?

7. **The settings toggle is the load-bearing escape hatch and gets tested weakest.** AC14 says "confirm wiring; bonus: unit test on the projection that respects the toggle." The bonus framing telegraphs that this won't get tested. When the toggle ships broken, nobody notices for weeks.

---

## Assumption Audit

### Load-bearing assumptions (the plan collapses without these)

| # | Assumption | Stated? | Likely to hold? |
|---|---|---|---|
| A1 | OSC 7 fires reliably on every cwd change in every shell the operator uses | Implicit | **Partial.** Bash/zsh with shell integration: yes. Fish: depends. Inside `claude` / `codex` / other TUIs that consume keystrokes without invoking shell: **no**. The plan never checks whether agents-in-panes (the *actual primary user*) emit OSC 7 at all. |
| A2 | `(cwd, mtime(.git/HEAD))` uniquely identifies a git-context | Stated | **Weak.** False negatives (cache hit on stale): possible via packed-refs change without HEAD touch. False positives (cache miss): cheap, just an extra git invocation. The cheap direction is fine; the silent-staleness direction is the real bug surface. |
| A3 | `git rev-parse` is fast enough off-main that backpressure isn't a problem | Implicit | **Mostly.** On local SSD: yes. On EXT4-backed VM disks, FUSE mounts, encrypted volumes, or repos with millions of objects (Linux kernel, chromium): no — multi-hundred-ms latencies are common. The plan never sets a budget or timeout. |
| A4 | The `derived` tier composes cleanly with the existing precedence chain | Stated | **Untested.** Plan says "ranked between `osc` and `heuristic`" but doesn't address: who issues derived-tier *clears*? Can a `derived` value be cleared by another `derived` writer (the resolver firing again with empty result)? What happens when an agent writes `explicit` `branch`, then the resolver computes a different value — the plan says explicit wins, but does the resolver still recompute and store the derived result somewhere for later? |
| A5 | Re-deriving on session restore is "good enough" — no need to persist | Stated as design choice | **Mostly.** But there's a visible window between restore and first OSC 7 where chips will be wrong or missing. Plan doesn't acknowledge or test this. |
| A6 | The operator's mental model of "worktree" maps cleanly to `git worktree add` linked worktrees | Implicit | **Mostly.** But the operator also has multiple *clones* of the same repo at different paths (manaflow-ai/cmux and Stage-11-Agentics/c11 are siblings under `code/`). These will render `worktree: nil` (main checkout each) but they are functionally parallel worktrees for the operator. Plan doesn't address. |
| A7 | A single 8–12-color palette can be picked at delegator time and is the right call | Stated | **Probably.** But this is the kind of decision that gets bikeshedded. Plan delegates it to the delegator with "flag in PR for operator review" — high probability of re-revision after merge. |

### Invisible / unstated assumptions

- **The c11 binary already has a place to put a background `DispatchQueue`** for this work. The plan doesn't survey whether there's an existing serial queue for OSC-driven work or whether one must be created (and shared across surfaces or per-surface).
- **`git` is on PATH in c11's process environment.** c11 launches from `/Applications` on most operator machines. Bundle-launched processes get a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). `/usr/bin/git` is there on stock macOS, so this likely holds — but Homebrew git is not, and the plan never specifies which `git` to invoke. If a worktree was created by Homebrew git (different version, different worktree layout assumptions), behavior could diverge.
- **The macOS sandbox / TCC does not block `git` invocations from a sandboxed c11.** If c11 is ever sandboxed (which the Stage 11 brand path may push toward for distribution), git invocations against arbitrary cwd paths require user-granted access to those paths. Plan doesn't address.
- **`MetadataValue` and `ChipModel` types exist** in the shape the test plan assumes. The plan says "delegator inspects and proposes the exact module shape" — meaning the test acceptance criteria (AC3, AC4) are written against types that *probably* exist but haven't been verified. This is fine until they don't exist, at which point the AC text becomes hand-wavy.
- **Workspace snapshot's existing `gitBranch` field stays.** The plan's "restore re-derives" story assumes c11 keeps writing `gitBranch` to snapshots for the bootstrap-before-OSC-7 window. If a future cleanup removes that field thinking it's now redundant (since chips re-derive), the restore experience regresses.
- **`.git/HEAD` exists on every code path.** Linked worktrees have a `.git` *file* (not directory) that points at the common dir. The actual HEAD-mtime to watch in a linked worktree lives at `<common-dir>/worktrees/<name>/HEAD`. The plan says "mtime-of-.git/HEAD" without specifying which one. A naive `<worktree>/.git/HEAD` stat will fail or stat the wrong file in a linked worktree.

---

## Blind Spots

### What's missing entirely

1. **Performance budget.** The plan says "off-main" but never says how slow is too slow. 50ms per resolution? 500ms? 5s? No budget = no way to detect regression. No timeout on `git` invocations = a hung git can pile up work in the background queue indefinitely.

2. **Concurrent OSC 7 storms.** If an agent does `cd a && cd b && cd c && cd d && cd a` in rapid succession (which happens in shell scripts), the OSC 7 handler fires five times. The plan's cache will help on the repeat, but five inflight resolutions can stack. Plan doesn't specify coalescing/debouncing or a "supersede earlier in-flight resolution" rule.

3. **The "many parallel worktrees" failure mode.** The motivation cites the *exact* scenario where this feature matters: many delegators, each in its own worktree. With N=10–30 panes, each in a different worktree, the first window after launch fires 10–30 OSC 7 events. The plan offers no admission control. On a slow disk, that's 10–30 × `git rev-parse` × 4–10 invocations = up to 300 fork/exec calls in the first second.

4. **What happens when `git` segfaults or hangs.** Git on a corrupted repo can hang on lock acquisition. Plan does not specify timeout, kill, or fallback.

5. **The deleted-worktree case.** The user's prompt called this out specifically. The plan's render-rules table covers "worktree pointing at a deleted *branch*" but not "worktree directory deleted while a pane is open in it." OSC 7 won't fire again (no `cd` will happen). The cache will hold stale data forever. The chips will lie. No invalidation mechanism for "worktree directory no longer exists."

6. **What happens when the operator runs `git worktree remove` or `git worktree prune` from a different pane.** Same problem as 5 — the affected pane has no signal to recompute.

7. **Submodule edge cases.**
   - Nested submodules (Stage 11 doesn't have these, but ghostty might at some point).
   - Submodule in detached HEAD pointing at a commit not on any branch (the *normal* state after `git submodule update`).
   - Submodule whose superproject is itself a linked worktree.
   - The plan's "stacked two rows" answers ergonomics, not edge-case correctness.

8. **What if `git` reports an error.** `git rev-parse --show-superproject-working-tree` exits 0 with empty output when not in a submodule. But `--show-toplevel` exits 128 with "not a git repository" when outside one. The plan's resolution sequence doesn't specify error handling for each step — what if step 1 succeeds and step 2 fails? Most likely the resolver will throw; tests don't assert what happens then.

9. **Worktree path canonicalization.** The plan says hash input is "absolute worktree path (NOT canonical-form-rewritten path)." But `git rev-parse --show-toplevel` returns the *real* path (symlinks resolved). If the operator `cd`s through a symlink, cwd is the symlinked form, but the git-reported toplevel is the real form. Color stability depends on which one the resolver feeds into the hash. AC4 says "same absolute worktree path" — but the plan doesn't define which absolute path.

10. **Multi-user / shared filesystems.** Not a c11 user pattern today, but: SSHFS / NFS worktrees, repos on network volumes. mtime granularity on network filesystems is often coarser than local (1s instead of nanoseconds). Cache invalidation can miss back-to-back branch changes.

11. **What about the operator changing branches via `git checkout` from inside the pane?** This works (it's the common case). But the operator changing branches via the *system git GUI* (Tower, Fork, source-tree app) from outside any pane: no OSC 7, no cwd change. Cache holds. Chips lie until cache TTL (30s) expires.

12. **The 30s "coarse interval" never gets specified.** The plan says "coarse interval (e.g., 30s post-checkout to catch branch renames)" once and never returns to it. Is this 30s since last OSC 7? 30s since last successful resolution? Plan doesn't say. AC12 only tests `.git/HEAD` mtime invalidation, not the coarse interval.

13. **The PR-author-as-validator antipattern.** The plan declares "Result Validator: on" but the validator audits *the same PR* that the delegator wrote. AC11 says "git diff shows no new git/IO calls inside those two methods" — a delegator that wants the test green can simply *not* edit those files. The test is verifying the PR diff, not the runtime behavior, so the test passes vacuously if the delegator chose a clever alternative path that *also* slowed those methods down for some other reason. The plan needs a runtime perf assertion, not a diff assertion, for the typing-latency claim to be real.

### Questions the plan never asks

- What does this look like when c11 itself is the repo being viewed (the operator opens a c11 pane in `code/c11`)? Bootstrap problem.
- What's the relationship between `worktree`/`branch` derived values and the `terminal_type` heuristic that *also* runs off process-tree scans? Two parallel heuristic-flavored systems — do they share infrastructure?
- Will this work for non-OSC-7-emitting workflows (vim full-time, htop, claude-code's own prompt loop while not at a shell)? In other words: *does this feature work for the agent panes it was designed for*?

---

## Challenged Decisions

### 1. "Bundle C + D in one PR."

**Counterargument:** The original recommendation was "ship C first; D as fast follow-up." Bundling adds complexity to a single PR for a feature that's load-bearing on typing latency. If C's hot-path discipline regresses, you're rolling back D too. If D's palette choice gets bike-shedded, C waits. The bundling decision is documented as the operator's call ("operator chose this over the 'ship C only' recommendation") but the architect should have pushed back harder — the *Spec recommendation* was correct and got overruled for stylistic reasons.

### 2. "Color hash input = absolute worktree path."

**Counterargument:** Worktree paths are operator-machine-specific. The operator has stable paths today, but a future workflow that uses scratch worktrees (e.g., GitHub Actions runners, ephemeral CI agents) would get unstable colors. Hashing the *branch* (or the ticket ID, if conventionally encoded in the branch name) would be more semantically meaningful. The plan rejects "branch" as the hash input for stability — but the operator's actual mental model is "this color is the C11-104 work," not "this color is /Users/atin/Projects/.../c11-worktrees/c11-104-sidebar-chips."

### 3. "Stacked two-row layout for submodules."

**Counterargument:** This is the rendering equivalent of "let's just add another row." It works for the c11 → ghostty case the operator has in mind, but the sidebar is already real-estate-constrained. Two rows per submodule pane doubles the chip footprint. The simpler answer (which the original ticket had) was "resolve to superproject context, optionally annotate `submodule: <name>`." The refined decision adds complexity that benefits the ghostty case and may regress sidebar density elsewhere.

### 4. "`derived` tier between `osc` and `heuristic`."

**Counterargument:** Why is derived data lower precedence than OSC sequences? OSC is the *transport*, not the source of truth. If an agent sends OSC 7 with a stale cwd, and derived has the fresh git context (because it ran `git rev-parse` directly), why does OSC win? The plan picks this ordering without rationale. An alternative: `derived` ranks *above* `osc` because it's a c11-internal computation against the actual filesystem state, whereas OSC is a hint from the shell.

### 5. "Tests live in `c11LogicTests`."

**Agreement, but:** The acceptance criteria mix logic tests (resolver correctness, projection correctness) with UI behavior assertions (toggle gates rendering, chips appear in sidebar). The latter category does not belong in `c11LogicTests` — it belongs in `c11Tests` (host-required) or in a manual smoke pass. The plan handles this by punting AC18–AC20 to "post-merge-smoke," but AC14 ("toggle gates rendering") is `pre-merge-static` and labeled as testable in `c11LogicTests` — which only works if the rendering layer is split cleanly enough to test the projection function in isolation. The plan doesn't audit whether that split exists.

### 6. "Result Validator on, Master Validator off."

**Counterargument:** The Master Validator audits *global* state — multiple in-flight tickets, build health across worktrees, PR queue. A typing-latency-sensitive feature is exactly the kind of work where a global audit ("does CI catch the regression on neighboring PRs?") is high-value. Turning Master off and Result on inverts the value: you get a fresh-eyes audit of one PR but no continuous check on whether other in-flight work is being affected.

### 7. "Architect promotes to Orchestrator in same pane."

**Counterargument:** Saves a pane, but the planning-state context (4 rounds of `AskUserQuestion`) sits in the same window as the orchestration-state context (delegator status, lattice events). When the operator looks back in a week to understand "why was the color hint bundled in?" they have to scroll past delegator status updates. The standing pattern (separate panes) preserves the audit trail in shape. This is a minor preference, not a hard error, but it's a "default" decision that wasn't justified.

---

## Hindsight Preview

Two years from now, looking back at this work:

1. **"We should have set a perf budget."** The plan ships, works fine on Atin's m4 Max with a local SSD, and silently degrades on a future operator's slower or networked-disk setup. Without a budget, the regression has no detectable signal until someone complains about typing lag — and by then the resolver is doing 10x more work than it should.

2. **"Why didn't we just use file-system events?"** The plan polls / re-derives on OSC 7 and on a coarse 30s interval. macOS has `FSEvents` for watching directory mtime changes — including `.git/HEAD`. A subscribe-based model would be more correct (catches external `git checkout` from other tools) and arguably cheaper (no polling). The plan never considered this.

3. **"The chips for non-shell agents never worked."** OSC 7 is shell-mediated. Inside Claude Code or Codex or kimi, OSC 7 doesn't fire unless the agent explicitly sends it. The whole feature works *worst* in the surfaces the operator most cares about — delegator panes running agents — and best in shell panes. This was the inverse of intent.

4. **"We invented a tier instead of using the one we had."** `heuristic` already means "c11 internal best-effort detection." The plan adds `derived` as a structurally similar idea. In hindsight, `worktree` and `branch` could have just been `heuristic`-sourced canonical keys with a clearer doc comment. Adding a tier is permanent — removing it later is breaking.

5. **"The settings toggle was never tested and shipped broken in v1.1."** Because AC14's test was "bonus."

6. **"The colored dot got confused with status pills."** The sidebar already renders colored pills for `status`. Adding a small colored dot next to a worktree chip risks visual conflation with status signal. The plan delegates palette choice without specifying it must visually differentiate from the existing status pill palette.

### Early warning signs the plan should watch for

- After merge, look at the c11 process's main-thread Hangs window in Instruments while the operator opens 10+ panes in a worktree-heavy session. Any hitch correlates with this feature.
- Log resolver wall-clock time per invocation. If p99 > 200ms, the plan's "off-main is enough" assumption is failing.
- Track how often the cache is hit vs missed. If the hit rate is < 80%, something about the invalidation logic is wrong.
- Count git invocations per pane per minute. If it's > 4/min in steady state (no `cd`s happening), the coarse interval is firing too aggressively.

None of these instruments exist in the plan. Acceptance is binary (test green / test red).

---

## Reality Stress Test

Three plausible disruptions hitting simultaneously:

### Disruption 1: Operator opens c11 on a slower machine (Atlas — m2 Ultra is fast, but suppose this lands on an older Mac or in a Linux VM via Asahi)

Resolver wall-clock doubles or triples. The 4–10 git invocations per OSC 7 now take 300–800ms instead of 50–100ms. Off-main keeps typing alive, but the chips lag visibly — chips show stale branch/worktree for 1+ seconds after `cd`. Operator perceives "the chips don't work" rather than "the chips are slow." Trust in the feature degrades.

### Disruption 2: Multiple delegators spawn near-simultaneously (the exact motivating scenario)

Five worktrees, five new panes, five OSC 7 fires within ~200ms. Background queue depth = 5 × 10 git invocations = 50 fork/exec calls competing for filesystem cache. On a cold cache, this is multi-second resolution latency for all five panes. All five show stale or missing chips during the period the operator was *most likely to be using the chips to disambiguate which pane is which*. The feature fails when it matters most.

### Disruption 3: Operator runs `git worktree prune` while a pane is open in a now-removed worktree

OSC 7 doesn't fire (no cd happened). Cache `(cwd, mtime(.git/HEAD))` — but `.git/HEAD` *is gone*. `stat` returns ENOENT. Cache key is undefined. Behavior depends on the resolver's stat-handling code, which the plan never specifies. Most likely: cache miss → re-run git → git fails → chips disappear or show error state → no further updates ever. Operator's pane shows no chips for the rest of the session.

### Combined effect

The three disruptions together describe an entirely realistic morning: operator on travel laptop, spawning multiple delegators, pruning old worktrees periodically. In that morning, the feature is approximately useless. The plan does not anticipate any of this.

---

## The Uncomfortable Truths

1. **The acceptance criteria are too tight in shape and too loose in semantics.** They look rigorous (20 numbered criteria with verification methods) but several can be passed without the underlying property holding. AC10 ("resolver runs off-main") = grep for `DispatchQueue.global`. A delegator could put one `DispatchQueue.global` call wrapping a sync `Process` that does the wrong thing and AC10 passes. AC11 (no new git work in two specific files) passes trivially if the delegator does the work in *adjacent* files. AC18–AC20 are subjective ("no perceptible new lag") — Atin will eyeball it and either accept or reject. The plan's rigor is largely theater.

2. **This feature is solving the wrong problem.** The motivation is "operator can't see which worktree a pane is in." But the operator already names tabs (`c11 rename-tab` is mandatory on agent startup per CLAUDE.md). The actual fix is *better tab-naming conventions* — agents could include worktree-derived info in their own self-declared title. The plan adds derived data on top of a tab-naming system that's already supposed to carry this signal. It's a workaround for agents not following the existing convention.

3. **The plan is a one-person plan.** It's optimized for the way Atin works, on Atin's machine, with Atin's specific multi-worktree workflow. The decisions ("colored dot," "stacked submodule," "dim main") are Atin's preferences. None of them are wrong, but the plan reads as personal toolmaking, not product engineering. That's fine — c11 is partly Atin's toolset — but the plan never owns this. It reads as if the design were derived from principles when it was actually derived from one operator's PR-day-style.

4. **The "Verbose ticket fidelity" decision means the SPEC has grown bigger than the implementation.** The refined-spec section already contradicts the original "Out of scope" section, and the plan handles this by saying "the refined section wins." This is fine for one round of revision. It's not fine if there's another round. The plan has no answer for "what happens when the operator changes their mind again mid-implementation."

5. **The delegator is "Fully Autonomous" but the plan has 17 pre-merge ACs and 3 post-merge smoke ACs, plus a Result Validator pass.** That's not autonomous; that's heavily gated. The autonomy framing is aspirational, not real.

6. **No one is going to do the post-merge smoke pass with the rigor the plan implies.** AC18–AC20 require opening c11 in "several states" and visually comparing. Atin will spot-check the worktree-vs-main case (10 seconds) and call it done. The submodule case will be tested if and when the operator happens to `cd` into ghostty — which may be never in the post-merge window.

---

## Hard Questions for the Plan Author

1. **Which `.git/HEAD` mtime are you watching in a linked worktree?** The worktree's `.git` file points elsewhere. The plan says "mtime-of-.git/HEAD" without qualifying which one. **Currently "we don't know" — and the resolver will silently watch the wrong file.**

2. **What's the performance budget for resolution?** Wall-clock ceiling per `git rev-parse` invocation? Total budget per OSC 7 event? Maximum queue depth before dropping or coalescing? **"We don't know" is the current answer.**

3. **What is the resolver's behavior when git times out, hangs, or returns an error?** Specifically: which git error codes are "no chips," which are "fall back to stale cache," and which are "log and retry"? **Plan does not specify.**

4. **How does the resolver detect that a worktree directory was deleted while a pane was open in it?** OSC 7 won't fire. The cache key (cwd, mtime(.git/HEAD)) is undefined when .git/HEAD doesn't exist. **No mechanism specified.**

5. **What renders during the window between session restore and first OSC 7?** The snapshot has `gitBranch` and `currentDirectory`. The chips presumably re-derive from `currentDirectory`. Is the re-derive synchronous on restore (blocks UI) or asynchronous (chips appear N seconds after restore)? **Not specified.**

6. **Who issues `clear_metadata` calls with `source: derived` when the resolver determines "no longer in git"?** Is there a code path that does this, and how does it compose with the clear-semantics rules? **Not specified.**

7. **Does this feature work in panes running TUI agents (claude, codex) that don't emit OSC 7?** This is the *primary use case* per the motivation section. **The plan doesn't check or guarantee this.**

8. **What happens when the operator has two clones of the same repo at different paths (e.g., manaflow-ai/cmux and Stage-11-Agentics/c11 are both clones of cmux ancestry)?** Both show `worktree: nil` because each is a main checkout. Are they distinguishable? **Not addressed.**

9. **What's the expected hash collision rate at N=5, N=10, N=30 active worktrees with an 8-color palette?** The plan delegates palette choice to the delegator and says "operator review on PR." **What's the operator supposed to do if two worktrees collide?**

10. **Why is `derived` ranked below `osc` instead of above? What's the rationale?** The plan asserts the ordering without argument. **"We don't know why" is the current answer.**

11. **AC11 verifies the diff doesn't touch two specific files. What stops the delegator from putting the new git work in `Sources/Sidebar/SomeNewFile.swift` such that AC11 passes vacuously while still affecting typing latency?** **Nothing stops this. The AC is fudge-able.**

12. **AC10 says "any code that calls `git ...` lives inside a `DispatchQueue.global` / `Task.detached` / equivalent off-main scope." What's the actual runtime assertion? A grep is not a runtime test.** **AC is grep-shaped, not runtime-shaped.**

13. **Is there a budget for sidebar real estate?** Two new chips per pane, possibly two rows for submodules. With 10+ panes in the sidebar, this adds substantial vertical density. **Not addressed.**

14. **What's the rollback story?** The settings toggle hides chips. But the resolver still runs and still consumes resources. Is there a flag that disables the resolver entirely (in case it's causing perf issues), or does the operator have to ship a follow-up PR? **Not specified.**

15. **How does the colored-dot palette interact with the `status` colored-pill palette?** Both are sidebar visual signal. Are they visually distinct enough not to be confused? **Not specified — delegator picks during plan with "flag in PR for operator review."**

16. **Does the resolver share state across surfaces?** I.e., if 10 panes are in the same worktree, does the resolver run once or 10 times? Cache key is `(cwd, mtime(.git/HEAD))` — if all 10 panes have the same cwd, they should share. But the OSC 7 event fires per-pane. Is there a singleton resolver or per-surface resolver? **Not specified.**

17. **What about FSEvents-based invalidation as an alternative to mtime-polling?** This is the macOS-native mechanism for "watch a file for changes." **Plan never considered it.**

18. **The plan says "Submodule kind for chip text other than `submodule:` prefix" is out of scope. But what about superprojects whose name *should* appear?** Operator cwd-ing into `code/c11/ghostty/` should arguably show `c11 / ghostty` not `worktree: c11 + submodule: ghostty`. **Naming convention is hand-waved.**

19. **What's the test strategy for the `30s coarse interval` rule?** AC12 only tests `.git/HEAD` mtime change. The coarse interval (for catching branch renames where mtime doesn't change?) is mentioned and never verified. **AC12 is incomplete.**

20. **Why does the plan delegate so much shape-decision to the delegator?** "Delegator inspects and proposes the exact module shape in plan phase," "delegator picks the palette during plan," "delegator's call, with operator review on PR." If the architect has already made the high-level decisions, why not pin down the file structure and palette during planning so the delegator just implements? **Operator-time is being spent in PR review where it could have been spent in planning.**

---

## Closing Note

The plan is competent. It would pass a normal review. As an adversary: I would not ship it without nailing down at least questions 1, 2, 4, 5, 6, 7, 11, and 12. Everything else is acceptable risk; those eight are *correctness or perf gaps* that the plan currently waves at without resolving.

The biggest single move to make the plan better is to **add a runtime perf assertion** (typing latency in a worktree pane vs main pane, measured with an actual harness, not "operator eyeballs it") and **specify error/timeout behavior for `git`** invocations. Those two changes turn the plan from "looks rigorous" to "actually rigorous."
