# C11-292: rewrite the sign-off checklist for Atin

You are a writer on C11-292 (Codex GPT-6-Luna max, fast mode off). Actor `agent:luna-292w`; tab title `Signoff Checklist`. Read `owner-common.md` in this directory. Do not change the ticket status.

**Problem.** `docs/c11-1.0-signoff.md` (worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-292`, branch of PR #579) became an agent's VM rehearsal protocol: guest leases, sandbox-exec commands, stop timers. Atin cannot use it. He will hand-test the `signoff-1-1` build on his own Mac this morning.

**Job.** Rewrite `docs/c11-1.0-signoff.md` from scratch as Atin's checklist. You own only that file. Another seat (tab:454) is moving the rehearsal table and guest protocol into `docs/c11-292-rehearsal-notes.md` at the same time; do not edit that file. Link to it once, at the bottom.

What Atin's checklist must be:
- **Setup** (top, five lines or fewer): the app is `~/Library/Developer/Xcode/DerivedData/c11-signoff-1-1/Build/Products/Debug/c11 DEV signoff-1-1.app`. It runs beside his normal c11, with its own socket and its own settings. How to launch it, and how to point a shell's `c11` CLI at it (read `scripts/launch-tagged-automation.sh` and `skills/c11-hotload/SKILL.md` for the tagged socket path). Build identity in one line: tag `signoff-1-1`, main `cde01d1571`, version 0.67.0.
- **Steps**: keep the same areas and ticket names as the current 23 steps, merged or trimmed where possible. Each step is one short do-and-see block: what he does, what he should see, and a checkbox. Agent steps use his own logged-in Claude Code and Codex inside the signoff build (no fixtures, no guests). Steps that need fake data (browser import, flags, asks) give the one command or one action that creates it. Browser import uses a synthetic fixture or is skipped with a note; never his real browser profile.
- **Fold in the review's instruction fixes**, which you will find in `/Users/atin/Projects/Stage11/code/c11-worktrees/review-artifacts/c11-292-review-36002e9594.md`. Finding 5: step 8 closes the named-profile tab before clearing it. Finding 6: step 13 tests Return and Escape as two separate sequences. Finding 7: step 14 continues straight on after the refusal, and describes the refusal by its error text. For the C11-261 groups step, reference `docs/groups-signoff.md` H1-H3, the human part; the automated runner was an agent's job.
- **Fold in Rehearsal B's wording fixes** (`build-remote/rehearsal-b/RESULTS.md`, "Wording fixes"): step 16 uses existing terminal areas; step 21 names Control+Command+W and says what to expect.
- **Known issues box**: tab:454 is triaging steps 16, 20 and 21 as product bug or wording. Leave a short "Known issues" section with a placeholder line; the Orchestrator fills it in.
- **Failure marking**: one line at the top. A failure gets "FAIL: <what you saw>" next to the step; that is all he does.
- No personal home paths (use `~`), no em-dashes, short sentences, plain English. Target: Atin finishes in about 45 minutes.

Time-box 45 minutes. When done, wait until `git log origin/c11-1.0/C11-292-signoff` shows tab:454's push (check every few minutes; if it has not pushed by the end of your box, commit anyway). Rebase on it; your file wins any conflict in `docs/c11-1.0-signoff.md`. Push one commit. Then: `c11 send --workspace workspace:11 --tab tab:210 "HANDOFF C11-292W <head>" && c11 send-key --workspace workspace:11 --tab tab:210 enter`.
