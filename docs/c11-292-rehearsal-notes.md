# C11-292 rehearsal notes

Date: 2026-10-03. Latest candidate build tag: `signoff-1-1`, source HEAD `cde01d1571973c8a62d93bcefc8ceb90a69793de`, Atlas build invocation `855ca04ce0f1431180865c8810c45920`, Atlas executable SHA-256 `a8b738b6cac016d2e2d8aace2049864f9d552b7321b514e792610bb00aa7084b`. Historical first run and corrected step 6 evidence use `signoff-1-0`, source HEAD `b1fa1c654c2137084fca1122ecf60d481a6bc043`, build invocation `a56aae33573c4c5baf29f3fbf6d67ffd`, executable SHA-256 `c155fef4f4715e2376254da5e6255a752772b384cbb4b4ec9cb155592bd46626`.

## Atlas-host exception: C11-261

The unchanged `scripts/groups-signoff.sh` ran on Atlas host `Atins-Mac-Studio.local`, from `/Users/atinwoodard/c11-builds/signoff-1-0/source` at source HEAD `b1fa1c654c2137084fca1122ecf60d481a6bc043`. Its Git object ID was `3ae3ddf70f3744f09af872d1f45b9103ad6c632d` and matched the local source.

Exact command:

```bash
cd /Users/atinwoodard/c11-builds/signoff-1-0/source
C11_QA_LAUNCH=fresh ./scripts/groups-signoff.sh signoff-1-0 \
  --results /tmp/c11-292-groups-signoff-20261003T071541Z
```

- UTC: started `2026-10-03T07:17:27.186Z`; tag cleanup recorded `2026-10-03T07:18:30.495Z`.
- Tagged app: `/Users/atinwoodard/Library/Developer/Xcode/DerivedData/c11-signoff-1-0/Build/Products/Debug/c11 DEV signoff-1-0.app`.
- Tagged socket: `/tmp/c11-debug-signoff-1-0.sock`.
- Tag-specific c11d socket: `/Users/atinwoodard/Library/Application Support/c11/c11d-dev-signoff-1-0.sock` (not created).
- Tag-specific session: `/Users/atinwoodard/Library/Application Support/c11/session-com.stage11.c11.debug.signoff.1.0.json`.
- Tagged PID: `67589`; the exact executable path was matched from Atlas unified logs. The runner exited 1 in its `automated` chapter on `workspace_switch_blocked`; it did not reach A10, A11–A13, or guest C1–C6. The unchanged runner recorded `forced_term` with `clean_quit:false`.
- Results: `/tmp/c11-292-groups-signoff-20261003T071541Z`; local evidence copy: `build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/host-run/`.
- Cleanup removed only the tag socket, the exact tag session file, and `/tmp/c11-groups-g60-signoff-1-0`. The PID, socket, session, and fixture root were verified absent. The tagged app and runner results were retained. No other Atlas services or tagged apps were addressed.

## Atlas disposable guests

All non-host rehearsal work stayed in disposable Atlas guests using the retained `signoff-1-0` app. Each guest had display 1 at 1024×768 and was deleted after its run.

| Guest | Tagged PID | Steps | Result |
|---|---:|---|---|
| `c11-292-01` | 607 | 1–3 | PASS |
| `c11-292-02` | 600 | 4–5 | Step 4 FAIL (C11-283); step 5 PASS |
| `c11-292-03` | 597 | 6 | Inadequate oracle; not a product failure. `about:blank` renders white, so a blank after-resize image cannot distinguish repaint from no paint. Corrected step 6 passed in `c11-292-05`. |
| `c11-292-04` | 623, window 34 (`Workspace 1`) | 7 | BLOCKED at the overall cutoff; VM `c11-sb-c11-292-04` deleted |
| `c11-292-05` | 628, window 34 (`Workspace 1`) | 6 retest | PASS with a visible loopback marker; VM `c11-sb-c11-292-05` deleted |

Guest 04 used only `scripts/c11-288-seed-import-fixtures.py`, run inside the guest. It generated one synthetic Chrome history row and two synthetic cookies under `/tmp/c11-288-fixtures`, with URL `http://127.0.0.1:19288/c11-288`. The import wizard reached step 3, selected source browser Google Chrome and synthetic source profile `c11-288-google-chrome`, and showed only destination `Default`. Import was not started, so history/cookie counts and warning behavior remain unverified. Evidence and screenshots are retained locally under `build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-04/`.

The first rehearsal timebox ended at `2026-10-03 08:03 UTC`. Step 7 was still in progress, and steps 8 and 10–23 had not started; they were marked BLOCKED in `docs/c11-1.0-signoff.md`. C11-261 and C11-283 remain failures. Step 6's old observation was ruled an inadequate oracle, then passed with the amended check below. No release tag was published.

## Step 6 oracle amendment

Atin ruled that the previous `about:blank` check was inadequate, not a C11-287 product failure: `about:blank` renders white, so the screenshot could not prove whether the browser had repainted. The checklist now requires a visible marker page at a stable URL, confirmation that the entire marker is visible before termination, and visible marker repaint at that same URL after the split resize. The c11 browser CLI resolved the attempted `data:` URI as a Google search; the corrected retest used the permitted guest-only loopback page at `http://127.0.0.1:19287/` instead.

## Continuation (UTC 2026-10-03, new 150-minute box)

Atin authorized continuing steps 7, 8, and 10–23 on the existing `signoff-1-0` build, without rerunning steps 4 or 9, and then directed a corrected step 6 retest. The continuation began at approximately `08:14 UTC`, with a `10:44 UTC` cutoff. No build or tag was created. The retained executable SHA-256 remained `c155fef4f4715e2376254da5e6255a752772b384cbb4b4ec9cb155592bd46626`.

### Corrected step 6 — PASS

- Atlas guest `c11-292-05`, display 1 at `1024×768`; c11 tagged PID `628`, window `34`. The guest launched the retained `signoff-1-0` app with `C11_QA_LAUNCH=fresh`; no agent credentials were staged. The guest was deleted after the app quit.
- `06-loopback-page.html` contains only the synthetic page. Before termination the browser showed the entire large `C11_287_REPAINT_MARKER` at `http://127.0.0.1:19287/`; see `06-before-visible.png`, `06-url-before.txt`, and `06-page-text-before.txt`.
- `06-simulate-termination.json` returned `scheduled: true`. The browser URL after termination and after resize remained `http://127.0.0.1:19287/`; `06-page-text-after-resize.txt` returned the marker. `06-after-resize.png` shows the marker visibly repainted alongside a live terminal.
- The two synthetic pointer drags did not alter pane geometry. The documented `c11 resize-pane --workspace workspace:2 --pane pane:3 -L --amount 60` action did: the adjacent areas changed from `412/412` to `351/473` pixels. This mechanism and the result are recorded in `06-resize-pane-command.txt` and `06-tree-after-resize-final.json`.
- A command sent to terminal tab 4 ran and printed `C11_287_TERMINAL_INPUT_OK`; see `06-terminal-after-input.txt`. The app was quit through its tagged app menu; PID `628` was absent before deleting the guest. Exact run artifacts are under `build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-05/`.


## Re-cut continuation on signoff-1-1

Atin directed a re-cut after C11-261 runner fix #580 and C11-283 focus-window #581 landed on main. The retained Atlas build uses exact source SHA `cde01d1571973c8a62d93bcefc8ceb90a69793de`, tag `signoff-1-1`, invocation `855ca04ce0f1431180865c8810c45920`, app `/Users/atinwoodard/Library/Developer/Xcode/DerivedData/c11-signoff-1-1/Build/Products/Debug/c11 DEV signoff-1-1.app`, and executable SHA-256 `a8b738b6cac016d2e2d8aace2049864f9d552b7321b514e792610bb00aa7084b`. Local retrieved executable SHA-256 was `9452a6c1ea9c542d027a118d5f5aa58ca8466332db3abb840602d541a57fdffd`; build manifest is `build-remote/855ca04ce0f1431180865c8810c45920/result.json`.

Per the time-box, this seat ran step 4 and step 9 on `signoff-1-1`, then steps 7, 8 and 10–15. Steps 16–23 belong to Rehearsal B in the other VM slot; this seat did not access that guest or its artifacts.

| Step | Result | Build | Machine / run | Note |
|---:|---|---|---|---|
| 4 | PASS | `signoff-1-1` | Atlas guest `c11-292-09`, display 1, PID 623 | Focus-window behavior and invalid/mismatched-target guards passed. The earlier `signoff-1-0` failure was superseded. |
| 7 | BLOCKED | `signoff-1-1` | Atlas guest `c11-292-11`, display 1, PID 630, window 34 | Within the 15-minute cap, the synthetic Chrome import reported one history row, zero cookies, and no warning; the expected imported title was not verified. Evidence under `build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/c11-292-11/07-*`; `07-history-content.txt` is empty. |
| 8 | PASS | `signoff-1-1` | Same guest/PID | Clearing the named profile preserved the default profile's cookie and the key window, with no dialog. |
| 9 | BLOCKED | `signoff-1-1` | Atlas host plus guest `c11-292-10` | The unchanged runner ran on Atlas host `Atins-Mac-Studio.local` from `/Users/atinwoodard/c11-builds/signoff-1-1/source`, with `C11_QA_LAUNCH=fresh`, tag-specific app/socket/session, and results `/tmp/c11-292-groups-signoff-20261003T102500Z`. Tagged PID 8994; run began at `2026-10-03T10:25Z`. Exact invocation: `cd /Users/atinwoodard/c11-builds/signoff-1-1/source && C11_QA_LAUNCH=fresh ./scripts/groups-signoff.sh signoff-1-1 --results /tmp/c11-292-groups-signoff-20261003T102500Z`. Tagged app: `/Users/atinwoodard/Library/Developer/Xcode/DerivedData/c11-signoff-1-1/Build/Products/Debug/c11 DEV signoff-1-1.app`; socket: `/tmp/c11-debug-signoff-1-1.sock`; tag-specific session: `/Users/atinwoodard/Library/Application Support/c11/session-com.stage11.c11.debug.signoff.1.1.json`. Host runner files are copied under `build-remote/855ca04ce0f1431180865c8810c45920/rehearsal/host-run/`. A1–A9 PASS; retained live `workspace.reordered` event does not discharge the runner's A10 JSONL `UNVERIFIED`; A11 clean quit remains unproven; A12–A13 PASS; AC5 remains the C11-270 residual. Host cleanup removed only the tag-specific socket/session/fixture. Guest C1 passed on `c11-292-10` PID 653; C2–C6 were NOT RUN before the 15-minute step cap. |
| 10 | BLOCKED | `signoff-1-1` | Guest `c11-292-11`, PID 630 | Guest PATH lacked both `claude` and `codex`; no sign-in or authentication attempt was made. Evidence: `10-agent-unavailable.png`. |
| 11 | PASS | `signoff-1-1` | Same guest/PID | Opened the exact typed-ask tab without answering; marker persisted. Evidence: `11-results.txt`, `11-after-open.png`. |
| 12 | BLOCKED | `signoff-1-1` | Same guest/PID | Per-step cap was 11:48:21 UTC. Last verification ended 11:48:23 UTC, two seconds over; partial ordering/count, no-activation, flag/ask/turn checks passed. Evidence: `12-manual-results.json` and `12-*`. |
| 13 | PASS | `signoff-1-1` | Same guest/PID | Command-I navigation opened the selected row, Escape restored the unsent marker. Evidence: `13-results-v2.json` and `13-*`. |
| 14 | BLOCKED | `signoff-1-1` | Same guest/PID | No Codex CLI/provider session was available. The synthetic `turn_end` row was visible, but a local shell prompt classified as `unknown`; single-line answer was safely refused and sent nothing, multiline returned `multiline_unsupported` and typed nothing. The draft remained after the safe refusal; this does not prove the intended known-empty/draft classifications. Evidence: `14-results.json`, screenshots and tree output. |
| 15 | BLOCKED | `signoff-1-1` | Same guest/PID; guest deleted | Step started 12:07:35 UTC; 15-minute cap was 12:22:35. After stopping the exact tagged PID, the resume launch's socket was observed ready only at 12:23:09 UTC; no post-resume assertions or UI checks were run. Evidence: `c11-292-11-step15/` report and screenshots. The guest deletion command succeeded (`deleted=c11-sb-c11-292-11`); a later list verification could not run because `tart` and `rg` were not on the Atlas PATH. The guest lease exceeded 30 minutes; record this as a rehearsal process miss. |

The `c11-292-11` guest was used for steps 7, 8 and 10–15 as instructed to batch those steps in one launch. The per-step 15-minute limits were applied; steps 7, 9, 12 and 15 remain blocked at their caps, and 10/14 remain blocked by unavailable provider tooling. The guest was deleted after the step 15 cutoff. No other tagged Atlas app or service was touched by this seat. Step 9 host run used only the `signoff-1-1` app, socket, and session; the app was quit and tag-specific session state removed.

Steps 16–23 are **NOT RUN by Rehearsal A**. Rehearsal B owns those steps and the other VM slot. Await B's `RESULTS.md` before folding in its outcomes. No merge or release tag was made.
