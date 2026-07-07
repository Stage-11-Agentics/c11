# Validation — C11-159 Socket dispatcher extraction

Branch `ts/dx-dispatcher-extraction` @ HEAD. Base (fork point) `8a98f0f7e`.
Tagged build: `dx-post` (Debug) → `/tmp/c11-debug-dx-post.sock`.

## DX-2 behavior parity — PASS

**tests_v2 dispatch subset, same host method + env as the baseline** (single tagged
instance, no prod-hostile per-test relaunch; see `PARITY-baseline-8a98f0f7e.md` for why):

| | Baseline @ 8a98f0f7e | Post @ HEAD |
|---|---|---|
| PASS (4) | metadata_persistence, send_requires_surface, rename_tab_cli_parity, doctor_command | **identical** |
| ENV-FAIL (10) | global_flags/v1_error_contract, mailbox_parity, pane_metadata(+persistence), notifications, m7_title/description/precedence, sidebar_metadata_commands, browser_api_p0 | **identical** |

- Pass/fail **set identical**; failure-**reason types identical** (ULID-normalized diff empty —
  `pane_not_found`, envelope-timeout, capabilities-missing, focus-suppression, all environmental,
  not product; this is CI-green origin/main behavior on a shared QA-fresh instance).
- Logs: `tests_v2-baseline-8a98f0f7e.log`, `tests_v2-post-<sha>.log`.

**Full `c11-logic` suite (hermetic, the authoritative DX-2 oracle):** `** TEST SUCCEEDED **`,
`All tests passed`, on the final tree.

## DX static rows — PASS

- **DX-1** 0 dispatch switches remain in `TerminalController.swift` (`switch cmd`/`switch method`/
  worker switches all relocated to `SocketDispatch.swift`); 15 per-domain handler files under
  `Sources/SocketHandlers/`.
- **DX-3** `nonisolated` declarations 208==208 (base==HEAD); `DispatchQueue.main.sync` 13==13.
  Surface send/read workers still `nonisolated` (off-main). Verified against base commit.
- **DX-4** `TerminalController.swift` 20351 → 8774 LOC; largest handler `BrowserHandlers.swift`
  1942 LOC. Both under target.
- **DX-5** 472 unique command/method case-strings **identical** base vs HEAD — no renames, adds,
  drops, or wire-response changes.

## Release-config build — PASS (closes code-review Minor 1)

`xcodebuild -scheme c11 -configuration Release build` → `** BUILD SUCCEEDED **`. Confirms the
`#if DEBUG` gating is correct in release: `debug.terminals` compiles ungated; no ungated code
references a gated symbol; no ungated `dlog` (0 in SocketHandlers/, 0 newly-ungated in TC).

## Live "I saw it work" — PASS

Real socket commands driven through the extracted dispatch on the running tagged build
(`live-dispatch-smoke-dx-post.txt`): `ping`→PONG (SocketDispatch), `list-windows`→WindowHandlers,
`list-workspaces`→WorkspaceHandlers, `tree`→SystemHandlers, `identify`→system.identify, and an
unknown command → the identical v1 `Unknown command` error. All correct.

## Note: browser.wait hang (pre-existing, NOT a C11-159 regression)

`test_browser_api_p0` issues a `browser.wait` that blocks in `v2AwaitCallback` /
`v2WaitForBrowserCondition` against a QA-fresh app with no loaded page, wedging the tagged
instance until relaunch. A process sample confirmed the blocked stack is **verbatim-relocated
code** (BrowserHandlers.swift, byte-identical to base) with identical runtime behavior; the test
env-fails identically in baseline. It is a property of the browser-wait-against-no-page path, not
of the dispatcher relocation. Out of scope for this mechanical ticket (DX-5); flagged for
awareness.

**Verdict: validation PASS.** Ready for `pr_open`.
