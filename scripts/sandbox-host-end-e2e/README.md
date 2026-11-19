# Host-end restore e2e (C11H-196)

Proves that after a host end (what a reboot does to c11), the next launch
resumes every agent conversation once, in its own cwd, hidden workspaces
included, without the operator looking and without typing into a live agent.

Runs in a sandbox guest on the build host against a tagged build. Never on the operator's laptop.

## Run it

```bash
./scripts/remote-build.sh --tag <tag>        # prints the retrieved .app under build-remote/
scripts/sandbox-host-end-e2e/run.sh "build-remote/<invocation>/c11 DEV <tag>.app" \
    --run-id <id> --out build-remote/c11h196-e2e-<id>.json
```

- `--keep` leaves the guest up; `scripts/sandbox-down.sh <id>` removes it.
- `--reuse` runs again in a guest that is already up (the driver resets its own state).
- `--allow-second` when another guest already holds slot A.
- `t=120 quiet=20 cpu=30 n=8` tune the resume deadline, the typed-input wait, the CPU window and the panel count.
- `noresume=1` relaunches with agent restart off (`CMUX_DISABLE_AGENT_RESTART=1`): nothing resumes, the shown panels get fresh shells, and (j) checks that no live panel still says its session ended (C11H-205). The resume assertions and (g) only inform in this mode.

Exit 0 when every assertion passes, 1 when one fails, 2 when the harness itself
failed. The summary JSON is written to `--out`, the full guest output beside it
(`.log`). Expect 2 to 3 minutes for sandbox-up (mostly the app upload) and about
3 minutes for the guest run (setup 12 s; collect 150 s, the 120 s deadline plus
the 30 s CPU window; less when every panel resumes early).

## What it does (guest.py phases)

1. **prepare**: TERM the app sandbox-up launched, end its hc, wipe this build's hc
   state, session file, sentinels and the ledger; install the stub `claude` at
   `/usr/local/bin/claude` (the bundled wrapper execs it); turn shards on
   (`c11.shards.enabled`); launch with `C11_QA_LAUNCH=fresh`.
2. **setup**: 8 agent panels: 2 in the selected workspace (its first panel plus a
   split; a fresh launch also makes 3 plain shells there, which are left alone),
   6 in 3 hidden workspaces that are never selected. Each runs `cd <cwd> && claude`
   (cwds include `_`, `.` and `/private/tmp`). The stub logs
   `{ts, pid, argv, cwd, pwd, panel}` to `/tmp/c11h196-ledger.jsonl`, then logs every
   stdin line. The conversation id is the wrapper's `--session-id`; a Claude-shaped
   transcript is written to `~/.claude/projects/<slug(cwd)>/<id>.jsonl` (three records
   without cwd, then records with it), and the ref is pushed as the SessionStart hook
   does (`--source hook --state alive`, no cwd). Requires the panels on 3 or more shards.
3. **quit**: SIGTERM, c11's clean quit; the clean sentinel must appear.
4. **hostend**: SIGKILL this build's hc cores, then its holders straight after (under
   3 s), repeating until neither respawns; then kill any shell or stub that outlived them.
5. **scrub**: delete `cwd` from every saved conversation ref in the session file.
6. **relaunch**: `C11_QA_LAUNCH=resume`; nothing is selected, read or focused afterwards.
7. **collect**: watch the ledger (no `read-screen`, which would attach a hidden terminal).
8. **again** (`again=1`, C11H-209): clean quit, then relaunch with resume on and watch
   for `t2` seconds (45). The summary is printed again with (k) and (l); `run.sh` reads
   the last one. `noresume=1 again=1` proves a launch never resumes an end its previous
   launch found and left; `hidetranscripts=1 again=1` (transcripts held away for the first
   relaunch, so every resume is skipped, then put back) proves a decided end is not
   decided again.

## Assertions

| | Passes when |
|---|---|
| a | every seeded id starts exactly once as `--resume <id>` within 120 s, in its seeded cwd |
| b | no two resume starts are within 0.5 s (gaps reported) |
| c | the ledger has no stdin line, checked again 20 s after the last resume |
| d | the selected workspace never changes, holds the 2 visible panels, and hidden panels have `last_seen_at` null and `being_seen` false |
| e | at most one `conversation.resume.decision` per panel this launch, total at most N + 2 |
| f | no workspace titled Recovered and no panel that did not exist before the quit |
| g | `hc-diagnostics --json` `restore_notice` is null for every panel (an absent field is reported as unknown, not a failure) |
| j | at least one panel is live, and every live panel's `restore_notice` is `previous_session_ended` with `noresume=1` (its fresh shell says the previous session ended), null otherwise |
| i | `c11 restore status --json` reports every seeded panel resumed, none needing the operator, finished; `c11 restore run --all` then schedules nothing (not issued with `noresume=1` or `hidetranscripts=1`: it would ask for every offered resume) |
| h | informational: each resume ran in its own panel |
| k | `again=1`: no agent starts after the second relaunch (every end there was decided, or predates the first relaunch) |
| l | `again=1` with `noresume=1` or `hidetranscripts=1`: every panel the first relaunch left ended reports `host_end.state` `not_resumed` with `offers_resume` true; informational otherwise |

Also reported: c11 CPU over the 30 s after the last resume (after the deadline when
none resumed), `hc-diagnostics.log` growth during the resume launch, decision events
per 10 s and by skip reason, hc-diagnostics samples every 5 s (including `host_end`
when the build has it), and the saved refs.

Baseline on main 1faa54c5 (tag `c11h196-base`): 0/8 resumed; every panel loops on
`skip transcript-unverified` ("crash recovery: transcript verification unavailable",
mode dirty, in a launch whose resume mode is clean), about 100 decisions per panel in
150 s and still firing past 200 s; hidden panels stay `ended / stopped_by_restart`.
Fails a, b and e; c, d, f pass; g is unknown (no `restore_notice` field).

## Outside signals (`mode=signal`, C11H-232)

```bash
scripts/sandbox-host-end-e2e/run.sh "build-remote/<invocation>/c11 DEV <tag>.app" \
    --run-id <id> --out build-remote/c11h232-e2e-<id>.json mode=signal
```

Four stub-agent panels (two shown, two hidden tabs), then one signal at one terminal root at a time,
never a broad `pkill`. About a minute after setup.

| | Passes when |
|---|---|
| root_is_the_shell | every terminal root's argv is the login shell: no `login`, no option string |
| incident_pattern_misses_roots | `pgrep -f "tsx mock-backend/server.ts" -n` (the 2026-11-06 pattern, read-only) lists no root |
| sigterm_root_survives | SIGTERM to panel A's root: root and stub agent alive, panel live |
| sigkill_panel_kept | SIGKILL to panel B's root: the panel stays with a `host_end` record |
| record_offers_resume | that record is `outside_signal`, signal 9, `not_resumed`, offers Resume, names the conversation |
| restore_status_lists_it | `c11 restore status` lists B as `skipped`, cause `outside_signal` |
| never_resumed_unasked | no agent start in the `quiet` seconds (8) after the end |
| restore_run_resumes_once_in_cwd | `c11 restore run --panel B` starts `--resume <id>` once, in B's cwd and panel |
| end_session_closes | `close-panel` on C still closes it |
| clean_exit_closes | Ctrl-D to the stub, then Ctrl-D to the shell, closes D |


## A mass outside-signal end (`mode=mass`, C11H-235)

```bash
scripts/sandbox-host-end-e2e/run.sh "build-remote/<invocation>/c11 DEV <tag>.app" \
    --run-id <id> --out build-remote/c11h235-e2e-<id>.json mode=mass
```

Ten stub-agent panels (two shown, eight in hidden workspaces). Each root is replaced by `exec /usr/bin/login -flp
<user> /bin/bash --noprofile --norc -c 'exec -l /bin/zsh'`, the root an older build opened, which SIGTERM ends
(the shell root C11H-232 opens ignores it). Every signal goes to one recorded root pid, never a pattern. `run.sh`
compiles `tests_v2/ax_walk.swift` into the guest so the strip's Resume all is clicked by its accessibility id
(`hc-mass-end-resume-all`); without it the run falls back to `restore run --all` and marks the click informational.
About 3 minutes after setup, two relaunches included.

| | Passes when |
|---|---|
| root_login_reported | `hc-diagnostics --json` says `root: login` for every agent terminal and `login_rooted` ≥ 7 |
| root_shell_for_a_new_terminal | a terminal opened now reports `root: shell` |
| text_reports_root_and_count | plain `hc-diagnostics` prints `login_rooted=`, `root=login` and `root=shell` |
| single_end_kept_without_mass_end | SIGTERM to S's root alone: kept with Resume, no `terminal.mass_signal_end`, no flag (checked 10 s later) |
| mass_kept_panels | SIGTERM to M's three roots within 2 s: three kept panels offering Resume |
| one_mass_end_event_with_count | one `terminal.mass_signal_end`, count 3, those panels, `auto_resume` false, no `flag_panel` or `notified` |
| no_flag_on_a_mass_end | no `flag.raised` by `c11`, and none of the three panels carries a flag |
| mass_never_resumed_unasked | no agent start in the `quiet` seconds (8) after the event |
| hidden_panels_not_shown | the selected workspace never changes; M's hidden panels keep `last_seen_at` null |
| others_wait_after_one_resumes | `restore run --panel` on the first panel alone: it resumes, the other two still offer Resume |
| resume_all_clicked_in_the_strip | the strip's Resume all was found and clicked (informational when no AX helper) |
| resume_all_once_each_in_cwd | each M panel resumes exactly once, in its cwd and panel; a second `restore run --all` adds none |
| setting_on_resumes_without_a_click | with `c11.massSignalEnd.autoResume` on, SIGTERM to A's roots: each resumes once in its cwd, one `terminal.mass_signal_end` with `auto_resume` true |
| setting_on_no_workspace_switch | the selected workspace is unchanged |
| one_ended_by_signal_event_per_panel | `c11 events tail --filter type=terminal.ended_by_signal`: exactly one per ended panel, all `kept`, signal 15 |
| two_mass_ends_in_all | one `terminal.mass_signal_end` each for M and A |
| no_flag_by_c11_in_the_run | no `flag.raised` by `c11` from the start of the run to here |
| launch_found_mass_end_recorded_once | L's three roots get SIGTERM while c11 is quit; the next launch finds them: one `terminal.mass_signal_end`, one `terminal.ended_by_signal` per panel, no flag by `c11` |
| launch_found_never_resumed_unasked | nothing resumes at that launch |
| relaunch_never_records_again | the launch after that: no `terminal.mass_signal_end`, no `terminal.ended_by_signal`, no flag by `c11`, L still offered |

## Sidebar marks after a restore (`mode=marks`, C11H-321)

```bash
scripts/sandbox-host-end-e2e/run.sh "build-remote/<invocation>/c11 DEV <tag>.app" \
    --run-id <id> --out build-remote/c11h321-e2e-<id>.json mode=marks
```

Six stub agents (two shown, four in two hidden workspaces) get Claude-shaped transcripts whose last request wrote a
5-minute prompt cache two hours ago (expired), at seeding (warm, on a whole second so the app's expiry and the
harness's agree), or never (no evidence). Some report idle at start, as
Claude's SessionStart hook does for a resumed session; the rest report nothing, as when that hook never lands. A
hidden opencode panel reports working (`agent-hook working`) and runs a stand-in `opencode`: panel 1901's shape, a
derived working saved with no conversation to resume. Then clean quit, host end and a resume launch; `c11 fleet` is
sampled every 2 s and nothing is selected or read. Screenshots land in the run's shared folder
(`~/.c11-sandbox/out/<id>/c11h321-*.png` on the Tart host). About 6 minutes after sandbox-up.

| | Passes when |
|---|---|
| resumed_every_stub | every stub agent starts exactly once as `--resume <its own conversation id>` |
| opencode_saved_working | the clean quit saved the opencode panel's `activity` as `working` (the scenario itself) |
| expired_cold_at_once | each expired panel draws cold within 40 s of its resume start (`cold_budget=`) |
| warm_idle_until_cold_at | each warm panel draws only idle from its rest (its start edge, or the end of C11-398's 120 s window) until 5 s before its cache expires |
| warm_cold_on_time | each warm panel draws cold within 25 s after its cache expires |
| no_evidence_rests_idle | the no-evidence panel draws idle after C11-398's window, never cold |
| ended_opencode_never_working | the opencode panel is in `c11 fleet` from its first appearance on, and `hc-diagnostics` (read each sample, before fleet) reports it `ended`, both within 10 samples. It may draw the working it was restored with only until hc reports the end, never after, and it ends idle; it is never resumed. A missing row, missing diagnostics or a reconnecting (`unresolved`) terminal fails |
| resumed_agent_working_then_cold | a resumed agent that reports a turn draws working, and cold again after it reports idle |

`python3 scripts/sandbox-host-end-e2e/guest-marks-test.py` runs the real collector against an in-memory guest
(well under a second, no app or guest): a valid run passes, and a missing opencode row, missing diagnostics, an
`unresolved` terminal, a phantom working, a working after the end and a wrong resume id each fail their check.

Baseline (C11H-321's guards removed, equivalent to main for these paths): fails expired_cold_at_once,
warm_cold_on_time and ended_opencode_never_working, the three ways the 2026-11-15 restore drew its sidebar.

## mode=lifecycle (C11H-322, C11H-323)

`run.sh <app> mode=lifecycle` proves what a relaunch and a resume say about agents. The stubs run c11's real
`claude-hook` (SessionStart, UserPromptSubmit, Stop) and print OSC 7501 status, as a real Claude reports both.

1. **Survivors** (clean quit and relaunch, every terminal kept): two stubs end their turn while c11 is down
   (OSC 7501 `done`, Stop spooled), two stay mid-turn, two rest before the quit, and a hidden opencode
   stand-in with no hooks and no conversation is saved working and is done while c11 is down. Pass: no ended or
   rested survivor and not the opencode panel ever reads `working` after the relaunch; a mid-turn survivor reads
   `working` within 20 s (hc's word), then rests when it reports its turn end. A hidden Codex stand-in captures
   its own conversation (`conversation capture-runtime`), prints OSC 7501 `working`, then ends its turn by
   Codex's notify while c11 is up, so hc keeps a `working` older than the turn end (C11H-123): it never reads
   `working` after the relaunch, whichever of hc's record and the journal row arrives first.
2. **Resumed** (host end, resume launch): every stub resumes once and its SessionStart (source `resume`) leaves
   its journal `idle/live/confirmed` within 20 s; an expired prompt cache draws `cold` within 40 s; a warm one
   rests `idle`.

`observe=30` and `cold_budget=40` tune the survivor window and the cold budget.

