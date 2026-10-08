# C11-295 paired runtime workload

Run only inside the Atlas Tart guest against an explicit sandbox-up tagged app.
The controller validates the socket owner, peer PID, executable, bundle tag and
bundled CLI before changing the guest workspace. Do not run this workload on
Hyperion or against an operator session.

Reuse `tests/ghostty_patchset/runtime-fixture.py` for both the baseline and
candidate. Keep the guest hardware, fixture version, input mode and arguments
identical. Record the exact application and engine SHAs alongside the output;
the JSON records binary hashes, which must match the remote build identity sidecar.

After provisioning each tagged app and its guest socket, run from the host:

```bash
tests/ghostty_patchset/run-runtime-sandbox.sh \
  "$BASE_RUN_ID" c11-295-baseline baseline "$GHOSTTY_SHA" \
  --full-scenarios --streams 40 --samples 100 \
  --sample-pause .24 --min-sample-seconds 24 --measure-switches

tests/ghostty_patchset/run-runtime-sandbox.sh \
  "$CANDIDATE_RUN_ID" c11-295-main-stalls candidate "$GHOSTTY_SHA" \
  --full-scenarios --streams 40 --samples 100 \
  --sample-pause .24 --min-sample-seconds 24 --measure-switches
```

`--full-scenarios` is deliberate for a C11-295 baseline containing the landed
C11-294 shutdown fixes. Without it, a baseline keeps the C11-294 default of
comparison-only probes, avoiding stubborn-child shutdown against the old engine.
Do not select full scenarios for an old-engine baseline.

Each stream targets 20 Hz at roughly 10 KiB/s. The 100 input/read observations
span at least 24 seconds from first input invocation to last ACK observation,
covering three configured eight-second autosave intervals. This elapsed window
does **not** prove that three autosaves actually ran. Capture autosave and
defaults-mutation evidence separately. Producer output counters and measured
rates are stored per stream; these are PTY writes, not rendered-frame rates.

Every tenth probe creates and closes a disposable workspace, enforcing a
500 ms close-reply ceiling when switch measurement is enabled, then switches
to a streaming workspace and back. `switch_ack_ms` and `switch_observed_ms`
report p50/p95/p99/max of socket command completion and the matching
`workspace.current` observation. They do not measure visible UI switching.

The separate shutdown matrix tests graceful, ignored-HUP, ignored-HUP-and-TERM
and detached children. It reports the <=500 ms close reply separately from
the <=18 s child-disappearance budget, plus surviving-terminal ACK evidence
during background shutdown. Stream liveness is recorded at each case's end.
If the independent 180-second worker timer expires, `workload_limitations`
explicitly withdraws full-streaming-load proof for that case.

For PID-scoped keyboard input, compile `tests/ghostty_patchset/ui-driver.m` on
Atlas or in the guest through the build lock, then pass its **guest** absolute
path and verified window ID to both runs:

```text
--ui-driver /tmp/c11-295-ui-driver --ui-window <verified-CGWindow-ID>
```

The helper already accepts an explicit tagged app name; no new local-tag
allowlist is needed. Enumerate displays/windows with its `list PID TAG` command,
verify the target with `check PID TAG WINDOW`, and arrange activation only in
the disposable guest before running. Input remains PID scoped and refuses an
AX-focused-window mismatch. The harness itself does not activate the app.
Even in keyboard mode, workspace-switch metrics remain socket measurements.
Screenshot evidence, readable geometry, synthesized dismissal and observed
app exit belong to the owner's separate computer-use validation.

The checked controller budget remains 240 seconds, the external watchdog 360
seconds, and terminal workers independently expire after 180 seconds. The UI
helper retains its eight-second watchdog. Cleanup only signals fixture-owned
PIDs whose identity and command still match, and closes fixture workspaces.

Each sandbox run writes under its shared `out/ghostty-runtime-{label}` directory.
Compare the collected result paths using:

```bash
python3 tests/ghostty_patchset/runtime-fixture.py compare \
  "$BASE_RESULT_JSON" "$CANDIDATE_RESULT_JSON"
```

Comparison rejects differing workload, hardware, input mode or measurement
version. Threshold and soak verdicts remain owner-controlled; a scenario pass
is not a completed C11-270 soak or a claim of bounded native formatting.

Preparation status: code only. No build, guest workload or UI run is implied by
this README.
