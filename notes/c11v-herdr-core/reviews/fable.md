# c11h M1 plan review: Fable seat (high level)

Reviewed 2026-10-31, 15:40 PDT, from `REVIEW-BRIEF.md`. Read-only: `docs/c11h-vision.md`, `docs/c11h-plan.md`, `docs/c11h-m1-brief.md`, `SPIKE-0B.md`, `feature-map.md`, `EXPLORATION.md`, `hc-federation-robustness.md`, `docs/c11v-herdr-core.md`, c11 `main`, the spike at `dd0d4e75a9f`. Live checks: the laptop's keychain and running hc, the build host load, disk, tags and guests, herdr's release manifest, the 0.1.15 tarball checksum.

The question for this seat: does M1 as scoped get Atin to "I can use this for real agent work"? Mostly yes. The ten tickets cover the feature map's hard rows and the containment is right. The findings below are the places where the plan would build the wrong thing, in the wrong order, or hand Atin something that breaks the first week.

## Findings

### 1. c11h never raises `RLIMIT_NOFILE`, and on the laptop it will be the process that spawns the core

- **Wrong or missing.** Ticket 2 has c11h start the hc core itself, but nothing in the plan raises the file-descriptor limit first, and a Finder-launched app gets launchd's soft limit of 256.
- **Evidence.** No `setrlimit` or `RLIMIT_NOFILE` anywhere in `Sources/` or `CLI/`. The guest launches the app with `open -g` (`scripts/launch-tagged-automation.sh:227`), and `launchctl limit maxfiles` on the build host reports `256 unlimited`. The audit (`hc-federation-robustness.md`, summary 6) found the holder keeps three descriptors per terminal and never raises the limit, capping it near 80 terminals. `EXPLORATION.md` §2 says plainly: "c11 must raise `RLIMIT_NOFILE` before spawning the core." In the spike the core was started by `hc-guest.sh` over SSH, not by c11, so the 200-panel run never exercised this path.
- **Consequence.** Around 80 panels, `terminal.run` fails and each new panel silently falls back to a plain, non-persistent shell. Atin's fleet with splits can reach that in a day. The Pathfinder's Scale check passes on a pre-started core and the failure shows up on the laptop.
- **Smallest fix.** Ticket 2 scope: raise the soft `RLIMIT_NOFILE` to the hard limit before spawning the core, and log both values (ticket 9). Acceptance: 200 panels with c11h launched by `open` and c11h starting the core itself. The Scale go/no-go row and the Validator run that way.

### 2. The signing identity is on the laptop, not the build host, and ticket 10 has no signing path

- **Wrong or missing.** Settled 6 sends the Pathfinder to find "where the identity is reachable from the build host." It is not on the build host and should not go there.
- **Evidence.** `security find-identity -v -p codesigning` on the laptop lists `Developer ID Application: Authentic Technologies Inc. (UKQ4QALWD4)`. `release.yml:223-266` imports the same certificate from GitHub secrets, and Actions are off for c11h. `scripts/release-local.sh` already runs this exact split: the Release build on the build host through `remote-build.sh`, then "The laptop the light tail: codesign, notarize" (lines 6, 20, 193).
- **Consequence.** Pathfinder item 2 returns "not reachable," ticket 10 stalls at the end of the run, or a seat exports the certificate to the build host, which the brief forbids. Either way the staging build arrives late or unsigned, and an ad-hoc signature re-prompts TCC on every update.
- **Smallest fix.** Settled 6 and ticket 10: Release build on the build host, signed on the laptop by a c11h variant of `release-local.sh`'s tail (codesign and staple; notarization optional for a locally installed build). Brief hard rule 1: signing on the laptop is allowed, launching is not. Pathfinder item 2 becomes a dry run of that tail on the laptop against a throwaway the build host Release build.

### 3. The signed artifact is never validated; the "update keeps grants" promise is only provable on it

- **Wrong or missing.** Every TCC and update proof runs on Debug, ad-hoc builds (the spike build for the Pathfinder, "the finished build" for the Validator), while ticket 10's signed artifact "finishes last."
- **Evidence.** Plan, go/no-go table and "How you get it" step 1. Settled 6's own reasoning: macOS ties file-access grants to the signature, and ad-hoc signatures re-ask after every update. Ticket 3's "installed newer build" acceptance runs in a guest on a dev build whose signature changes with every build.
- **Consequence.** The first exercise of "install a newer build, every agent and every grant survives" happens on Atin's machine with his real agents.
- **Smallest fix.** Split ticket 10: the signing half lands before wave 3, the laptop install half stays last. The Validator installs signed build A in the guest, grants Desktop, Documents and Downloads, starts agents, installs signed build B through the same command, and re-reads from the same shells. GREEN requires that run.

### 4. The hc pin is stale on both ends: spike on 0.1.14, plan on 0.1.15, 0.1.16 shipped with the fix in the flood and reconnect area

- **Wrong or missing.** The go/no-go evidence comes from a version nobody will ship, and the pinned version is already superseded by one that touches two tickets.
- **Evidence.** `spike/c11v/tools/hc-guest.sh:16` pins 0.1.14. The brief pins 0.1.15 (its SHA-256 matches the tarball, verified today). `releases.herdr.dev/core/latest.json` is 0.1.16: "Terminals no longer freeze when the core falls behind or loses touch with its holder: it reconnects and keeps your programs running. (#47)". That is spike defect 9 (the core's backlog under a flood) and ticket 6 (reconnect).
- **Consequence.** The Memory-under-a-flood stop condition may be measured against a known-fixed bug; ticket 6 may re-implement reconnect behavior upstream changed; the Pathfinder's 20-row checklist proves 0.1.14.
- **Smallest fix.** The Pathfinder's first act is the pin: run the 20-row checklist and the go/no-go on 0.1.16, falling back to 0.1.15 only if 0.1.16 regresses a row. The brief carries the chosen version and SHA; ticket 2 pins what the Pathfinder chose. Risk 4 gets a line: the pin is reviewed at each wave boundary.

### 5. hc's sweep kills `nohup`, `disown`, `setsid` jobs and tmux servers on panel close, and the plan never decides this

- **Wrong or missing.** A behavior change Atin will meet in the first week has no decision, no acceptance line and no mention in the guide.
- **Evidence.** Audit summary 4 (`sweep.rs:71-131`): on exit or kill every process carrying the terminal's `HC_SCOPE` token and its descendants gets HUP, TERM, KILL. `EXPLORATION.md` §7 lists it under "what c11 stops being good at." Today a closed exec panel HUPs the shell only; `nohup` survives.
- **Consequence.** Agents start dev servers, watchers and builds with `&` or `nohup`; Atin closes the panel; the server is gone and he learns it from a dead port.
- **Smallest fix.** A Settled line choosing the behavior (recommend: accept the sweep for M1; it is what makes "close ends its terminals" true). Ticket 3 acceptance: a `nohup` job's fate on close is asserted, not discovered. Ticket 9's skill notes and ticket 10's one-page guide say it in one sentence.

### 6. c11h starts with factory defaults, so day one is not "it is c11"

- **Wrong or missing.** Ticket 1 gives every setting and store a c11h home, and nothing fills it.
- **Evidence.** Vision, Separation table: defaults and saved sessions are "its own." No ticket imports them.
- **Consequence.** Atin's themes, keybindings, sidebar layout, flag kinds, panel-sheet clocks and saved agent configs are gone at first launch. "Use it for real work" begins with an hour of setup, and the M1 verdict is colored by it.
- **Smallest fix.** Ticket 10's install command offers a one-time import: copy the `com.stage11.c11` defaults domain into `com.stage11.c11h` minus Sparkle and socket keys, and copy the agent configs. Acceptance: a guest with a customized c11 yields a c11h that looks the same at first launch.

### 7. Wave 2 is a serial chain in two files; the plan calls it parallel and undercounts the build host

- **Wrong or missing.** Three tickets rewrite the same restore path, two rewrite the same gate, only one dependency is declared, and eleven build-host tags are planned on a disk already carrying nine.
- **Evidence.** Tickets 3, 4 and 8 all edit `Workspace.swift`'s restore and resume paths (feature map rows 2, 7, 11, 14, 28, 35, 40: lines 650-949, 1060-1451, 5375-5399); 7 and 8 both edit `TerminalController.swift`'s gate and `report_tty` handler (1164-2354, 10026-10114). Only 8 waits for 3. Astra owns 2, 3 and 8 in sequence with two reviews each. The build host today: load 12, one guest running for the c11 run, both goldens present and stopped, 124 GB free with 38 GB in nine existing tags (about 4.7 GB per tag).
- **Consequence.** Owners rebase against each other in the two largest files; the true critical path is 2 → 3 → 8 → Validator, and the Orchestrator plans around seven parallel seats that cannot be. Eleven tags add about 50 GB.
- **Smallest fix.** (a) Ticket 4 waits for 3, and ticket 3 lands the liveness seam (hc record state replaces "has a surface") that 4 and 8 consume. (b) The brief names the critical path and starts 3 from 2's review handoff. (c) Three build-host tags (`c11h` plus two lanes) instead of one per ticket, and the Orchestrator checks the build host free disk at launch and prunes at every completion.

### 8. Running beside herdr-app's hc is never tested, and "a folder c11h owns" invites the XDG trap

- **Wrong or missing.** the laptop already runs an hc core, and the plan has no check that two cores on one machine leave each other's terminals alone, nor a rule on how c11h isolates its state.
- **Evidence.** the laptop right now: `~/.local/share/herdr-core-try/bin/herdr-core serve`, session `default`, state `~/.local/state/herdr-core/default`, with a live SSH mux to the build host, where another core serves. Audit summary 2: a core started with a different socket directory while the real one is down sweeps every live program it cannot find, and a core of another state directory sharing a socket directory kills every terminal it does not know. `EXPLORATION.md` §2: hc takes its directories only from `XDG_STATE_HOME` and `XDG_CONFIG_HOME`, and programs inherit the core's whole environment.
- **Consequence.** Either an owner isolates by XDG variables and every agent in c11h inherits a rewritten `XDG_STATE_HOME`, breaking other tools, or c11h shares the root with herdr-app's hc and nobody has proven the two sessions survive each other's restarts.
- **Smallest fix.** Ticket 2 says it: binary in c11h's folder; state by session name under hc's default root; no XDG variables on the core. One go/no-go row: a `default` session core with live terminals beside c11h's in the guest; restart and kill each; no terminal in either session ends. Ticket 10 acceptance: herdr-app's terminals on the laptop are untouched after install and after an update.

### 9. The brief forbids one script; five others kill live c11 by name

- **Wrong or missing.** Hard rule 1 names `scripts/rebuild.sh` only.
- **Evidence.** `scripts/reloadp.sh:6` (`pkill -x c11`), `scripts/run-tests-v1.sh:37` and `run-tests-v2.sh:37` (`pkill -x c11`), `scripts/reload.sh:479` and `reloads.sh:351` (`pkill -f ".../c11.app/Contents/MacOS/c11"`). They run from whichever clone invokes them, the c11h clone included, and `test-unit-local.sh` spawns a DEV app on the local machine.
- **Consequence.** One seat running a "quick local test" from the c11h clone on the laptop kills Atin's c11 with every agent in it.
- **Smallest fix.** Hard rule 1 names them: never `rebuild.sh`, `reload*.sh`, `run-tests-v*.sh` or `test-unit-local.sh` on the laptop. Ticket 1 acceptance: no script in the c11h repo kills a process outside c11h's bundle. Ticket 10's installer is held to the same rule, proven in the guest beside a live c11.

### 10. Holder isolation has no trigger before M3

- **Wrong or missing.** The order M1 → M3 → M4 → M5 is Atin's call and sound, but the plan's only trigger for the holder patch is "if it bites," with nothing recorded to know whether it bit.
- **Evidence.** Vision M5 "starts with M4's first needed patch"; plan risk 1 "pulled forward if it bites during M1 use"; `EXPLORATION.md` decision 4 asks for holder-crash data before default-on. M3 adds federation's own edges on top (audit 9 and 10: dropped keys, a banner in the stream, stale mirrors, leaked remote children).
- **Consequence.** A holder loss during M1 use ends every terminal and the fix is two milestones away; no loss during M1 is not evidence unless someone counted.
- **Smallest fix.** One gate line between M1 and M3: at least one week of real the laptop use with holder losses counted (ticket 9 logs `holder_lost`); zero means M3, any loss means M5's holder patch first. Atin's order stands; the trigger becomes a number.

## What the plan gets right

- A separate app with its own bundle id, hc session and no Sparkle feed is the right containment; nothing lands in c11 before M8.
- Folding M2 into M1 so M1 ends in Atin's hands, and the ten tickets map cleanly onto the feature map's hard rows (the gate, restart semantics, the doorbell and input guard).
- Go/no-go on the spike build before any ticket starts; the Recovered workspace for orphans; restore never typing `--resume` into a live agent.
- Agent state stays in c11h, not in hc documents.
- Cross-family reviews and a Validator that re-runs every promise, not just the tests.

## Verdict

`READY WITH FIXES`. Findings 1 to 4 change what gets built or proven before the laptop; 5 to 10 change ticket scope, order and the run's guardrails. None requires a new ticket.

## Verification

Re-read `docs/c11h-plan.md` and `docs/c11h-m1-brief.md` as revised, 2026-10-31, 16:05 PDT.

- **F1: ADDRESSED.** Contract launch tuple raises `RLIMIT_NOFILE` to the hard limit; ticket 2's acceptance runs 200 panels with c11h launched by `open` and starting the core; ticket 9 logs the limits. See regression R1 for where the Pathfinder cannot run this row yet.
- **F2: ADDRESSED.** Settled 6 names the laptop's keychain; ticket 10 signs on the laptop through a `release-local.sh` tail; brief rules 2 and 3 allow signing and forbid export; Pathfinder item 4 is the dry run.
- **F3: ADDRESSED.** Ticket 10's acceptance is the two-build signed update in a guest with TCC grants, surviving shells and a `c11` call; the Validator runs it; ticket 10 starts once 1 merges, so the signed artifact exists before wave 3.
- **F4: ADDRESSED.** Settled 8 and Pathfinder item 1: checks run on 0.1.16, fall back to 0.1.15 on a regression, version and SHA recorded, pin held through M1; risk 4 covers later moves.
- **F5: ADDRESSED.** Decision 1 (recommend accept), "what works differently" says it to Atin, ticket 3 asserts the close behavior in a test, the guide and skill carry it.
- **F6: PARTIAL.** Decision 3 and ticket 10 import c11's settings on first install, and the promise line says so. Gap: ticket 10's acceptance never checks the import. Smallest change: one acceptance clause, "a guest with a customized c11 yields a c11h with the same settings at first launch, c11's files unchanged." See also regression R2.
- **F7: ADDRESSED.** 4 and 7 follow 3; 8 follows 3, 4, 6 and 7; ticket 3 lands the liveness seam; the critical path is named and protected; three tags, disk checked at launch and pruned at completion.
- **F8: ADDRESSED.** Contract: hc's default state root, no XDG variables on the core; go/no-go row "Two hc sessions on one machine"; ticket 2 and ticket 10 acceptances keep the `default` session and herdr-app untouched; brief rule 5 repeats it.
- **F9: ADDRESSED.** Brief rule 2 names `rebuild.sh`, `reload*.sh`, `run-tests-v*.sh`, `test-unit-local.sh` and anything that kills or launches by name; ticket 1 scopes every kill to c11h's bundle; ticket 10 kills nothing outside c11h.
- **F10: ADDRESSED.** Decision 2 sets the gate (a week of use, holder losses counted, any loss pulls the holder patch before M3); ticket 9 counts `holder_lost`; "How you get it" step 3 and the brief's objective carry the week.

Count: 9 addressed, 1 partial, 0 missed.

### Regressions introduced by the revision

- **R1. The Scale go/no-go row cannot run where the table says it runs.** The table header says the Pathfinder runs every row "on the spike build," and the Scale row now requires "core started by the app as `open` launches it (F1)." The spike build does not start the core (`hc-guest.sh` does) and does not raise the limit; that behavior is ticket 2's. Smallest change: the Pathfinder's Scale row runs on the spike build with the core started under a 256 soft limit, to record where it caps; the `open`-launched variant is ticket 2's acceptance and the Validator's row, as the plan already states for both.
- **R2. Ticket 1 contradicts decision 3 as written.** Ticket 1: "No migration from c11, c11mux or cmux state" (A2). Decision 3 and ticket 10: the installer imports c11's settings once. Both are right (the app never reads c11's state; the installer copies once, read-only), but an owner reading ticket 1 alone will refuse the import or build it into the app. Smallest change: ticket 1 adds "inside the app; the installer's one-time, read-only import is decision 3."

Not counted, one consistency item for when decision 2 lands: `docs/c11h-vision.md` Decided 4 still says the fork starts "when M4 needs a patch," and M5 "starts with M4's first needed patch." If Atin takes decision 2, those two lines move to "when decision 2's gate or M4 needs a patch."
