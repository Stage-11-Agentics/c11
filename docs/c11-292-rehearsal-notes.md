# C11-292 rehearsal notes

Date: 2026-10-03. Latest candidate build tag: `signoff-1-1`, source HEAD `cde01d1571973c8a62d93bcefc8ceb90a69793de`, Atlas build invocation `855ca04ce0f1431180865c8810c45920`, Atlas executable SHA-256 `a8b738b6cac016d2e2d8aace2049864f9d552b7321b514e792610bb00aa7084b`. Historical first run and corrected step 6 evidence use `signoff-1-0`, source HEAD `b1fa1c654c2137084fca1122ecf60d481a6bc043`, build invocation `a56aae33573c4c5baf29f3fbf6d67ffd`, executable SHA-256 `c155fef4f4715e2376254da5e6255a752772b384cbb4b4ec9cb155592bd46626`.

## Atlas-host exception: C11-261

The unchanged `scripts/groups-signoff.sh` ran on Atlas host `Atins-Mac-Studio.local`, from `$HOME/c11-builds/signoff-1-0/source` at source HEAD `b1fa1c654c2137084fca1122ecf60d481a6bc043`. Its Git object ID was `3ae3ddf70f3744f09af872d1f45b9103ad6c632d` and matched the local source.

Exact command:

```bash
cd $HOME/c11-builds/signoff-1-0/source
C11_QA_LAUNCH=fresh ./scripts/groups-signoff.sh signoff-1-0 \
  --results /tmp/c11-292-groups-signoff-20261003T071541Z
```

- UTC: started `2026-10-03T07:17:27.186Z`; tag cleanup recorded `2026-10-03T07:18:30.495Z`.
- Tagged app: `$HOME/Library/Developer/Xcode/DerivedData/c11-signoff-1-0/Build/Products/Debug/c11 DEV signoff-1-0.app`.
- Tagged socket: `/tmp/c11-debug-signoff-1-0.sock`.
- Tag-specific c11d socket: `$HOME/Library/Application Support/c11/c11d-dev-signoff-1-0.sock` (not created).
- Tag-specific session: `$HOME/Library/Application Support/c11/session-com.stage11.c11.debug.signoff.1.0.json`.
- Tagged PID: `67589`; the exact executable path was matched from Atlas unified logs. The runner exited 1 in its `automated` chapter on `workspace_switch_blocked`; it did not reach A10, A11–A13, or guest C1–C6. The unchanged runner recorded `forced_term` with `clean_quit:false`.
- Results: `/tmp/c11-292-groups-signoff-20261003T071541Z`. Retained host evidence includes `build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/host-run/run.json`, `commands.txt`, `execution-notes.md`, and `termination.jsonl`.
- Cleanup removed only the tag socket, the exact tag session file, and `/tmp/c11-groups-g60-signoff-1-0`. The PID, socket, session, and fixture root were verified absent. The tagged app and runner results were retained. No other Atlas services or tagged apps were addressed.

## Atlas disposable guests

All non-host rehearsal work stayed in disposable Atlas guests using the retained `signoff-1-0` app. Each guest had display 1 at 1024×768 and was deleted after its run.

| Guest | Tagged PID | Steps | Result |
|---|---:|---|---|
| `c11-292-01` | 607 | 1–3 | Step 1 BLOCKED in the canonical table; steps 2–3 PASS |
| `c11-292-02` | 600 | 4–5 | Step 4 FAIL (C11-283); step 5 PASS |
| `c11-292-03` | 597 | 6 | Inadequate oracle; not a product failure. `about:blank` renders white, so a blank after-resize image cannot distinguish repaint from no paint. Corrected step 6 passed in `c11-292-05`. |
| `c11-292-04` | 623, window 34 (`Workspace 1`) | 7 | BLOCKED at the overall cutoff; VM `c11-sb-c11-292-04` deleted |
| `c11-292-05` | 628, window 34 (`Workspace 1`) | 6 retest | PASS with a visible loopback marker; VM `c11-sb-c11-292-05` deleted |

Guest 04 used only `scripts/c11-288-seed-import-fixtures.py`, run inside the guest. It generated one synthetic Chrome history row and two synthetic cookies under `/tmp/c11-288-fixtures`, with URL `http://127.0.0.1:19288/c11-288`. The import wizard reached step 3, selected source browser Google Chrome and synthetic source profile `c11-288-google-chrome`, and showed only destination `Default`. Import was not started, so history/cookie counts and warning behavior remain unverified. Evidence includes `build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-04/07-import-wizard.png` and `07-before-import.png`.

The first rehearsal ended at its overall cutoff. Step 7 was still in progress, and steps 8 and 10–23 had not started; they were marked BLOCKED in `docs/c11-1.0-signoff.md`. C11-261 and C11-283 remain failures. Step 6's old observation was ruled an inadequate oracle, then passed with the amended check below. No release tag was published.

## Step 6 oracle amendment

Atin ruled that the previous `about:blank` check was inadequate, not a C11-287 product failure: `about:blank` renders white, so the screenshot could not prove whether the browser had repainted. The checklist now requires a visible marker page at a stable URL, confirmation that the entire marker is visible before termination, and visible marker repaint at that same URL after the split resize. The c11 browser CLI resolved the attempted `data:` URI as a Google search; the corrected retest used the permitted guest-only loopback page at `http://127.0.0.1:19287/` instead.

## Continuation (UTC 2026-10-03, new 150-minute box)

Atin authorized continuing steps 7, 8, and 10–23 on the existing `signoff-1-0` build, without rerunning steps 4 or 9, and then directed a corrected step 6 retest. The continuation began at approximately `08:14 UTC`, with a `10:44 UTC` cutoff. No build or tag was created. The retained executable SHA-256 remained `c155fef4f4715e2376254da5e6255a752772b384cbb4b4ec9cb155592bd46626`.

### Corrected step 6: PASS

- Atlas guest `c11-292-05`, display 1 at `1024×768`; c11 tagged PID `628`, window `34`. The guest launched the retained `signoff-1-0` app with `C11_QA_LAUNCH=fresh`; no agent credentials were staged. The guest was deleted after the app quit.
- `06-loopback-page.html` contains only the synthetic page. Before termination the browser showed the entire large `C11_287_REPAINT_MARKER` at `http://127.0.0.1:19287/`; see `06-before-visible.png`, `06-url-before.txt`, and `06-page-text-before.txt`.
- `06-simulate-termination.json` returned `scheduled: true`. The browser URL after termination and after resize remained `http://127.0.0.1:19287/`; `06-page-text-after-resize.txt` returned the marker. `06-after-resize.png` shows the marker visibly repainted alongside a live terminal.
- The two synthetic pointer drags did not alter pane geometry. The documented `c11 resize-pane --workspace workspace:2 --pane pane:3 -L --amount 60` action did: the adjacent areas changed from `412/412` to `351/473` pixels. This mechanism and the result are recorded in `06-resize-pane-command.txt` and `06-tree-after-resize-final.json`.
- A command sent to terminal tab 4 ran and printed `C11_287_TERMINAL_INPUT_OK`; see `06-terminal-after-input.txt`. The app was quit through its tagged app menu; PID `628` was absent before deleting the guest. The exact retest artifacts include `build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-05/06-before-visible.png`, `06-after-resize.png`, `06-page-text-after-resize.txt`, `06-terminal-after-input.txt`, and `06-pid-after-quit.txt`.


## Re-cut continuation on signoff-1-1

Atin directed a re-cut after C11-261 runner fix #580 and C11-283 focus-window #581 landed on main. The retained Atlas build uses source SHA cde01d1571973c8a62d93bcefc8ceb90a69793de, tag signoff-1-1, invocation 855ca04ce0f1431180865c8810c45920, and Atlas executable SHA-256 a8b738b6cac016d2e2d8aace2049864f9d552b7321b514e792610bb00aa7084b. The local retrieved executable SHA-256 was 9452a6c1ea9c542d027a118d5f5aa58ca8466332db3abb840602d541a57fdffd. The manifest is build-remote/855ca04ce0f1431180865c8810c45920/result.json.

Rehearsal A ran steps 4 and 9, then 7, 8, and 10–15. Rehearsal B ran steps 16–23 in its separate Atlas guest. Rows below identify the build and the exact evidence files for each step. Where a required observation is unsupported by retained evidence, the result is BLOCKED or the triage says EXPECTED / WORDING; a directory listing alone is not evidence.

## Full rehearsal results

| Step | Result | Build | Machine / guest run ID | Evidence and recorded outcome | Owner |
|---:|---|---|---|---|---|
| 1 | BLOCKED: live executable hash was not captured, so the guest process is not bound to the manifest | signoff-1-0 | Atlas guest c11-292-01, display 1, PID 607 | build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-01/01-doctor-screen.txt; 01-about.png; 01-tree.txt. These show doctor/About/tree identity details but no live executable hash. | C11-292 |
| 2 | PASS | signoff-1-0 | Atlas guest c11-292-01, display 1, PID 607 | build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-01/02-selection-read.txt; 02-selection-cleared.txt; 02-selection-selected.png. | none |
| 3 | PASS | signoff-1-0 | Atlas guest c11-292-01, display 1, PID 607 | build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-01/03-large-selection.json; 03-large-selection-final.png. | none |
| 4 | BLOCKED: focus-window path is visible; invalid-window and mismatched-send outputs are not retained | signoff-1-1 | Atlas guest c11-292-09, display 1, PID 623 | build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-09/04-focus-b-final.png; 04-key-a-after-negative-tests.png; 04-tree-after-new-window.json. The cited files exist, but do not show the missing CLI results for the negative guards. The earlier signoff-1-0 failure is superseded only for the focus-window behavior. | C11-283 |
| 5 | PASS | signoff-1-0 | Atlas guest c11-292-02, display 1, PID 600 | build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-02/05-resize-request.json; 05-resize-after.json; 05-frontmost-finder-before.txt; 05-frontmost-finder-after.txt; 05-before-resize-window-b.png; 05-after-resize-window-b.png. | none |
| 6 | PASS: amended visible-marker oracle | signoff-1-0 | Atlas guest c11-292-05, display 1 at 1024×768, PID 628, window 34; guest deleted | build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-05/06-simulate-termination.json; 06-url-after-resize.txt; 06-page-text-after-resize.txt; 06-terminal-after-input.txt; 06-before-visible.png; 06-after-resize.png; 06-pid-after-quit.txt. The same loopback URL and large marker were visible after resize while the terminal remained live and accepted input. The earlier about:blank observation was an inadequate oracle, not a product failure. | none |
| 7 | BLOCKED: 15-minute cap; expected imported title not verified | signoff-1-1 | Atlas guest c11-292-11, display 1, PID 630, window 34 | build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-11/07-import-result.png; 07-history-content.txt; 07-fixture-manifest.json; 07-import-wizard.png. Partial result showed one history row, zero cookies, and no warning; 07-history-content.txt is empty, so the title is unverified. | C11-288 / timebox |
| 8 | PASS | signoff-1-1 | Atlas guest c11-292-11, display 1, PID 630, window 34 | build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-11/08-named-only-cookie.png; 08-named-after-clear.txt; 08-default-reload-signed-in.json; 08-tree-after-clear.json. Clearing the named profile preserved the default cookie and key window, with no dialog. | none |
| 9 | BLOCKED: runner and guest chapters incomplete; A10 event evidence is empty | signoff-1-1 | Atlas host plus guest c11-292-10 | build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/host-run/run.json; steps.jsonl; a10-event-tail.txt; termination.jsonl; cleanup-summary.json; build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-10/c11-292-signoff/c11-292-10/C1-tree-final.json; C1-cleanup.txt; C1-after-type.png. The host-run event-tail artifact is zero bytes. A1–A9 and A12–A13 passed; A10 remains UNVERIFIED, A11 clean quit remains unproven, guest C1 passed, and C2–C6 were NOT RUN before the 15-minute cap. AC5 remains the C11-270 residual. | C11-261 / timebox |
| 10 | BLOCKED: provider binaries unavailable; no authentication attempt | signoff-1-1 | Atlas guest c11-292-11, PID 630 | build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-11/10-agent-unavailable.png. Guest PATH had neither claude nor codex. | C11-263 / C11-274 |
| 11 | PASS | signoff-1-1 | Atlas guest c11-292-11, PID 630 | build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-11/11-results.txt; 11-after-open.png. Opened the exact typed-ask tab without answering; marker persisted. | none |
| 12 | BLOCKED: per-step cap exceeded; no timestamped cutoff record retained | signoff-1-1 | Atlas guest c11-292-11, PID 630 | build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-11/12-manual-results.json; 12-no-activation.json; 12-current.png. Partial ordering/count, no-activation, and flag/ask/turn checks passed; the seat recorded that final verification was over the cap, but exact cap timestamps are not claimed because they are absent from these files. | C11-265 / timebox |
| 13 | PASS | signoff-1-1 | Atlas guest c11-292-11, PID 630 | build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-11/13-results-v2.json; 13-ask-highlighted.png; 13-escape-open.png; 13-escape-closed.png; 13-turns-filter.png. The separate Return and Escape paths preserved the draft. | none |
| 14 | BLOCKED: no provider CLI/session; unknown shell prompt refused safely | signoff-1-1 | Atlas guest c11-292-11, PID 630 | build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-11/14-results.json; 14-before.png; 14-after.png; 14-tree-after.json. The single-line input was refused at an unknown prompt; multiline returned multiline_unsupported and typed nothing; draft remained. This does not prove the recognized empty-prompt or occupied-draft classifications. | C11-268 |
| 15 | BLOCKED: no post-resume assertions retained; timing details are not in the report | signoff-1-1 | Atlas guest c11-292-11, PID 630; guest deleted | build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-11-step15/report.json; 01-blocked-with-no-unread.png; 02-blocked-sidebar.png; 03-seen-still-blocked.png. The report and screenshots contain pre-resume checks only. The seat recorded that the 15-minute cap elapsed before post-resume verification, but exact start/readiness timestamps and guest-lease timing are not claimed because no retained file contains them. | C11-273 / timebox |
| 16 | BLOCKED: B reported FAIL, but the clean-quit action was not completed; see triage | signoff-1-1 | Rehearsal B guest c11-292b-02 | build-remote/rehearsal-b/evidence/c11-292b-02/16-03-interrupted-resume.png; 16-03-interrupted-resume.txt; 16-05-clean-quit.txt; 16-05-quit-menu-state.json; 16-05-quit-inspection.txt. Interrupted resume restored the richer layout. On the clean-quit pass, Quit was disabled and PID 2644 remained alive, so no clean-quit restore result was observed. | C11-311 |
| 17 | PASS: synthetic response correlation and unread preservation only; live-provider response and resolution unverified | signoff-1-1 | Rehearsal B guest c11-292b-02 | build-remote/rehearsal-b/evidence/c11-292b-02/17-01-response-fixture.txt; 17-02-ui-response-attempt.txt; 17-03-completion-unread.txt. The files show a synthetic shell response and a different tab's unread completion. They do not show continuation or resolution of the original blocked ask, and do not cover the revised live-provider journal metric check. | C11-231 |
| 18 | PASS | signoff-1-1 | Rehearsal B guest c11-292b-02 | build-remote/rehearsal-b/evidence/c11-292b-02/18-01-focus-history.txt; 18-02-typing-history.txt; 18-02-after-window.png. | none |
| 19 | PASS | signoff-1-1 | Rehearsal B guest c11-292b-02 | build-remote/rehearsal-b/evidence/c11-292b-02/19-01-block-agent-switch.txt; 19-02-operator-return.txt; 19-04-before-operator-return.png; 19-05-after-operator-return.png. | none |
| 20 | FAIL: triaged PRODUCT BUG; release blocker NO | signoff-1-1 | Rehearsal B guest c11-292b-02 | build-remote/rehearsal-b/evidence/c11-292b-02/20b-07-undo.png; 20b-07-undo.txt; 20b-09-settings-rail.txt; 20b-10-settings-after.png; 20b-11-resize-and-cleanup.txt. Undo reported Tabs; selecting Rail in Settings reopened the same area's 11-tab rail. Resize bounds did not change, so divider reflow is unconfirmed. | C11-249 |
| 21 | EXPECTED / WORDING: B reported FAIL, but observed behavior matches the attached confirmation sheet | signoff-1-1 | Rehearsal B guest c11-292b-02 | build-remote/rehearsal-b/evidence/c11-292b-02/21-14-after-cmd-w.png; 21-15-close-window-confirmation.png; 21-16-after-red-close.png; 21-16-after-red-close-tree.txt; 21-18-close-idle-last-tab.png; 21-18-close-idle-last-tab.txt. Control+Command+W opened Close window?; leaving it unanswered kept W2 open when the red close control was clicked. Closing an idle last terminal removed its workspace without a replacement terminal. | C11-250 / C11-311 |
| 22 | BLOCKED: 15-minute cap; locale matrix incomplete | signoff-1-1 | Rehearsal B guest c11-292b-02 | build-remote/rehearsal-b/evidence/c11-292b-02/22-ru-other-tabs-1.png; 22-ru-other-tabs-2-valid.png; 22-ru-other-tabs-5.png; 22-uk-other-tabs-1.png; 22-ru-feed.png; 22-uk-feed.png; 22-ja-feed.png; 22-ko-feed.png; 22-zh-Hans-feed.png; 22-zh-Hant-feed.png; 22-ru-group-header.png; 22-uk-group-header.png; 22-ja-group-header.png; 22-ko-group-header.png; 22-zh-Hans-group-header.png; 22-zh-Hant-group-header.png; 22-workspace-group-help.txt. Six locales showed translated close-other-tabs copy, Feed, and group header. RU counts 1, 2, 5 and UK count 1 were captured. RU/UK close-workspaces counts, RU/UK close-window count 2, and RU/UK/JA Feed multiline and send-guard refusals were not run. | C11-291 / timebox |
| 23 | BLOCKED: no active/resume-candidate agent and no guest provider CLI | signoff-1-1 | Rehearsal B guest c11-292b-02 | build-remote/rehearsal-b/evidence/c11-292b-02/23-agent-preflight.txt. No active or restore-candidate agent turn existed; the guest had no Claude, Codex, or OpenCode CLI and no credentials were staged. | C11-274 |

## Triage of Rehearsal B findings

### Step 16: EXPECTED / WORDING (C11-311)

Interrupted resume is a PASS: the richer saved layout returned. The clean-quit case did not run to completion. The retained evidence shows Quit disabled and the exact tagged PID 2644 still alive; it does not show a successful quit or the subsequent resume. The app defaults to a quit confirmation, so the procedure must explicitly answer it and verify termination before comparing clean-quit restoration. Relevant source: Sources/c11App.swift and Sources/AppDelegate.swift.

Replacement step text for the checklist owner:

> Interrupted resume: record the saved smaller layout, stop only the exact tagged PID, relaunch with C11_QA_LAUNCH=resume, and verify the richer layout returns. For clean quit, recreate the smaller layout, activate Quit from the tagged app menu, choose Quit in the confirmation if one appears, and verify the exact tagged PID exits before relaunching with resume. If Quit is disabled or the PID remains alive, record BLOCKED and stop; do not infer a layout-restore failure.

### Step 20: PRODUCT BUG (owner C11-249; release blocker: NO)

One-line repro: Force-offer the tab-rail tip, overflow the strip, choose Try Rail, choose Undo, then select Rail in Settings; the same area's rail reopens.

User impact: Undo clears the preview state but selecting the persisted Rail mode reopens that area's rail, reducing terminal content after the operator had undone the tip.

Code and screenshots agree on the intended local reset: TabRailTipCenter.performUndo calls setRailOpen(false, inPane:) before returning to Tabs, while the subsequent Settings selection reopens the rail. The retained screenshot 20b-10-settings-after.png shows the reopened 11-tab rail. This is a recoverable layout regression in a narrow tip-undo path; the operator can return to Tabs, so it is not a release blocker. Relevant source: Sources/TabRailTipCenter.swift and vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift.

### Step 21: EXPECTED / WORDING (C11-250, C11-311)

One-line outcome: Control+Command+W opens the Close window? sheet; while it is unanswered, the red window control cannot dismiss the attached sheet or close W2.

The window remains open by design while its confirmation sheet is attached. AppDelegate.confirmCloseMainWindow refuses a second close request while a sheet is attached. The idle-last-terminal observation also matches the default setting: LastTabCloseShortcutSettings.defaultValue is true, so Command+W on an idle last terminal closes that workspace; no replacement terminal is expected. Relevant source: Sources/AppDelegate.swift and Sources/WorkspaceManager.swift.

Replacement step text for the checklist owner:

> In W2, run sleep 600 and press Control+Command+W. Choose Close in the confirmation sheet to close W2; do not leave the sheet unanswered and then expect the red close control to bypass it. Verify W2 disappears, the app remains open, and no new window or terminal appears in W1. Separately, with the default last-tab setting, press Command+W on an idle last terminal and verify its workspace closes without a replacement terminal.

## Guest and sandbox protocol transferred from the sign-off document

Astra finding 3 also applies to the transferred A10 tail recipe: the existing a10-event-tail.txt is zero bytes, and the original tag-plus-PID instance guess is not valid for this runner. The event remains unverified. Resolve the target instance from the tagged app's feed list --json output before any future tail; do not treat this transferred recipe as a successful A10 capture.



## Transferred protocol text

Before a guest, check Atlas for `/tmp/c11-validator-vm-wanted`; if present, do not start another guest. Start isolated guests with `C11_SANDBOX_HOST=local scripts/sandbox-up.sh <run-id> <Atlas-retained-tagged.app> --agents claude,codex` only where the run plan requires them. Do not sign in or request new credentials; stop if either CLI asks for authentication or displays a quota screen. Keep each guest lease within its 30-minute cap, quit the tagged app, and delete the guest with `C11_SANDBOX_HOST=local scripts/sandbox-down.sh <run-id>` when the run ends. Use the `GUEST_APP`, `SOCKET`, `CLI`, and `DSOCK` values printed by `sandbox-up.sh`. Initial launches use `C11_QA_LAUNCH=fresh`; restore steps use `resume` only where stated. This ticket does not publish, sign for release, or push a release tag.

For a guest relaunch after verifying and stopping only its tagged PID, set shell variables to that guest's exact `GUEST_APP`, `SOCKET`, and `DSOCK` values, then use:

```bash
C11_SANDBOX_HOST=local scripts/sandbox-exec.sh <run-id> /usr/bin/env \
  C11_SOCKET_MODE=automation C11_ALLOW_SOCKET_OVERRIDE=1 \
  C11_SOCKET="$SOCKET" C11_SOCKET_PATH="$SOCKET" CMUXD_UNIX_PATH="$DSOCK" \
  C11_QA_LAUNCH=fresh /usr/bin/open -a "$GUEST_APP"
```

Use `C11_QA_LAUNCH=resume` only for restore steps. Never use host `open` on a guest app path. Each guest lease ends within 30 minutes. If a checklist run needs more time, save its evidence, stop the UI run, delete that guest, and continue in a newly named guest from the same retained tagged app. Record the guest run ID for every step. Do not leave a guest running while idle.

This checklist is for the disposable Atlas guest. Use synthetic terminal text, asks, flags, browser profiles, and imported data. Never import a real browser profile. For every guest UI run, record the guest display, exact tagged c11 PID and window, set a 20-minute stop timer, prove dismissal with synthesized input, and inspect `c11 tree --no-layout` so each important pane is readable. The only host exception is C11-261's unchanged runner in step 9: use only the `signoff-1-1` tagged app, socket, and session, launch with `C11_QA_LAUNCH=fresh`, quit it, then remove its session state. Record exact host paths and result directory. Touch no other Atlas services or tagged apps, and do not drive Hyperion's production c11 window.

Mark each numbered checkbox after the expected result is observed. If a step fails, stop that step, fill its row in **Rehearsal results**, attach the screenshot or exact CLI output, and name the listed owning ticket. Do not remove or weaken a failed check to make the rehearsal green.

### C11-261 execution boundary

The groups chapter follows `docs/groups-signoff.md` without copying its scenarios or changing its runner. Atin directed this one host exception; all C1–C6 pointer, keyboard, menu, and locale work stays in the guest. Run the unchanged runner on Atlas from the retained remote-build source checkout at `~/c11-builds/signoff-1-1/source`, against the matching tag app in Atlas DerivedData. The source checkout and app paths must match the build result manifest.

Run the unchanged automated runner on the Atlas host from the retained remote source checkout, with the tag-specific app, socket, and session shown here:

```bash
results_dir="/tmp/c11-292-groups-signoff-$(date -u +%Y%m%dT%H%M%SZ)"
printf 'C11-292 C11-261 results_dir=%s\n' "$results_dir"
cd "$HOME/c11-builds/signoff-1-1/source"
C11_QA_LAUNCH=fresh ./scripts/groups-signoff.sh signoff-1-1 \
  --results "$results_dir"
```

The runner writes `run.json` before launching. In a second Atlas host shell, read `candidate.app` and `candidate.cli` from that manifest, then match the exact `Contents/MacOS/c11` process path to record its PID. The manifest records the app path, not the PID. Before A10 runs, query `feed list --json` with the tag-specific CLI and socket. Match the exact tagged PID to the returned instance, and use that instance name for the event tail; do not infer it from the tag and PID:

```bash
results_dir="<copy the exact absolute path printed by the runner shell>"
APP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidate"]["app"])' "$results_dir/run.json")"
CLI="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidate"]["cli"])' "$results_dir/run.json")"
target="$APP/Contents/MacOS/c11"
PID="$(ps -axo pid=,command= | awk -v target="$target" '{ command=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command); if (command == target) print $1 }')"
test -n "$PID" || { echo "tagged signoff-1-1 process not found at $target" >&2; exit 1; }
"$CLI" --socket /tmp/c11-debug-signoff-1-1.sock feed list --json \
  > "$results_dir/a10-feed-list.json"
candidate_instance="<exact instance for the matched PID from a10-feed-list.json>"
"$CLI" --socket /tmp/c11-debug-signoff-1-1.sock events tail \
  --instance "$candidate_instance" --follow --filter type=workspace.reordered \
  2>&1 | tee "$results_dir/a10-event-tail.txt"
```

Retain the final A10 `workspace.reordered` event with its `seq`, timestamp, and payload beside `commands.txt`; stop the follow tail after capture. A captured live event from the matched instance separately discharges the runner's A10 event-emission `UNVERIFIED` marker. Do not pass `--perf-artifact`; C11-270 owns that measurement. Confirm A11 is a graceful quit and the exact tagged PID is gone. Remove only `~/Library/Application Support/c11/session-com.stage11.c11.debug.signoff.1.1.json`; verify `/tmp/c11-debug-signoff-1-1.sock` is gone. Keep the build app and results directory. Record the Atlas hostname, retained source checkout, app path, socket, session path, exact commands, PID, UTC, event excerpt, and results directory in the rehearsal notes.

For C1–C6, keep the signoff app inside the disposable guest. Stage the unchanged fixture helper and its Python support files through this run's share, then use `sandbox-exec.sh` to copy them into the guest:

```bash
RUN_ID="<actual guest run id>"
mkdir -p "$HOME/.c11-sandbox/out/$RUN_ID/groups-source"
mkdir -p "$HOME/.c11-sandbox/out/c11-292-signoff/$RUN_ID"
cp scripts/groups-fixture.sh "$HOME/.c11-sandbox/out/$RUN_ID/groups-source/"
cp -R tests_v2 "$HOME/.c11-sandbox/out/$RUN_ID/groups-source/"
C11_SANDBOX_HOST=local scripts/sandbox-exec.sh "$RUN_ID" /usr/bin/env "RUN_ID=$RUN_ID" /bin/zsh -c '
  source="/Volumes/My Shared Files/out/$RUN_ID/groups-source"
  destination="$HOME/c11-sandbox/groups-source"
  mkdir -p "$destination/scripts"
  cp "$source/groups-fixture.sh" "$destination/scripts/"
  cp -R "$source/tests_v2" "$destination/"
'
```

For every independent C chapter, use the guest relaunch command above with `C11_QA_LAUNCH=fresh`, then provision/seed/snapshot with the unchanged helper inside the guest. Set `C11_SOCKET` and `C11_CLI` to the exact `SOCKET` and `CLI` printed by `sandbox-up.sh`:

```bash
C11_SANDBOX_HOST=local scripts/sandbox-exec.sh "$RUN_ID" /usr/bin/env \
  RUN_ID="$RUN_ID" C11_SOCKET="$SOCKET" C11_CLI="$CLI" C11_SIGNOFF_CHAPTER=C1 /bin/zsh -c '
    cd "$HOME/c11-sandbox/groups-source"
    ./scripts/groups-fixture.sh signoff-1-1 provision \
      --out "/Volumes/My Shared Files/out/c11-292-signoff/$RUN_ID/$C11_SIGNOFF_CHAPTER-provision.json"
    ./scripts/groups-fixture.sh signoff-1-1 attention \
      --out "/Volumes/My Shared Files/out/c11-292-signoff/$RUN_ID/$C11_SIGNOFF_CHAPTER-attention.json"
    ./scripts/groups-fixture.sh signoff-1-1 snapshot \
      --out "/Volumes/My Shared Files/out/c11-292-signoff/$RUN_ID/$C11_SIGNOFF_CHAPTER-before.json"
  '
```

Repeat the fixture command with `C11_SIGNOFF_CHAPTER=C2` through `C6`, saving each chapter's cleanup output separately. Follow each scenario and its cleanup/quit/fresh-reprovision direction in `docs/groups-signoff.md`, changing its helper tag argument to `signoff-1-1`. If the lease expires, set `RUN_ID` to the new guest run ID and restage the helpers there. Keep H1–H3 blank for Atin. Never launch the host app for these checks.

After each C chapter's UI actions, clean only its recorded fixture and save that cleanup result before quitting the tagged guest app:

```bash
C11_SANDBOX_HOST=local scripts/sandbox-exec.sh "$RUN_ID" /usr/bin/env \
  RUN_ID="$RUN_ID" C11_SOCKET="$SOCKET" C11_CLI="$CLI" C11_SIGNOFF_CHAPTER=C1 /bin/zsh -c '
    cd "$HOME/c11-sandbox/groups-source"
    ./scripts/groups-fixture.sh signoff-1-1 cleanup \
      --out "/Volumes/My Shared Files/out/c11-292-signoff/$RUN_ID/$C11_SIGNOFF_CHAPTER-cleanup.json"
  '
```

Set `C11_SIGNOFF_CHAPTER` to the matching C1–C6 value for each cleanup. Quit with synthesized input, prove the exact guest PID is gone, and use the fresh relaunch command before the next chapter.
