# C11-292 rehearsal notes

Date: 2026-10-03. Candidate build tag: `signoff-1-0`. Build source HEAD: `b1fa1c654c2137084fca1122ecf60d481a6bc043`, directly above authorized main `9c9cf4ba444c05ba9d82a85ea9bcb3323487b920`. Atlas build invocation: `a56aae33573c4c5baf29f3fbf6d67ffd`; retained executable SHA-256: `c155fef4f4715e2376254da5e6255a752772b384cbb4b4ec9cb155592bd46626`.

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
| `c11-292-03` | 597 | 6 | FAIL (C11-287) |
| `c11-292-04` | 623, window 34 (`Workspace 1`) | 7 | BLOCKED at the overall cutoff; VM `c11-sb-c11-292-04` deleted |

Guest 04 used only `scripts/c11-288-seed-import-fixtures.py`, run inside the guest. It generated one synthetic Chrome history row and two synthetic cookies under `/tmp/c11-288-fixtures`, with URL `http://127.0.0.1:19288/c11-288`. The import wizard reached step 3, selected source browser Google Chrome and synthetic source profile `c11-288-google-chrome`, and showed only destination `Default`. Import was not started, so history/cookie counts and warning behavior remain unverified. Evidence and screenshots are retained locally under `build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-04/`.

The overall rehearsal timebox ended at `2026-10-03 08:03 UTC`. Step 7 was still in progress, and steps 8 and 10–23 had not started; they are marked BLOCKED in `docs/c11-1.0-signoff.md`. The C11-261 failure and C11-283/C11-287 failures remain explicit. No release tag was published.
