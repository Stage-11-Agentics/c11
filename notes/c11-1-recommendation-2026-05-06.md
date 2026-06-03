# C11-1 Recommendation — 2026-05-06

Research-only note. No code changes, no Lattice writes, no PRs.

Ticket: `task_01KPP7QBZ3NJMXS4C9NA2XW01X` — *c11mux → c11 rebrand pass (fork-level, upstream-compatible)*. Status: **needs_human** since 2026-05-04T00:06:41Z. Auditor (`agent:claude-opus-4-7-c11-1-audit`) parked it with two operator-judgment items.

---

## 1. Current state

### What has shipped to `main`

- **PR #36** (2026-04-20, commit `56ec6d5d3`) — original rebrand pass. The bulk landed cleanly per the heuristic "user sees it → rename; compiler/daemon sees it → don't."
- **PR #111** (merged 2026-05-04, squash commit `cd4bd7f1b`, source `f32f3d6b0` on `c11-1-completion-audit`) — six audit-flagged stragglers absorbed:
  - `skills/c11/references/metadata.md` — dead link to deleted module-2-metadata spec dropped.
  - `Sources/c11App.swift` — About-panel `defaultValue: "c11mux"` → `"c11"`.
  - `Sources/{TitleFormatting,ContentView,AgentChip,SurfaceMetadataStore}.swift` — comment refs to deleted module specs dropped.
  - `scripts/generate_{dark,nightly}_icon.py` — `os.execv` delegation repointed from non-existent `generate_c11mux_icon.py` to `generate_c11_icon.py`.
  - `docs/c11-charter.md` — homebrew-tap and bundle-ID guesses updated to what shipped.
  - PR body explicitly deferred `docs/upstream-sync.md` ("load-bearing enough to want a separate think-through and follow-up ticket").

### What is staged but not landed

- **`c11-1-completion-audit` worktree** at `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-completion-audit`:
  - Branch is 1 ahead of `main` (the `f32f3d6b0` commit, now also present as squash `cd4bd7f1b`). Effectively merged.
  - Working tree has: modified Lattice metadata (`.lattice/events|tasks|plans/task_01KPP7QBZ3NJMXS4C9NA2XW01X.*`) and an untracked artifact `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-completion-audit/.lattice/artifacts/payload/art_01KQR7R4P4KZC0T11HG1F1ZS2N.md`. The artifact is a 1-paragraph audit summary; not load-bearing — its substance is already in the ticket comment trail.
  - **Verdict:** safe to retire. Branch's purpose was already served by PR #111.

- **`c11-1-rebrand-cleanup` worktree** at `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-rebrand-cleanup`:
  - Branch is **11 commits ahead** of `main`, 32 behind. **No PR exists** (`gh pr list --head c11-1-rebrand-cleanup` returns empty).
  - Working tree has modified Lattice metadata + an untracked plan note `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-rebrand-cleanup/.lattice/notes/task_01KPP7QBZ3NJMXS4C9NA2XW01X.md`. The plan note is a careful, well-organized inventory of every `c11mux` hit categorized as whitelist vs real residue, with a "do not ship" contract for the validate phase. **Load-bearing — read it before deciding what to do with the branch.**
  - The 11 commits (oldest → newest):
    | SHA | Subject | Overlap with PR #111 |
    |-----|---------|----------------------|
    | `4f07efee4` | docs: rebrand prose c11mux to c11 in active plans | partial (`docs/c11-charter.md`) |
    | `44d399722` | Sources: drop dead spec refs and fix About-panel fallback | **full overlap** |
    | `8776144e2` | CLI/Resources/skills: drop dead spec refs | partial (`skills/c11/references/metadata.md`) |
    | `767e5fc44` | l10n: rebrand `New c11mux Workspace/Window Here` keys | none |
    | `8567144e2` | l10n: add uk translations for the 2 keys above | none |
    | `753b6538f` | tests: align fixtures with current `com.stage11.c11` bundle IDs | none |
    | `7337f466a` | tests: rebrand c11mux to c11 in test prose comments | none |
    | `bdfa7e5b1` | scripts: repoint broken icon delegations + rebrand header script | partial (`generate_dark_icon.py`, `generate_nightly_icon.py`) |
    | `d1d3bfb3c` | CLAUDE.md: drop dead installer-spec path reference | none |
    | `5fd50c185` | design: rename `c11mux-*` asset files (`git mv`) | none |
    | `71312ce22` | fixup: drop c11mux residue missed by plan enumeration | none |
  - **Verdict:** ~5 commits overlap PR #111 (already shipped); ~6 commits are unique, real, and not yet on main. The unique work is non-trivial and includes at least one **active correctness item** (test bundle-ID fixtures).

### Audit findings (recap from ticket comment trail)

The auditor (run on `origin/main` HEAD `3a3908110`, 2026-05-03) reported:

| AC | Result | Detail |
|----|--------|--------|
| 1. `rg -i c11mux` | PASS w/ 6 cosmetic stragglers | All addressed by PR #111. Today on `main`: 122 files still match, ~all in whitelist categories. |
| 2. `cmux` binary + skill auto-load | PASS w/ note | `cmux` shim refuses until a tag is `reload.sh`-selected (per `notes/c11-cli-coexistence-plan.md`); behavior change but intentional. |
| 3. Dry-run upstream merge zero conflicts | LITERAL FAIL / SPIRITUAL PASS | 968 upstream + 183 c11 commits since 2026-04-20; conflicts are organic feature divergence, not rebrand-caused. |
| 4. `./scripts/reload.sh --tag c11-rebrand` smoke | PASS (after worktree submodule init) | Build green, app launches, socket up. |

Auditor's own recommendation in the parking comment: **(1b) + (2) accept-as-is** — file a small follow-up and complete C11-1.

### Where the `needs_human` parking originated

Only two questions were thrown over the wall:

1. What to do with the 6 minor stragglers (absorb? follow-up ticket? accept drift?). PR #111 already absorbed them, but the auditor was unaware of the parallel `c11-1-rebrand-cleanup` branch.
2. How to interpret AC #3 given organic divergence.

Neither question has been answered in the ticket trail since.

---

## 2. Open decisions

Numbered for scan. The rebrand-cleanup branch's plan note already settles many of these — it pre-categorized every `c11mux` hit and recommends fixes — so several "decisions" are really "ratify the plan note + rebase the branch."

1. **Disposition of the `c11-1-rebrand-cleanup` branch.** It exists, has ~6 unique commits, no PR. Either land it (with a rebase to drop the 5 commits PR #111 already shipped) or retire it. Judgment call because the branch is unattributed in the Lattice trail — the auditor's needs_human comment doesn't reference it, and there's no record of why it stalled.

2. **Test bundle-ID fixtures (commit `753b6538f` on rebrand-cleanup).** Hardcoded `com.stage11.c11mux*` in `c11Tests/GhosttyConfigTests.swift` (27 sites), `c11UITests/AutomationSocketUITests.swift`, `c11UITests/BrowserOmnibarSuggestionsUITests.swift`, `tests/cmux.py`, `tests/test_open_wrapper.py`, `tests_v2/test_m5_*.py`, `tests_v2/test_ctrl_enter_keybind.py`. Runtime is `com.stage11.c11*`. **These are active failures, not cosmetics** — M5 tests skip silently against fresh tagged builds; UI tests can't find the app. Decision: scope-of-C11-1 or separate ticket. Judgment because the original ticket scope said "do not rename Xcode targets/schemes" and reasonable readers could put bundle-ID-bound test fixtures on either side of that line.

3. **`Resources/InfoPlist.xcstrings` keys + uk translation (commits `767e5fc44` + `8567144e2`).** The xcstrings JSON keys still say `"New c11mux Workspace Here"` / `"New c11mux Window Here"` while the values are already `"New c11 …"`. macOS NSServices will lookup-miss on the keys, so localized translations don't apply — non-English users see the raw English fallback. Five locales (ja/ko/zh-Hans/zh-Hant/ru) already have c11 translations attached to the wrong key; uk is absent entirely. Judgment because it's user-visible localization correctness vs. operator's preference for separate ticket scoping.

4. **`docs/upstream-sync.md` rewrite (in commit `4f07efee4`).** Explicitly deferred by PR #111 ("load-bearing enough to want a separate think-through"). The current version on `main` prescribes keeping `com.stage11.c11mux` bundle IDs and `Sources/cmuxApp.swift` filename — both untrue post-rebrand. The rebrand-cleanup version rewrites it to reflect shipped reality plus an explicit whitelist of intentional `c11mux` references. Judgment because the doc is a future-agent contract for upstream merges; the rewrite needs operator eyes, not just an audit pass.

5. **Design asset renames (commit `5fd50c185`).** `design/c11mux.icns` → `c11.icns`, `design/c11mux-spike.svg` → `c11-spike.svg`, `design/c11mux-lattice-icon-source.png` → `c11-lattice-icon-source.png`, with `scripts/generate_c11_icon.py` updated in lockstep. Bytes preserved (`git mv`). Judgment because brand asset filenames are a low-risk rename but affect anyone with a bookmark/script outside the repo.

6. **`scripts/generate_c11_header.py` rebrand (in `bdfa7e5b1`).** Currently renders the literal text "c11mux" and writes `docs/assets/c11mux-header.png`; nothing references the output. Rebrand-cleanup renames to `c11-header.png` + renders "c11". Judgment is whether to keep the script (rename) or delete it (script appears orphaned).

7. **AC #3 closure stance.** The auditor flagged literal-fail/spirit-pass. Operator can either close C11-1 by accepting the spiritual reading, or rerun the dry-run merge against `upstream/main@2026-04-20` (rebrand merge point) to isolate rebrand-only conflicts. Judgment because the cost of a focused re-check is real (worktree gymnastics) and the value depends on whether AC #3 is meant as a sanity check or a load-bearing release gate.

8. **Stragglers that survive even after rebrand-cleanup lands.** A handful of `c11mux` hits are intentional whitelist (CamelCase `C11muxTheme`, integration-installer marker `c11mux-v1`, `~/Library/Application Support/c11mux/` runtime path, `skills/MANIFEST.json` schema key, frozen review packs under `docs/c11mux-*-review-pack-*/`, compat sweep globs in `scripts/`). The rebrand-cleanup plan note enumerates these as the "do not ship" contract. Judgment is whether to formalize that whitelist in `docs/upstream-sync.md` (which the rebrand-cleanup branch already does) or treat it as agent-runbook-only.

---

## 3. Recommended resolution

Opinionated. Push back where it doesn't fit.

**1 — Land the `c11-1-rebrand-cleanup` branch (as one rebased PR).** The auditor's recommendation to "file a follow-up ticket" was reasonable in the absence of staged work, but the staged work already exists and is well-organized. Ratifying it costs less than re-deriving it via a new ticket. The rebrand-cleanup plan note (`/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-rebrand-cleanup/.lattice/notes/task_01KPP7QBZ3NJMXS4C9NA2XW01X.md`) is a load-bearing artifact — it draws the whitelist boundary cleanly per the cmux→c11 naming memory's "lineage talk vs residual" rule. Treat that note as the contract going forward.

**2 — Bundle-ID test fixtures: ship in this PR.** Per the cmux→c11 naming memory, residual `cmux`/`c11mux` strings are wrong. Test fixtures hardcoded to `com.stage11.c11mux*` aren't lineage talk — they're live runtime contract checks against a bundle ID that no longer exists. Calling that out-of-scope and filing a separate ticket adds delay for no benefit; the test suite is currently in a degraded state. Land it.

**3 — InfoPlist.xcstrings keys + uk translation: ship in this PR.** Same reasoning as #2 — this is user-visible localization correctness, not cosmetic. The fact that ja/ko/zh-Hans/zh-Hant/ru already have c11 translations attached to the wrong key proves an earlier translator pass already did the work; the keys were just never renamed. Backfilling uk is one xcstrings entry. The cmux→c11 memory's residual rule applies directly: these keys leak the upstream brand into runtime localization lookups.

**4 — `docs/upstream-sync.md` rewrite: ship in this PR.** PR #111 deferred it for "separate think-through." The rebrand-cleanup branch's rewrite is the think-through — it explicitly reflects shipped bundle ID + repo slug and codifies the intentional-cmux whitelist (CamelCase type, marker ID, Application Support path, manifest schema key, runtime fallback constants). This is exactly the kind of "future-agent contract" doc that's load-bearing precisely because every upstream merge will read it. Read it once, ratify, ship; don't drag it into yet another ticket.

**5 — Design asset renames: ship.** Low blast radius. Bytes preserved. No callers outside the lockstep `generate_c11_icon.py` update. The cmux→c11 memory's "lineage talk only in lineage docs" rule means filename `c11mux.icns` in `design/` is residual, not lineage.

**6 — `generate_c11_header.py`: keep + rename.** Per the rebrand-cleanup commit message, no caller references the output. But the script is small, working, and in the `scripts/` brand-assets family alongside `generate_c11_icon.py`. Renaming preserves it for whoever might later regenerate the wordmark; deleting trades zero immediate value for some option-loss. Default to keep.

**7 — AC #3: accept the spiritual pass.** The auditor's literal-fail diagnosis is structurally correct: 1.1k commits of organic divergence will produce conflicts no matter how clean the rebrand was. The spiritual reading — "no rebrand-attributable conflicts in `Sources/`, `daemon/`, `Xcode project`" — is what the AC was actually probing for. Operator can sanity-check by spot-grepping a handful of conflict regions in the auditor's sample (`Sources/c11App.swift` `WorkspaceTitlebarSettings`/`TabBarChromeState`) and confirming none are brand-driven. If that sanity-check holds, close as-is. Re-running the dry-run merge against the `2026-04-20` rebrand point isn't worth the worktree gymnastics; the result will just be "no rebrand conflicts" and we already have qualitative evidence of that from the conflict-region inspection.

**8 — Whitelist formalization: handled by #4.** The rebrand-cleanup `docs/upstream-sync.md` rewrite includes the whitelist. Once that lands, the cmux→c11 memory and the doc agree, and future agents have a single source of truth for what `c11mux` strings are intentional.

**Retire the `c11-1-completion-audit` worktree.** Its sole commit shipped as PR #111. The untracked `.lattice/artifacts/payload/art_01KQR7R4P4KZC0T11HG1F1ZS2N.md` summary is a 1-paragraph echo of the ticket comment; not load-bearing. Worktree dirty state is harmless Lattice metadata that will get regenerated.

---

## 4. Suggested next steps

Ordered. Operator can interrupt at any step.

1. **Read the rebrand-cleanup plan note first.** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-rebrand-cleanup/.lattice/notes/task_01KPP7QBZ3NJMXS4C9NA2XW01X.md`. ~5 minutes. If you disagree with its whitelist contract, everything below changes.

2. **Pick the base.** Use `c11-1-rebrand-cleanup` as the base. The 5 overlapping commits (`44d399722`, partial `4f07efee4`, partial `8776144e2`, `bdfa7e5b1` partial) will become empty cherry-picks during the rebase onto current `main` since their content already shipped via PR #111 — git will skip them cleanly; verify with `git log --oneline` before pushing.

3. **Rebase onto `origin/main`.** From inside the worktree:
   ```bash
   cd /Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-rebrand-cleanup
   git fetch origin
   git rebase origin/main
   ```
   Expected: 5 commits become empty (drop them), 6 remain. Resolve any incidental merge conflicts in `docs/upstream-sync.md` (which has had no main-side edits since PR #111 declined to touch it, so should rebase cleanly).

4. **Commit boundaries: one PR.** The 6 unique commits each have a clear, focused message and stand alone:
   - `767e5fc44` xcstrings key rename
   - `8567144e2` uk translation backfill
   - `753b6538f` test bundle-ID fixtures
   - `7337f466a` test prose comments
   - `4f07efee4` docs (incl. upstream-sync rewrite)
   - `5fd50c185` design asset renames
   - `d1d3bfb3c` CLAUDE.md installer-spec ref
   - `71312ce22` shell-integration + design/c11-spike.svg comment polish
   - leftover unique parts of `8776144e2`, `bdfa7e5b1` after overlap-drop
   Keep them as separate commits in the PR for review readability; squash-merge as usual.

5. **Validation before merging.** Per CLAUDE.md "no local tests" policy, validation goes via CI:
   - Push branch; CI builds for scheme `c11`.
   - `./scripts/reload.sh --tag c11-1-cleanup` locally; verify the app launches, About panel shows "c11", and `New c11 Workspace Here` appears in the Services menu under macOS System Settings → Keyboard → Shortcuts → Services. (User-visible localization sanity check; doesn't require running tests locally.)
   - `cd /Users/atin/Projects/Stage11/code/c11 && rg -il c11mux | wc -l` — number should drop from 122 to roughly 122 minus ~30 (real residue files); the remainder is the documented whitelist. Spot-check a few of the survivors map to the "do NOT ship" list in the plan note.
   - `gh workflow run test-e2e.yml` once if you want the M5 bundle tests (`test_m5_built_bundle.py`, `test_m5_channel_identity.py`) to actually exercise the new bundle-ID assertions against a fresh tagged build.

6. **Lattice writeback (after merge).** Comment on the ticket: "rebrand-cleanup PR landed (link); closes the rebrand-cleanup branch's items 1–8 from `notes/c11-1-recommendation-2026-05-06.md`." Transition `needs_human` → `done`. Retire both worktrees with `git worktree remove`.

7. **Surviving needs_human items: zero.** If recommendations 1–7 above are accepted, every operator-judgment item collapses. AC #3's spiritual-pass acceptance closes the last open question. C11-1 lands as a complete ticket.

---

## Files referenced

Absolute paths for fast navigation:

- `/Users/atin/Projects/Stage11/code/c11/notes/c11-audit-2026-04-21.md` — original audit, source of truth for §7 (brand naming drift).
- `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-rebrand-cleanup/.lattice/notes/task_01KPP7QBZ3NJMXS4C9NA2XW01X.md` — load-bearing plan note. Read first.
- `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-completion-audit/.lattice/artifacts/payload/art_01KQR7R4P4KZC0T11HG1F1ZS2N.md` — auditor summary (1 paragraph). Not load-bearing.
- `/Users/atin/.claude/projects/-Users-atin-Projects-Stage11-code-c11/memory/feedback_cmux_to_c11_naming.md` — naming memory cited throughout §3.
- Lattice ticket: `task_01KPP7QBZ3NJMXS4C9NA2XW01X` (`C11-1`).
- PR #111 squash on main: `cd4bd7f1b`. Source on `c11-1-completion-audit`: `f32f3d6b0`.
- Original rebrand on main: `56ec6d5d3` (PR #36, 2026-04-20).
