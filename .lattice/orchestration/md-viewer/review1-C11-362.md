# Review 1: C11-362 (N1 in-panel navigation), PR #626

- **Verdict: FAIL.** Three blocking findings, all small to fix.
- **Reviewer:** `agent:claude-md-review-362` (Claude Opus).
- **Mode:** read-only; nothing tracked was edited or pushed.
- **Head:** `6148809111479eb652470591e172d5321f0fa5eb` (asserted). Base `22786494a8`.
- **Inputs read:** the full diff, owner brief, plan, and validation comment `ev_01M4EMXTQ291Q0DXDARAME209Y`.

## Invariants checked

| # | Invariant | Result |
|---|---|---|
| a | Navigation and each command do what the ticket says, against the right panel, and reject bad input loudly | **Broken**: B1, B2, B3 |
| b | Threading and focus policy | Holds. Verified at runtime: a socket navigate into a background panel kept the focused panel and the selected workspace. All three methods are on socket workers. The guard is untested (N1). |
| c | `visible --watch` stays bounded | Untouched by this PR. Navigation publishes through the existing render-state path and adds no subscription. |
| d | Evicted or never-shown panels | Holds. `navigate` and `history` answer from the model with no renderer created. The pending fragment lands when the reader is recreated. Back restores position while evicted. `links` recreates a hidden reader without a focus change. All verified at runtime. |
| e | Skill matches the shipped CLI | Mostly. Commands, flags and usage match. Outcome vocabulary is inexact (N5). |
| f | Link reach no wider than `c11 markdown open` | Holds. Document links are scoped to the repo, or to the document's directory when there is no repo. Two layers enforce this: the realpath prefix check, plus the pinned-root `openat`/`O_NOFOLLOW` read. Agent-CLI navigation is exactly as wide as `markdown open`. History replays each entry's recorded scope. A hardening note is at N7. |

## Blocking

### B1. Regression from main: a filename containing `#` no longer opens

- **Where:** `CLI/c11.swift:5570` and `:5628` (`splitMarkdownTarget`).
- **Problem:** every `markdown open <path>` now splits at the first `#`, even without `--panel`.
- **Demonstrated** with the head CLI against a fake socket (script `scratchpad/probe/cli_hash_probe.py`). Both `c11 markdown open …/C#notes.md` and the `c11 markdown …/C#notes.md` shorthand, on an existing file, sent `markdown.open path=…/C fragment=notes.md`. The real app answers `not_found`. On main the whole path is sent.
- **Fix:** split only when the whole string is not an existing file. Splitting at the last `#` is an alternative.
- **Test gap:** add a CLI case for a `#` filename.

### B2. Anchors in new-panel mode, and ⌘-click on anchors, corrupt history and duplicate the panel

- **Where:** `Resources/markdown-viewer/viewer.js:995-996` and `Sources/Panels/MarkdownWebRenderer.swift:671-681`.
- **Problem:** for any resolvable `#anchor`, the page posts the link and then always scrolls itself, whatever the modifiers. When native picks "new panel" (⌘ held, or the toolbar default set to New panel), it opens a second panel on the same file. It never pushes a history entry for the source panel.
- **Scenario:** turn the toolbar toggle to New panel and click any table-of-contents link. The source panel jumps and a duplicate panel opens. ⌘[ in the source panel cannot return to where the operator was reading.
- **Same path:** the broken-anchor suggestion buttons post `meta:false` links, so they hit the same bug in New panel mode.
- **Acceptance points broken:** "position is restored on back/forward" and "anchors participate in history."
- **Fix (either):**
  - Same-document anchors always stay in-panel.
  - Or the page skips its local scroll when native will open a new panel. The new-panel decision then has to reach the page, because it currently scrolls before native decides.

### B3. ⌘-click does not invert the default

- **Where:** `Sources/Panels/MarkdownWebRenderer.swift:671-672`.
- **Problem:** `opensNewPanel = meta || defaultIsNewPanel`. With the toggle on New panel, plain click and ⌘-click both open a new panel, so a link can no longer be followed in place.
- **Contract:** the reference prototype labels this control "where a followed link opens (⌘-click does the other)". The ticket says the toggle sets which destination is the default.
- **Fix:** `opensNewPanel = meta != defaultIsNewPanel`. Update the skill sentence "Cmd-click also opens a new panel" to match.

## Guard break-it results (Atlas, scratch worktrees)

The owner's greens reproduce at exact head:
- logic invocation `ed674eb7a684486da9769ced29ac1cfc`: `CapabilityFeaturesTests` 4/4, `MarkdownAssetPolicyTests` 10/10, `MarkdownNavigationHistoryTests` 2/2;
- unit invocation `7bf72a1aafc14b9fae0e15a80f422688`: `MarkdownWebRendererTests` 18/18, including the new navigation test;
- `tests/test_cli_markdown_agent.py` passes against the head CLI from tagged build `fec4609e62d6451b86cff50a9a7a51ff`.

The owner claimed no reds.

I added two probes in scratch only:
- `testReviewProbeSocketNavigateHiddenPanelKeepsFocusAndAppliesFragment` drives the real socket dispatch for `markdown.navigate`, `markdown.history` and `markdown.links`.
- `testReviewProbeBackRestoresPositionLiveAndAfterEviction` checks that Back restores position, both live and after eviction.

Both pass on unmodified code (`8fdc24974ed9452dafc621df6bac55d8`).

| Break | What was removed | Owner tests | Review probes |
|---|---|---|---|
| B1 | Repo-scope prefix check in `MarkdownNavigationPolicy.prepare` | **Red** (`…ConfinesAutomaticLinks…`, `testPanelNavigation…` line 130: `notReadable` ≠ `outsideScope`). The pinned-root `openat` read still refused the file, so a second layer holds. | n/a |
| B2 | `markdown.navigate` from the off-main method list | **Red** (`CapabilityFeaturesTests`: `mainActor` ≠ `socketWorker`) | n/a |
| B6 | History position restore (`pendingNavigationPosition = nil`) | **Green.** Unguarded. | **Red**: live and evicted Back land on line 1, not 121 |
| B3 | Focus steal injected into `v2MarkdownNavigate` | **Green**, 18/18. Unguarded. | **Red**: focused panel changed |
| B7 | Recreated renderer drops the pending fragment | **Green.** Unguarded. | **Red**: heading "Target" ≠ "Details" |
| B4 | Both supersede guards in `performNavigation` | **Green.** Unguarded. | Green. Nothing covers supersede. |

Run invocations: B1+B2+B6 `722f2ee7c6fc435cab2e4b043fc9753a` (logic) and `93fa3906b0204d13b95815f577e2ab5b` (unit). B3+B4+B7 `b8a1df0399024a239394ac1a7f974f90`.

## Non-blocking

### N1. Test gaps

The PR has no socket-seam test for `markdown.navigate`, `markdown.history` or `markdown.links`. The Python test only checks CLI-to-request shape against a fake server. Nothing guards:
- focus and workspace preservation;
- position restore on back/forward;
- the eviction interplay the plan promised;
- supersede.

My two probes are a ready template. Lifting them into the PR closes B3, B6 and B7 above. Also extend `testMarkdownSocketRejectsUnresolvedPanelRefsWithoutFallingBack` with stale refs for the three new methods.

### N2. Repeating a navigation does nothing after the reader scrolls away

- **Where:** `Sources/Panels/MarkdownPanel.swift:157`.
- **Problem:** `open --panel p file#anchor` returns `unchanged` and does not scroll when the current history target already equals the request.
- **Scenario:** the agent runs `open … #install`, the operator scrolls away, and the agent repeats the command. Nothing moves. The probe confirmed the `outcome=unchanged` response.
- **Fix:** an agent-CLI request for the current target should re-apply the fragment.

### N3. The panel can move after the caller was told it timed out

- **Where:** `Sources/SocketHandlers/MarkdownFeedbackHandlers.swift:478,505`.
- **Problem:** after the 20 s timeout the caller gets `timeout`, but the main-actor `Task` keeps running and can still move the panel.

### N4. Unbounded reads and payloads

- **Where:** `Sources/MarkdownAssetPolicy.swift:281,287`, plus peek and links.
- **Problem:** `prepare` reads the whole target with `maximumBytes: Int.max` or `Data(contentsOf:)`. This runs:
  - on every hover peek (280 ms), which also ships the entire file to the page through a main-thread `callAsyncJavaScript`;
  - on every link in `links --broken`, re-reading repeated targets before the dedupe check;
  - in `inspectMarkdowns`, which can marshal up to 128 × 1 MB in one main-thread JavaScript call.
- **Fix:** cap the size, and cache per path within one `links` call.

### N5. Skill and schema precision

- **Skill:** `skills/c11-markdown/references/commands.md:112` lists outcomes (`invalidTarget`, `outsideScope` and so on). The CLI only prints `navigated` or `unchanged`. Failures arrive as v2 error codes (`invalid_params`, `not_found`, `permission_denied`, `superseded`, `timeout`), with the outcome only in error data.
- **Mixed reason vocabulary in `links` output:** `brokenReasons` mixes camelCase outcomes (`notFound`, `outsideScope`, `invalidTarget`) with snake_case (`missing_fragment`, `blocked_target`, `invalid_target`). Both `invalidTarget` and `invalid_target` can appear (`MarkdownFeedbackHandlers.swift:562,582,601`).
- **Duplicate output:** `links` returns the same array under both `links` and `broken`.

### N6. A FIFO named `.md` ties up a thread on agent-CLI navigation

- **Problem:** the agent-CLI branch reads with `Data(contentsOf:)` and no regular-file or non-blocking check. A FIFO named `.md` parks a detached thread indefinitely, and the call times out at 20 s.
- **Not a regression:** `markdown.open` already hangs main on the same input.

### N7. Hardening: in-repo symlinks bypass the extension check

- **Where:** `Sources/MarkdownAssetPolicy.swift:225,241`.
- **Problem:** the extension check uses the link name, but the read goes to the resolved target. An in-repo `notes.md -> .env` symlink previews and navigates to a non-markdown file. Reach stays inside the repo.
- **Fix:** check the extension on the resolved path too.

### N8. Breadcrumb lacks the file name

- **Problem:** the breadcrumb is C11-360's heading-path label. It does not carry the file name at wide widths, and it is not the prototype's clickable `dir / file › headings` crumb.
- **Effect:** after in-place navigation, only the panel title shows which document is open.

### N9. Peek popover is offset twice

- **Where:** `Resources/markdown-viewer/viewer.js:947`.
- **Problem:** the peek `rect` is already relative to the surface, and `showLinkPeek` subtracts the surface origin again.
- **Effect:** harmless while the surface sits at (0,0); wrong placement if it ever moves.

## Repair checklist

- [ ] B1: `#` filenames open as before; add a CLI test.
- [ ] B2: anchors never duplicate the panel or skip history; add a test for New panel mode and ⌘-click on an anchor.
- [ ] B3: ⌘-click inverts the default; fix the skill text.
- [ ] N1: lift the two review probes, or equivalent socket, focus, restore and eviction tests, into the PR.

Probe tests (scratch-only, apply with `git apply`): `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review1-C11-362-probes.diff`.
