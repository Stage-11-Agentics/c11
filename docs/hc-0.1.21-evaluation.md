# hc 0.1.21: evaluated, not adopted

c11 2.0 ships hc (herdr-core) **0.1.16**. On 2026-11-15 we evaluated a bump to 0.1.21, upstream's latest release, under one rule (Atin, 17:35): ship 0.1.21 only if every gate passes, otherwise ship 0.1.16 and record why. One gate failed: on stock 0.1.21, End Session no longer ends nohup and setsid jobs, which c11 promises it does. The C11 Captain recorded the decision at 17:46. Ticket C11H-333; the candidate code is on branch `c11h/C11H-333-hc-bump`.

## The gates

| Gate | Result | Evidence |
|---|---|---|
| hc's contract suite on our reproducible 0.1.21 build | **Pass** for every row c11 relies on. 16 rows pass. C7 and C15 fail because upstream now starts the macOS core through launchd; c11's launch tuple already bypasses that (rows S2 and S4 pass). C14 fails on the suite's own downgrade probe. | hc repo `contract/run.sh`, build sha256 `3fff24ec…48fe` |
| End Session ends everything a terminal started, nohup included (Settled 10; the close sheet, End All, the skill card) | **Fail.** In one sandbox guest, one interactive shell started a `&` job, a `nohup` job and a `setsid` job, then End Session. On 0.1.16 all three ended. On 0.1.21 the `&` job ended; the nohup and setsid jobs survived. | Guest run `c11h333g1`; hc 0.1.19 changelog #136 |
| macOS permission prompts still name c11 | **Not decided** (see below); not needed once End Session failed. | Guest run `c11h333g1` |
| c11 2.0 migration proofs (`scripts/c11-2.0-migration-e2e`) | Not run; not needed once End Session failed. | |

## What 0.1.17 to 0.1.21 change

From each tag's `CHANGELOG.md` and the diff of `schema/hc.openrpc.json`. Protocol generation (1) and the holder protocol (v1) are unchanged, and no method c11 calls lost a field or gained a required input.

| Version | Change | Effect on c11 |
|---|---|---|
| 0.1.19 (#136) | Ending a terminal hangs up its program and foreground job (HUP, TERM, KILL to those process groups) instead of ending every process that carries the terminal's `HC_SCOPE` token. hc still sweeps by token, but only after a holder is lost. | Breaks End Session's promise. hc offers no option to restore it. |
| 0.1.18, 0.1.20 | The macOS core gets its own identity: the binary embeds an Info.plist (`dev.herdr.core`, "Herdr Core", usage strings that say "Herdr terminals"), and every holder re-executes itself to disclaim macOS privacy responsibility. | Changes who macOS asks about a terminal program's privacy access (below). |
| 0.1.21 | A program on the alternate screen is painted as its primary screen first, then `CSI ?1049h`, `CSI ! p` and the alternate screen. | c11's hidden-panel composer read (#321) refused that paint, so mail to Grok and OpenCode would hold. Fixed on the candidate branch (commit `03815033`): c11's Ghostty ignores `CSI ! p`, so the replay does too. |
| 0.1.17 to 0.1.20 | The macOS core starts through launchd unless `HC_LAUNCHD_DIRECT` or `SSH_CONNECTION` is set. | Already handled by c11's launch tuple (contract Amendment 1). |
| 0.1.20 | `terminal.send` waits up to 60 s for a person's unsent draft. | None: c11 never calls `terminal.send`. |
| 0.1.20 | Terminals default to `TERM=xterm-256color`. | None: c11 passes its own terminal identity; a guest shell on 0.1.21 still saw `xterm-ghostty`, `ghostty`, `truecolor`. |
| 0.1.20 | `hc connect` restarts a core left from an earlier macOS login. | None: c11 runs `hc connect` only on a linked machine, over SSH, where it never applies. |
| 0.1.21 | A failed SSH login backs off 2, 5, then every 10 minutes; `hc machine login` redials at once. | c11's reconnect already uses `machine login`. |
| 0.1.18, 0.1.21 | `terminal.run` takes `size` and `display`; an observer can ask for resize notifications, and `attach --observe` no longer resizes the terminal. | Optional. `size` could retire `HCSizeGate` later. |

## Security fixes 0.1.16 lacks

Upstream fixes security bugs only in its latest release (`SECURITY.md`). Between v0.1.16 and v0.1.21 (130 commits) it published no advisory or CVE, and no changelog entry or commit is marked as a security fix. The release notes give no severity, so the ratings below are ours, with c11's exposure.

| Version | Fix | Our rating | c11's exposure |
|---|---|---|---|
| 0.1.20 (#64) | Agent messages and parent notes no longer submit a person's half-typed draft. | Medium (input integrity) | None: c11 delivers its own mail and refuses a panel with a draft. |
| 0.1.19 (#20, #21) | `hc update` and `hc server restart` keep the environment the core started with, so an updater's environment no longer reaches every new terminal. | Low (environment integrity) | Low: c11's helper refuses `hc update` (read-only folder), and c11 restarts its own cores with its own launch tuple. |
| 0.1.20 (#124) | A kept terminal whose program was lost no longer spins the core. | Low (availability) | Low: c11 starts every terminal with `keep=false`. |
| 0.1.21 (#230) | Repeated `hc wait` no longer grows the core's memory. | Low (availability) | Low: c11 does not call `hc wait`; an agent in a c11 terminal could. |
| 0.1.21 | A machine whose SSH login fails no longer retries every few seconds, which could get it banned by fail2ban or CrowdSec. | Low (availability) | Present for linked machines whose key needs an agent that is locked. |
| 0.1.20 (#210) | Terminals opened after a new macOS login use that login's ssh agent and user. | Low (correctness) | Present after logging out and back in. |
| 0.1.17 (#50) | `hc send` with arguments that are not valid text reports an error instead of crashing. | Low (local crash of one CLI call) | Present for agents that call `hc send`. |

## TCC attribution, as far as it got

- In the guest, `launchctl procinfo` showed that every shell in a 0.1.21 terminal is attributed to `c11.app/Contents/Helpers/herdr-core`, the holder's own binary, not to the app. That is upstream's disclaim at work, and it holds however c11 is launched.
- Not established: what the prompt says. The guest launched c11 over SSH, so the app itself was attributed to `sshd-keygen-wrapper`, and the guest raised no TCC request for `~/Desktop` from either build. A fair check needs each app opened through LaunchServices and a trigger that always reaches TCC, such as an Apple Event to Finder; it was written but not run.
- Expected, unverified: prompts would name the helper ("Herdr Core", from its embedded Info.plist, or `herdr-core`), and access granted to c11.app would not cover programs in terminals.

## Also proven on 0.1.21 (guest run c11h333g1)

- Quit and relaunch: 26 of 26 terminals reattached with the same process ids.
- Hidden-panel mail after the relaunch: Claude, Codex, Grok, OpenCode and Pi seats received the doorbell within 1 s; the draft and dialog seats were held; the queued seat got it after its turns.
- 15 terminals closed 50 ms to 1.2 s after opening: the other terminals stayed live, the connection was never dropped, and nothing was left running.
- A machine linked at 0.1.16 (a second account on the guest) moved to 0.1.21 with `c11 machine link --update` and reconnected at 0.1.21.

## What adopting it later would take

1. **End Session.** Either upstream ends detached processes again on a normal end, which we will not ask for (vision, Decided 10: no upstream contact), or c11 ends them without matching processes by name or environment. One such design: while the terminal's session leader is alive, c11 records the processes in its kernel session (`getsid`), then ends those that remain after hc confirms the end, checking each one's start time against process-id reuse. That covers `&` and `nohup` jobs but not `setsid` jobs or daemons, which leave the session, so the promise would need narrowing for those, and remote terminals would need the same step on the far machine. Whether that is acceptable is Atin's decision.
2. **Privacy prompts.** Run the fair check above. If prompts name the helper, either accept a second privacy identity for terminals, or wrap the helper in a small app bundle inside c11.app named c11 (still a second identity, but one that names c11; it changes the helper path, the pin manifest, retained-helper trust and the installer).
3. **The rest is ready:** the pin and recaptured paint fixtures (`766abe6c`) and the paint fix (`03815033`) on `c11h/C11H-333-hc-bump`, then the migration proofs and the full gate. Every machine that builds c11 needs the 0.1.21 build in its hash-keyed hc cache; the build host already has it.
