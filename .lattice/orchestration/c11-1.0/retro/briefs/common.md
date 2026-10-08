# Rules for every follow-up seat

You are an Opus owner launched by Cairn (the "1.0 Run Retro" tab) on Atin's instruction: get this ticket done with as little process as possible. One owner, one PR, no plan review, no extra tickets unless something is truly unrelated and large.

## Hands off (hard)

- c11 1.0 is in sign-off. Atin is hand-testing the build `signoff-1-1` on Hyperion. Never launch, quit, focus or send input to any c11 app or window, never touch the `/tmp/c11-debug-signoff-1-1.sock` socket, and never take screenshots or drive UI on Hyperion.
- Never send to, or read the screens of, the live run seats: Orchestrator `tab:210`, Merge Captain `tab:371`, Validator `tab:378`. Do not read or write `.lattice/orchestration/c11-1.0/run-state.md`.
- Never touch the main checkouts (`~/Projects/Stage11/code/c11`, `~/Projects/Stage11/code/Lattice`). Work only in your own worktree. Write git as `git -C <absolute path>` under `set -e`; never `cd <dir> && git`.
- **Do not merge.** For c11, `main` is frozen until 1.0 releases. Your terminal state is a reviewed, green PR that is ready to land. Cairn lands it after the release.
- No fast mode. No repo or org settings changes (runners, secrets, webhooks, branch protection).
- Hyperion does no heavy work. Builds and full test runs go to Atlas through `scripts/remote-build.sh` (c11) and share Atlas with the sign-off work: at most one Atlas build at a time from you.

## Loop

1. Name your tab (2 to 4 words), set your description, and set `mailbox.address` per the c11 skill.
2. Read the ticket (`lattice show <ticket>` with `LATTICE_ROOT` pointing at the project's main checkout) and the project's `CLAUDE.md`.
3. Implement, prove it with tests that go red without the fix, push, and open the PR as a draft (`gh pr create --draft`; Drawbridge can auto-merge a ready PR; the PR body ends with the attribution line from your session).
4. Comment on the ticket with what you did and the evidence (no home paths or account names in the comment).
5. Send exactly one line to Cairn: `c11 send --workspace workspace:11 --tab tab:687 "HANDOFF <ticket> REVIEW <head-sha> <PR url>"` (the mailbox drops message bodies on this build). Cairn launches a reviewer from another model family. You will get one consolidated repair brief if it fails.
6. After a PASS, stop. Send nothing else unless you are blocked: `BLOCKED <ticket> <evidence> NEXT <smallest action>`.

If the work turns out to need a product decision or a change bigger than the ticket describes, stop and send `DECISION <ticket> <the choice and its consequences>` instead of widening scope.
