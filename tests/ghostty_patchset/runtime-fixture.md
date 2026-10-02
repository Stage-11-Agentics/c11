# Tagged runtime evidence for C11-294

One bounded harness, `runtime-fixture.py`, supports an existing `sandbox-up.sh` guest or the owner's explicitly authorized local tagged C11-294 artifacts. It does not launch/relaunch c11 or discover targets. The controller checks the exact tagged bundle ID, bundled CLI path, socket ownership, expected socket filename, and Darwin socket peer PID's executable before creating anything. Production sockets and untagged apps fail closed. Local mode additionally requires `--local-tagged`, exactly `c11-294-base` or `c11-294-ghostty`, the matching app filename/socket, and a new output directory below `/tmp`.

## Authorized local tagged run

The owner's go-owner authorization permits these owned Hyperion tagged apps until ATLAS BUILDS LIVE. Start the exact tagged artifacts separately through the existing launch script; this harness only connects. Run baseline before the candidate build/load, and do not run baseline/candidate simultaneously:

```sh
tests/ghostty_patchset/run-runtime-sandbox.sh --local-tagged \
  c11-294-base /tmp/c11-debug-c11-294-base.sock \
  '/absolute/path/c11 DEV c11-294-base.app' \
  '/absolute/path/c11 DEV c11-294-base.app/Contents/Resources/bin/c11' \
  baseline 26c3e499ed8c4d65e3748248de7fd04c1e9a8103 \
  /tmp/c11-294-base-runtime-UNIQUE --comparison-only

tests/ghostty_patchset/run-runtime-sandbox.sh --local-tagged \
  c11-294-ghostty /tmp/c11-debug-c11-294-ghostty.sock \
  '/absolute/path/c11 DEV c11-294-ghostty.app' \
  '/absolute/path/c11 DEV c11-294-ghostty.app/Contents/Resources/bin/c11' \
  candidate <40-character-candidate-ghostty-sha> \
  /tmp/c11-294-candidate-runtime-UNIQUE
```

Use actual absolute bundle/CLI paths and new output paths. The old baseline tag **requires `--comparison-only`**: it performs the 30-stream responsiveness measurements and skips focus transitions, paste, and all shutdown cases. Its old HUP loop can otherwise hang main. Cleanup verifies and kills fixture worker identities before closing their workspaces, so baseline cleanup does not ask the old engine to terminate a stubborn fixture. Candidate performs all reported scenarios unless comparison-only is explicitly requested. Logs are adjacent to the `/tmp` result directory. A local watchdog failure requires inspecting only that named tagged app and the recorded fixture PIDs; never kill production c11.

## Optional AppKit/Quartz input route

After the root agent obtains the UI slot and verifies the target display/window, append `--ui-driver /tmp/c11-294-ui-driver-final --ui-window <exact-CGWindow-ID>` to the local invocation above. Use the verified window belonging to that invocation's tagged app. Baseline still needs `--comparison-only`; candidate uses the same input mode for a valid latency comparison.

Build the driver once, then use the same binary for both baseline and candidate:

```sh
scripts/with-build-lock.sh xcrun clang -std=c11 -fobjc-arc -Wall -Wextra \
  tests/ghostty_patchset/ui-driver.m -o /tmp/c11-294-ui-driver-final \
  -framework Cocoa -framework ApplicationServices -framework Carbon
```

Before a full run, append `--streams 1 --samples 3 --comparison-only` for a bounded one-stream preflight. The defaults remain 30 streams and 100 samples; each report records the actual counts. A preflight is not a full-load acceptance run. Remove the two count overrides for the matching full runs. Keep `--comparison-only` on baseline.

For a focused candidate shutdown repair check, append `--streams 30 --samples 3` to the candidate command without `--comparison-only`. This retains all thirty streaming terminals, runs three initial input samples, then the focus, paste, and four shutdown cases. It is a shutdown regression run, not a replacement for the matching 100-sample latency benchmark. No additional mode or target authorization is needed.

For each probe, the controller invokes `text PID TAG WINDOW token` followed by `key PID TAG WINDOW return`. PID comes from the verified socket peer, not a caller's PID claim. The independently supplied driver must validate process/tag/window/AX focus and use only `CGEventPostToPid`. There is no global-keyboard fallback or automatic focus repair. A driver error fails the fixture. The harness records the driver hash, target, invocation responses, and input mode. Each driver call has a 10-second subprocess limit (the provided driver also has its own eight-second timer).

The provided driver spaces key-down/key-up by 20 ms and reports that interval. PTY receipt is timestamped by the child independently; read-screen observation starts after the driver exits and therefore includes this completion floor. Pointer events clear inherited modifiers, but posting alone never proves a click or selection. The C11-294 visual selection proof used repeated keyboard Select All/Copy with clipboard and screenshot checks.

Before each UI probe, a read-only two-second readiness gate checks `debug.terminal.render_stats` for the exact probe tab: `inWindow`, `isFirstResponder`, `desiredFocus`, `appIsActive`, `windowIsKey`, and `isActive` must all be true. This also runs after churn. Every sample records the observations and readiness elapsed time separately from input latency. The gate never re-focuses or re-sends input; an error or timeout fails before posting. The measured key latency therefore describes input after focus readiness, not input arriving during an unresolved focus transition.

The existing `pty_ms` and `read_screen_ms` measure the full invocation interval, including driver startup, validation, Unicode text posting, and Return posting. UI runs additionally report `key_to_pty_ms` and `key_to_read_screen_ms`, measured from the Return driver's `first_post_ns` timestamp immediately before its first `CGEventPostToPid` call. These remove pre-post invocation overhead; read-screen observation still includes polling. `invocation_to_key_post_ms` reports the removed overhead explicitly. Each metric has p50/p95/p99/max distributions, and every sample preserves the raw invocation/post/receipt/observation timestamps. This supplements socket-only delivery measurements; it is not a physical hardware keyboard measurement. Offline comparison refuses socket/UI mode or measurement-version mismatches and includes both invocation and Return-post distributions. Setup, streaming, paste, and close actions continue to use the verified socket. This option does not itself perform hide/show or claim GPU/cursor visual proof. The root agent owns the timed UI slot, display/window verification, and synthesized dismissal proof.

## Clock and probe evidence

Parent send time, child receipt time, and parent observation time use `clock_gettime_ns(CLOCK_MONOTONIC_RAW)`, a shared kernel clock. macOS Python 3.9's `monotonic_ns()` can have a process-local epoch and must not be subtracted across these processes. Before creating workspaces, a bounded subprocess sanity check verifies that a child RAW timestamp falls between its parent's surrounding RAW timestamps. Each ACK identifies its clock. The controller rejects missing/noninteger Return-post timestamps and enforces `invocation_start <= return_first_post <= pty_received <= read_screen_observed` for UI probes. All timestamps use the shared RAW clock. Socket probes enforce the corresponding invocation/receipt/observation order. Ordinary deadlines use same-process monotonic time.

The probe appends every received chunk unchanged to `raw-input.bin`. CR, LF, and CRLF delimit tokens; empty delimiter fragments are ignored even when a CRLF pair arrives in separate reads. Unexpected nonempty tokens still fail and produce `error.json` with the exception and traceback. ACK timestamps are captured immediately after the PTY read, before the output/file writes. Responsiveness samples are saved to `result.json` after each probe, before churn, so a later error retains prior samples. Interrupted sampling remains marked incomplete and preserves available distributions.

The first readiness or ACK-observation miss stops sampling before another token is sent. A `miss-pNNNNNN.json` snapshot preserves the latest child ACK, exact raw input as hex, read-screen text, and focus stats, including individual observation errors. It is also embedded in the failed sample. A missing Return cannot contaminate the next token, and received-but-unobserved ACKs remain distinguishable from absent input. Existing failed-run directories are never reused.

## Sandbox baseline and candidate

Build the two tagged artifacts on Atlas through the existing remote build lane. Preserve their full parent and Ghostty SHAs and archive hashes. Start one guest at a time from the same golden image and with the same CPU/RAM:

```sh
scripts/sandbox-up.sh c11-294-baseline /absolute/path/to/c11\ DEV\ c11-294-baseline.app
tests/ghostty_patchset/run-runtime-sandbox.sh \
  c11-294-baseline c11-294-baseline baseline <40-character-baseline-ghostty-sha>
scripts/sandbox-down.sh c11-294-baseline

scripts/sandbox-up.sh c11-294-candidate /absolute/path/to/c11\ DEV\ c11-294-candidate.app
tests/ghostty_patchset/run-runtime-sandbox.sh \
  c11-294-candidate c11-294-candidate candidate <40-character-candidate-ghostty-sha>
scripts/sandbox-down.sh c11-294-candidate
```

Use the real tags of the supplied artifacts, not invented labels. The `.app` paths are on the machine running `sandbox-up.sh`; its normal default host is Atlas. No fixture commands should be run against the operator's production session. The separate local mode above is restricted to the specifically authorized tagged builds. If a run times out, retain its logs and dispose that sandbox guest; do not rerun in uncertain state.

Evidence is written to the guest share `/Volumes/My Shared Files/out/ghostty-runtime-{baseline,candidate}` and its adjacent `.log`. On the Tart host these remain under `~/.c11-sandbox/out/<run-id>/`. Each output directory must be new. Fetch the evidence before guest disposal if the host's retention policy requires it. Compare downloaded reports without contacting an app:

```sh
python3 tests/ghostty_patchset/runtime-fixture.py compare \
  /absolute/baseline/result.json /absolute/candidate/result.json
```

The comparison refuses different workload settings, CPU/RAM, or local/sandbox modes. Sandbox baseline also runs comparison-only automatically. It emits both distributions without inventing a release threshold. Operator screen verification and C11-270's soak verdict remain with their owners.

## What the harness proves

- **Thirty real streaming PTYs plus churn.** Thirty terminal workspaces each start their Python worker directly with `workspace.create(initial_command=...)`, bypassing interactive shell rc files. Churn uses `/bin/sleep 1`. The thirty PTYs emit ~10 KiB/s each at 20 Hz and change their titles once per second. While those workers run, a separate raw-PTY probe receives 100 unique synthetic input lines. Every tenth sample creates/closes a disposable workspace. Reports contain p50/p95/p99/max for input-to-child receipt and input-to-read-screen observation, individual samples, missed probes, and actual sample duration. The report identifies socket-synthetic or PID-scoped AppKit/Quartz input. These measurements include their injection and observation overhead; they are not physical hardware keyboard latency. Worker readiness and ACKs come from child output/files, not echoed shell command text.
- **Final focus state.** Ten workspace-away/back transitions under stream load end with explicit tab focus. The harness asserts the current workspace, selected/focused tab flags, a fresh PTY ACK, and bundled-CLI read-screen output. This provides setup and socket-state evidence for AC3. It does not assert an onscreen frame or cursor; a fresh computer-use pass must verify real hide/show and focused typing on the named tagged window, with screenshots and proven dismissal.
- **Paste byte recorder.** A raw PTY enables bracketed paste, emits DSR queries at 50 Hz, initially delays reads for two seconds to create backpressure, and records a deterministic 6,000-line UTF-8 payload exceeding PTY capacity. The harness requires exactly one pair of paste fences, byte-for-byte payload equality, and real DSR replies outside the fences. It preserves `paste-input.bin`, the recorder's `received.bin`, lengths, and SHA256 hashes. This proves observed bytes, not B072's backend-error reachability or deliberately reordered write completions. Native fixtures own those checks. No real agent receives the payload.
- **Real tab shutdown and surviving-terminal responsiveness.** Graceful HUP, ignored HUP, ignored HUP+TERM, and a detached `setsid` keep sentinel run as actual terminal child programs alongside the streaming workload. Closing the sole-tab workspace must return within 500 ms (`close_ms`). Immediately after return, the already-running probe terminal receives a fresh token and must acknowledge it; the harness records the complete probe, `survivor_roundtrip_ms`, and `close_to_survivor_ack_ms`. For both ignored-HUP cases, the original child's identity must still exist before and after this probe, proving input responsiveness overlaps its grace period. Only then does the harness wait for eventual child disappearance, with `reap_ms` measured from the original close request and limited to 18 seconds. It also requires the graceful HUP marker, the detached child's continuing heartbeat, and surviving stream-worker identities. Records are persisted before close, immediately after return, after the survivor probe, and after reaping/completion, so failures retain the separate measurements. Cleanup signals only fixture PIDs whose start time and unique command path still match. These four paths do not cover freshly attributed foreground groups, already-reaped leaders, reused PGIDs, or early pre-setsid races.

## Limits and cleanup

Normal RPCs have a four-second socket timeout. Probe receipt/display has a two-second deadline. Each shutdown request has a 20-second transport timeout so a stalled return can be recorded, but **a return over 500 ms fails**. Eventual child disappearance must occur within 18 seconds of the close request, independently of close-return timing. The controller has a 240-second work budget and an external 360-second hard watchdog. Ordinary workers self-terminate after 180 seconds; the detached sentinel after 120 seconds. Verified remaining fixture processes are killed first during cleanup; then only created workspaces are closed. Cleanup failures fail the run. A watchdog kill requires sandbox disposal in sandbox mode, or scoped inspection of the named tagged app in local mode, because graceful controller cleanup may not have run.

The 30 streams occupy one terminal workspace each; the fixture does not create 30 simultaneously visible panes. Comparison requires the same direct-initial-command workload version on both artifacts. It records actual duration rather than claiming a prolonged soak. App-tick timing/count metrics are explicitly unperformed in `result.json`. Render/occlusion screenshots, physical keyboard testing, full shutdown safety fixtures, packaged no-harness smoke, and C11-270's longer load run remain separate proof gates.

Engine SHA is recorded as the caller's claim. The harness hashes the actual app executable, each `Contents/MacOS/*.dylib` (including the Debug implementation library), bundled CLI, fixture source, and optional UI driver; map those hashes to the recorded build manifest before accepting exact-artifact evidence.
