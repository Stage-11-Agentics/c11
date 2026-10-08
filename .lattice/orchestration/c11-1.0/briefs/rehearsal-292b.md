# C11-292 rehearsal, second seat (steps 16-23)

You are a helper on C11-292 (Codex GPT-6-Luna max, fast mode off). Actor `agent:luna-292b`; tab title `C11-292 Rehearsal B`. Read `owner-common.md` and `go-owner.md` in this directory: Atlas, VM-lease and sandbox rules bind you. Do not change the ticket status and do not edit the C11-292 worktree; the owner (tab:454) folds your results in.

**Job:** rehearse steps 16 to 23 of `docs/c11-1.0-signoff.md` as it stands in `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-292` (read it; read `docs/c11-292-rehearsal-notes.md` for how the guests were set up). Use the existing tagged build `signoff-1-1` (main cde01d1571) already on Atlas at `~/c11-builds/signoff-1-1`. Do NOT build anything. Use the Atlas-local sandbox (`C11_SANDBOX_HOST=local scripts/sandbox-up.sh` run on Atlas from `~/c11-builds/signoff-1-1/source`), guest name `c11-sb-c11-292b-01` (then `-02` if a step needs a fresh launch). At most ONE guest at a time; the owner holds the other VM slot.

**Speed matters more than polish.** Run as many steps as possible in one guest and one app launch; only relaunch when a step requires it (step 22 needs fresh launches per locale). Spend at most 15 minutes on any one step: if it stalls, mark it BLOCKED with the reason and move on.

**Hard stop: 05:45 PDT.** At the stop, or earlier when done: delete your guest, then write `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-292/build-remote/rehearsal-b/RESULTS.md` (create the directory; it is untracked) with, per step: PASS / FAIL (owning ticket, one-line symptom) / BLOCKED (reason) / NOT RUN, the build (`signoff-1-1`), and evidence file names in the same directory. Also note any step whose WORDING was wrong or unclear and the exact fix. Then send to the Orchestrator: `c11 send --workspace workspace:11 --tab tab:210 "HANDOFF C11-292B <one-line tally> <RESULTS.md path>" && c11 send-key --workspace workspace:11 --tab tab:210 enter`, and stop.

No credentials, no publishing, no git pushes, no edits under `.lattice/` except a single `lattice comment C11-292 --file RESULTS.md --actor agent:luna-292b` at the end.
