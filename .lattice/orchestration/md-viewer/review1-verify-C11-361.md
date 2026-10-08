# Review 1 verification: C11-361 at `c428aefca8a0335287c5d7982dd308210927ee27`

Reviewer: `agent:claude-md-review-361` (Claude Opus). The review worktree is checked out detached at `c428aefca8`, which is rebased onto `origin/main` and includes `fd263426f9`.

The repair briefs (`repair1-C11-361.md` and `repair1b-C11-361.md`) were checked against the owner's validation (`ev_01M4EB0RJSGZRP8W237XVMCGPS`) and handoff (`ev_01M4EB12EQY2K4BK4GRRZ83A7Y`).

## Verdict: PASS

- **B1, B2 and B3 are fixed.** Each is proven at runtime in an Atlas guest, and each has a test that goes red when its fix is removed (B2 is the exception: it has no test and is proven at runtime only).
- **No fix caused a regression.**
- **Residuals are non-blocking.** They are listed below, together with one correction to the owner's validation report.

## Blocking items

| Item | What the repair touched | Red without it (Atlas) | Runtime (guest `c11-sb-rv361v`, tagged `rv-361v`) |
|---|---|---|---|
| **B1**: unmounted and evicted panels | Design (a) from the brief:<br>• `MarkdownFeedbackHandlers.v2MarkdownWebCall` calls `ensureRenderer()` and pins with `beginAgentQuery()`.<br>• `whenReadyAndRendered` waits a bounded 8 s off-main.<br>• `MarkdownVisibleWatch` attaches through panel-level reader events.<br>• The reader is sized to `lastKnownViewportSize`.<br>• The cache keeps evicting normally. | **M7** (the watch no longer creates a reader) turned `testVisibleWatchCreatesReaderForNeverMountedPanelOverSocket` red. | **Never-shown panel** (`panel:7`, created by `markdown open --workspace workspace:3`; workspace 2 selected):<br>• `visible` gave `["Doc"]`, lines 1–90.<br>• `scroll --heading Installation` succeeded; the next `visible` gave `["Doc","Installation"]`, lines 92–98.<br>• `scroll --heading Inst` returned `ambiguous`.<br>• `--watch` streamed `Installation`, then `Alpha`.<br><br>**Evicted panel:**<br>• Six more hidden readers were opened and queried.<br>• The debug log shows `markdown.renderer.evicted panel=ECE7AE0B…` (panel:7), twice, the second time while it was being watched.<br>• While the reader was gone, `theme --set dark` streamed as model state.<br>• `scroll` recreated the reader, and both `visible` and the watch then showed `Installation` in the dark theme.<br><br>Workspace 2 stayed selected throughout. |
| **B2**: `open-external` stole focus | `NSWorkspace.OpenConfiguration` with `activates = false`. Success is reported from the completion handler, waited on off-main with an 8 s bound. The skill line says the file opens "behind c11". | **M6** (`activates = true`) has no test and stays green, as expected. This item is proven at runtime only. | Frontmost before: `c11`. Command result: `opened: true`. Frontmost after: `c11`, still `c11` after a second call. TextEdit lists the `rv361.md` window, and the screenshot shows it behind c11. |
| **B3**: unresolved ref fell back to the focused panel (Review 2) | `v2MarkdownPanelTarget`, `v2MarkdownOpen` and `v2MarkdownGetContent` now call `v2RejectUnresolvedTargetRefs`. That shared function gained an optional `fallbackWorkspaceManager`. With nil it behaves exactly as before, so the destructive verbs that already use it are unchanged. | **M8** (rejection removed from the markdown resolver) turned `testMarkdownSocketRejectsUnresolvedPanelRefsWithoutFallingBack` red: `not_ready` instead of `not_found`; theme, typeface and font changed; a hidden reader was created. | `panel:99999` returned `not_found` for theme set, font, scroll and visible. An unknown UUID and the area ref `area:2` also returned `not_found`. The focused `panel:5` theme was `system` before and after. |

## Non-blocking items from Review 1, plus N10 and N11 from Review 2

| Item | Status | Evidence |
|---|---|---|
| **N1**: missing tests | Fixed for M4 and M5 | **M4** (server and panel theme guards removed) turned `testUnsupportedThemeAndTypefaceAreRejectedWithoutChangingTheModel` and the socket rejection test red. **M5** (`close()` no longer completes observers) turned `testClosingRendererNotifiesItsStateObservers` red. Residuals R1 and R2 below. |
| **N2**: waiter test didn't prove the wakeup | Fixed | The `onWaiting` handshake now parks the waiter before `finish()`. **M3** (no broadcast) turned `testFinishingWakesAnEventWaiter` red with a timeout. |
| **N3**: a watch pinned its reader forever | Fixed | The pin lasts only for the attach query (`releasePin`). Runtime: the watched panel was evicted while its watch ran. Residual R1: **M11** (pin never released) stays green. |
| **N4**: no deadline on the watch's initial state | Fixed | `waitForInitialState(timeout: 8)` returns a `timeout` error. Verified by reading the code. |
| **N5**: stale cached state preferred over the fresh result | Fixed | `beginOrPublish` takes the fresh `visible` result. Verified by reading the code. |
| **N6**: fd closed before disconnect cancellation finished | Fixed | `setCancelHandler` plus a semaphore wait before the fd is closed. Verified by reading the code. |
| **N7**: stream path skipped checks | Fixed | Order is now auth, then `startupNotReadyResponse`, then `shouldContinue`, then routing keys. The stream loop checks `shouldContinue()` every 0.5 s. Verified by reading the code. |
| **N8**: skill gaps | Fixed | The skill now names `markdown.agent_cli` (also added to the `api.md` feature list), and covers `not_ready`/`timeout`, opening behind c11, the watch stop conditions and the ambiguity rule. The claim "the gold flash appears when the panel is next shown" is accurate: revealing BG 5 s after a hidden `scroll --heading Alpha` showed the gold flash on Alpha. |
| **N9**: bare index and non-decimal scale | Fixed | `--panel 5` is rejected with a hint to use the `panel:1` form. `--scale 0x1p0` is rejected. **M10** (bare integers accepted again) made `tests/test_cli_markdown_agent.py` fail (`['markdown','visible','--panel','1','--json']`). The clean CLI passes. |
| **N10**: ambiguous heading matching | Fixed | **M9** (first match wins again) turned `testScrollToHeadingPrefersExactAndReportsAmbiguousBroaderMatches` and the socket test red. Runtime: `Inst` returned `ambiguous`. |
| **N11**: watch stop conditions in the skill | Fixed | The skill names panel close. Runtime: `close-panel --panel panel:9` ended its watch with exit 0, and the process was gone. |

**Baseline:** Atlas run `24690066…` passed:
- `MarkdownWebRendererTests`: 17 tests.
- Logic suites: 43 tests (`CapabilityFeatures`, `MarkdownVisibleStateBuffer`, `MarkdownPanelFontScale`, `MarkdownPresentation`, `MarkdownRendererRetentionPolicy`, `SocketClientCommandLoop`).

**Mutation runs:** set A (`5fad24f3…`: M3, M4, M5, M7, M9) and set B (`4803c55d…`: M8, M5′, M11, M6). Set B's CLI was then built under tag `rv-361` for the M10 run. Mutations were made only in scratch worktrees, which are now removed.

## Residuals (non-blocking, none is a regression)

- **R1. The watch-specific tests the owner reported don't exist.** The validation says "watch tests cover renderer pin release on eviction, readiness deadlines, fresh initial state, bounded/coalesced updates, disconnect cleanup, panel close, listener stop, and stream auth/startup behavior". The diff adds no tests for pin release, deadlines, fresh initial state, disconnect, panel close, listener stop or stream auth/startup. Two mutations confirm it:
  - **M5′**: `MarkdownPanel.close()` no longer sends `.closed`. All tests stay green.
  - **M11**: the watch never releases its pin. All tests stay green.

  The behaviour is correct at runtime (guest checks above), so this is a test gap and a reporting inaccuracy, not a defect.
- **R2. `MarkdownWebRenderer.observeState` and `removeStateObserver` have no production callers.** The watch now uses panel-level reader events. That means `testClosingRendererNotifiesItsStateObservers` (the M5 test) covers an API nothing uses, while the real close path (M5′) is untested.
- **R3. Transient states during reader recreation.** When an evicted panel's reader is recreated, the watch emits pre-restore states (`heading_path []` at line 1, then `["Doc"]` at line 1) before the restored position. A consumer briefly sees a false jump to the top.
- **R4. The 0.5 s wakeups.** The stream loop and the initial-state wait wake every 0.5 s to check `shouldContinue()`. This is bounded and off-main; state delivery itself is event-driven.
- **Shared-resolver follow-up (already reported by the owner).** `v2ResolveWorkspaceSurface` in the `DebugHandlers` panel-sheet, rail, strip-scroll and hover seams still falls back to the focused panel for an unresolved explicit ref. This is outside this PR.

## Housekeeping

- The guest `c11-sb-rv361v` is deleted.
- Extra Atlas tags are deleted per the Orchestrator's disk instruction. Only the seat tag `rv-361` remains.
- During the run, Atlas reached 100% full (614 MB free). I freed my round-1 tags, and the volume is now at 118 GB free.
