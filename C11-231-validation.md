# C11-231 parked validation snapshot

Parked for quota rollover. This is not a review handoff.

- Branch: `c11-1.0/C11-231-agents-json`.
- Code head before the required WIP park commit: `435e838423a9907f6481905c331912c57c8f3628`.
- Mainline included: `origin/main` at `45004b6b0838543398ef890b09b8ac3b1d56f264`.
- Atlas tag: `c11-231` only.

## Done

- Crash-live journal baselines are projected through `JournalReplayPolicy.restored` before startup publication, roster candidate selection, or restored cache hydration.
- A store close/reopen test starts from a confirmed-live baseline without writing a synthetic `connection_lost`; it checks the resulting restore candidate.
- Reopen tests preserve stored event effect/attribution and select applied exact start, ask, and turn evidence no newer than each committed baseline. They cover repeated starts/asks, a newer advisory ask, and a non-applied start after end.
- Delayed owner registration refreshes attached snapshots and hydrates restored clocks/asks.
- Copy-mode Return no longer records a human submit; terminal input observation is after AppKit/copy-mode/IME handling. Regression probes cover editing, repeats, generated input, copy mode, and TextBox Send.
- The unconfirmed localization key and closed event schema parse; project-file syntax and ticket-diff whitespace checks pass.

## Validation state

- A prior Atlas native run passed 31 targeted tests at the pre-latest-main repair head (`4826396c02a54205a25de71e620c93f5`). It is not evidence for the parked merged-main head.
- The exact merged-main test action was started with tag `c11-231`, invocation `2b0d38c397994220bc868b8b34c46e5d`, then interrupted by the rollover request during source transfer. Xcode did not start; no test result is claimed for head `435e838423a9907f6481905c331912c57c8f3628`.
- The earlier isolated `tests_v2` pass predates the current repair/main merge; rerun it on the resumed exact head.
- The current Atlas transfer is stopped. This ticket has no running Atlas job or guest, and its exact `~/c11-builds/c11-231` and `~/Library/Developer/Xcode/DerivedData/c11-c11-231` paths were removed. Atlas reported 131 GB free. Other tickets' jobs and guests were left untouched.

## Remaining after rollover

1. Run the focused native suite against the current merged-main head using only tag `c11-231`.
2. Run `test_agents_roster.py`, `test_journal_restart.py`, `test_journal_append_replay.py`, and `test_events_parity.py` in an isolated Atlas guest; include the deliberate event-stream gap recovery assertions.
3. Complete the P1 tagged UI proof: actual copy-mode Return versus real Return, editing/repeat/generated-key exclusion, TextBox Send, completion unread/seen behavior, restart clocks, and the pinned Claude Code 2.1.287 AskUserQuestion fixture.
4. Empirically inspect the named picker screen before assigning any commit key. `pickerCommitKeyCode` remains `nil` and exact picker submits fail closed until the visible fixture names the key; do not guess.
5. Record exact-head validation evidence, keep C11-270 soak `unverified`, push the final repair, and then send the review handoff.
