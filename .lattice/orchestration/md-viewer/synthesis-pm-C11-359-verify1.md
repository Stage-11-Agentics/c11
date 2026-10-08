# C11-359 follow-up verify: PR #622 at `381b05f68515201ae33f46e0a0f9b51848265c55`

Needs you: nothing.

- Seat: `agent:claude-md-synth-359`.
- Head attested: `381b05f68515201ae33f46e0a0f9b51848265c55`, one commit directly on `main` (`a95823705c`, merge-base = main tip).
- PR #622 is an open draft. `workflow-guard-tests`, `remote-daemon-tests` and `web-typecheck` pass; Drawbridge is skipped.
- Brief: `synthesis-pm-C11-359.md`.

## Verdict: PASS

## Scope

8 files, +334/−12, all within the brief:
- **PM-B1:** `MarkdownPanel.swift`, `MarkdownWebRenderer.swift`.
- **PM-B2:** `MarkdownWebRenderer.swift`.
- **Task lists:** `PanelTitleBarView.swift`, `DescriptionSanitizerTests.swift`.
- **Menu and test rename:** `MarkdownWebRenderer.swift`, `BrowserConfigTests.swift`.
- **Docs:** `docs/security-threat-model.md`, `skills/c11-markdown/SKILL.md`.
- **Probes:** `MarkdownWebRendererTests.swift`.

## Atlas

| Invocation | Tree | Result |
|---|---|---|
| `f71849771b4744ed979ab3125039f063` | exact head, `dirty=false` | 8-class slice **102/102 PASS** (72 logic + 30 host), `** TEST SUCCEEDED **`. All three PM probes (Astra's retained/evicted insertion pair, my deletion variant, Fable's appearance probe), the three task-list tests, the context-menu test and the renamed drag test pass. |
| `25fda4449b874f10a3dbca04bdd25010` | exact head with both fixes removed (`restoreContentBeforeReload = nil`; no `synchronize()` in `viewDidChangeEffectiveAppearance`) | **RED as expected.** Evicted insertion lands on **Section 28** (target at 1665.9 px); evicted deletion lands on **Section 52**; the appearance probe stays `light` through flip, publish and relayout. The four other eviction tests time out waiting for the second (latest-content) render they now require, which shows those tests are bound to the new restore sequence. |

## Item by item

- **PM-B1: holds.**
  - At eviction, `MarkdownPanel.evictRenderer` stores `readingContent = content`.
  - On recreation, `synchronize()` first loads that captured content. After the first `rendered`, the restore runs (mode, find, `scrollToLine`); its completion clears `readingContent` and, if the file changed, loads `panel.content` as a same-document reload. The bridge's `capture()`/`restore()` then carries the anchor, exactly as on the retained path.
  - `renderedRevision` stays nil until the latest revision renders, so the old text is never shown. Unchanged content keeps the single-load path.
  - Live reloads during the restore are deferred, because `synchronize()` keeps using the captured content until restore completes.
  - The fallback claim in the skill matches the bridge: a missing block falls back to the captured line (`viewer.js` `restore`).
  - Packaged (Atlas `abf19323…`): every production source in the overlay matches the PR head by SHA-256. Only a test file and the threat-model doc differ, and neither goes into the binary. The screenshots `md359-pm-package-before-insert.png` / `-after-insert.png` show Section 40 at the same viewport position after 12 sections were inserted while the reader was evicted, with five other readers open.
- **PM-B2: holds.** `MarkdownWKWebView.viewDidChangeEffectiveAppearance()` calls the owning renderer's `synchronize()` through a weak back-reference, which `close()` clears. The settings diff makes repeat calls free. In the packaged light/dark pair the reader follows the window.
- **Fix-in-place 1 (mailto docs): holds.** The threat model and the skill both name the validated `mailto:` route and its limits.
- **Fix-in-place 2 (task lists): holds.** A list item starting `[ ] ` / `[x] ` / `[X] ` gets a `☐`/`☑` marker with the label trimmed; three tests.
- **Fix-in-place 3 (context menu): holds.**
  - `willOpenMenu` removes WebKit's Open/Back/Forward/Download/Reload/Copy Link items by identifier (with title fallbacks), keeps Copy, Look Up and Services, and appends "Panel Details" (localized key `surfaceManifest.menuItem`), targeting the view.
  - The test drives `willOpenMenu` directly with WebKit identifiers.
  - Not UI-demonstrated, which is the same limit as for the browser panel's equivalent.
- **Fix-in-place 4 (test rename): done.** `testMarkdownWebViewFiltersRegisteredDragTypesAndCannotBecomeFirstResponder`.

## Non-blocking notes

1. **Installed skill copies still match `main`, not this PR.** That's checked for `~/.claude`, `~/.codex` and `~/.pi`. The owner didn't run the sync, but syncing unmerged content would be premature. Make it a merge step: after merge, run `scripts/sync-installed-skills.sh c11-markdown` and confirm the live copies contain the mailto paragraph. Merge Captain.
2. **Attach the packaged evidence to the ticket.** The four `md359-pm-package-*.png` screenshots exist only in the owner's worktree (`md-r2-panel/build-remote/`). Owner.
3. **Hardening: source mode re-anchors by line number only.** The bridge's `restore()` in source mode uses the captured line number, so retained and evicted source-mode readers both drift when lines are inserted above. This PR keeps the two paths at parity; it is an R1 bridge trait, not a regression.
4. **Hardening:** no test covers recreating an evicted reader whose file did not change (the single-load branch). It was covered by the earlier packaged pair at `c3d4d0867d`'s tree, and the branch is a direct `finishRender`.
5. **Edge case:** an escaped `- \[x] text` also becomes a checkbox. Negligible.

Evidence: [synthesis-pm-C11-359-verify1-evidence.zip](./synthesis-pm-C11-359-verify1-evidence.zip) holds both invocations' logs and `result.json`, and the fixes-removed patch.
