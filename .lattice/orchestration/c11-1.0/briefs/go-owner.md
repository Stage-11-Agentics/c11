# c11 1.0 owner: BUILD MODE launch

Atin gave the go (2026-10-01). **Build mode is ON.** You are a fresh owner for one lane. Your planning-mode predecessor's work is durable: plans on the tickets, the lane worktree (keep every local commit; never reset, stash, clean or force), the briefs in this folder.

## Read first
1. `owner-common.md` (your contract). Where it says "planning mode", read "build mode": implement, validate, open the PR.
2. Your seat brief (named in your launch prompt). Use the title from your launch (`--title`) and the actor `agent:codex-<seat>` (Astra seats keep their brief's actor). Ignore any Grok wording in older briefs: this lane is Codex.
3. Your ticket (named in your launch prompt): `lattice show <ticket>` and its stored plan. Do not re-plan from scratch; fix only real errors and re-store any plan you change.

## Work one ticket at a time
- Branch per ticket from the fetched remote: `git fetch origin`, then in your lane worktree `git switch -c c11-1.0/<ticket>-<slug> origin/main` (or switch to the ticket's existing branch if one exists with useful commits). `lattice status <ticket> in_progress` and `lattice branch-link <ticket> <branch>`.
- Send `READY <ticket> CWD <abs worktree> HEAD <sha> BASE <origin/main sha>` once, then work. No acks expected.
- Implement the full cut line from the plan, commit as you go, push early. Push your branch freely (a bare branch push costs no macOS CI), but **open the PR only at handoff**, as a **draft** against `main` on `Stage-11-Agentics/c11` (it stays draft; the Merge Captain un-drafts it at landing). GitHub runs about 5 macOS jobs at a time for the whole repo and every push to an open PR queues about four workflows, so a PR opened early starves everyone's landings. If you already have an open PR mid-implementation, push only at handoff and repair boundaries.
- When the ticket is review-ready: validation evidence on Lattice (`lattice comment <ticket> --role validation --file …`), `lattice status <ticket> review --no-auto-review`, then `HANDOFF <ticket> REVIEW <head> <PR url> <lattice pointers>`. Wait for the Orchestrator: it sends one bundled repair brief or `NEXT <ticket>`. Do not start your lane's next ticket until it says `NEXT`.

## Validation flow (Atin, 2026-10-01: batch validation)
- **Default (low-risk tickets):** hand off for review once GitHub CI is green and your targeted tests pass. Runtime proof is NOT a per-ticket gate: an Atlas Validator seat builds merged main in batches and runs your ticket's acceptance scenario. Write that scenario as numbered steps with expected results in your validation comment ("Validator scenario"). If the batch finds a failure, you fix it forward on the same ticket.
- **Risk list (runtime proof before merge):** C11-294, 259, 260, 273, 295, 302, 303, 263, 298, and any change on the typing path (hitTest, TabItemView, forceRefresh, terminal input/focus). These owners prove their ticket on a tagged build before HANDOFF REVIEW.

## Builds and tests
- **Hyperion (this Mac) is allowed overnight** (Atin, 2026-10-01) for one locked build at a time: `scripts/reload.sh --tag <tag>` only (it holds the build lock; never bare `xcodebuild`, never an untagged DEV app), launch with `scripts/launch-tagged-automation.sh <tag> --qa fresh`. Computer use only on your own tagged app; never touch the production c11 window or its agents. Prefer Atlas once it is live.
- **Atlas builds are live** (C11-216 merged): build, test and launch tagged builds on Atlas through `scripts/remote-build.sh` (from C11-216; read `skills/c11-hotload/SKILL.md` on main). Tagged builds only, `C11_QA_LAUNCH` set. Computer-use validation runs on Atlas against your tagged build, never on Hyperion.
- **Performance:** the fleet soak (C11-270) is deferred to the end of the run (Atin). If your plan measures against "the soak baseline" or "M1", measure instead on your tagged Atlas build against a tagged build of origin/main with the same scenario, and record both numbers and the load average.

## Unchanged
Rulings final. Doctrine (no writes to agent tools' config). C11-188 guardrail. Hot paths. Localization via `String(localized:defaultValue:)` (the six-locale pass is C11-291). Disclosure (public repo: synthetic data only). Stay out of C11-257's files until it lands. Never touch the main checkout. No subagents outside Codex. Repair related findings in place; mint nothing without the Orchestrator.

**Fetch gotcha:** if `git fetch origin` fails with `nightly -> nightly (would clobber existing tag)`, run `git fetch origin '+refs/tags/nightly:refs/tags/nightly'` once (the nightly tag moves every night), then fetch again.

**CI queue:** GitHub's macOS runners are the shared bottleneck (every push runs a macos-15-xlarge build). Push at meaningful boundaries, not every commit, and cancel your own superseded queued runs (`gh run list --branch <your branch>`, `gh run cancel <id>`). A queued run with zero steps is congestion, not a blocker: do not send BLOCKED for it.

**Hyperion UI slot (one screen):** before any computer use on Hyperion, take the slot with `mkdir /tmp/c11-1.0-ui.lock && echo "<ticket> $$" > /tmp/c11-1.0-ui.lock/owner` (if mkdir fails, someone holds it: wait and retry every minute, read `owner`). Release with `rm -rf /tmp/c11-1.0-ui.lock` the moment your UI run ends, success or failure. Hard-cap each UI run at 20 minutes. Socket-only checks need no slot.

**Waiting on CI:** do not end your turn while your PR's checks are pending and you have nothing else to do: block on `gh pr checks <n> --watch --interval 60`, then act (HANDOFF when green, fix when red). An idle agent never wakes up on its own.

**Review does not wait for CI:** once your targeted checks pass and the branch is pushed, send HANDOFF REVIEW even if GitHub CI is still queued or running. The Merge Captain requires green CI at the exact head before landing; if CI then fails, fix it on the same ticket.

**Never sync or edit installed skills** (`~/.claude/skills/*`, `scripts/sync-installed-skills.sh`). Every agent on this Mac loads them; a pre-merge or hand-merged copy breaks them for the whole fleet (it happened: a spliced paragraph broke the c11 skill's frontmatter). Only the Merge Captain syncs, from merged main, after landing.

**Atlas VM guests (two slots, shared):** a Tart guest is a lease: 30-minute cap, delete the guest the moment your run ends (success or failure), and never start one while you are not actively driving it. If both slots are busy, wait with a bounded poll (every 2-3 minutes) instead of sending BLOCKED. Never run browser import against a real user's profiles; isolated guests only.

**UI slot reservation:** if `/tmp/c11-1.0-ui.reserved` exists, the Validator holds priority: do not take the UI slot (finish and release a lease you already hold) until that file is gone. The Validator removes it when its reserved runs end.

**One Atlas tag per ticket:** always build with the same tag, `c11-<ticket number>` (e.g. `--tag c11-303`), for every rebuild and test run, so Atlas holds one ~5 GB checkout per ticket instead of one per attempt. Delete any other tags you created (`ssh atlas 'rm -rf ~/c11-builds/<old-tag> ~/Library/Developer/Xcode/DerivedData/c11-<old-tag>'`) once their logs are retrieved.
- **Validator has Atlas VM priority.** macOS allows two guests at once. Before starting a guest, check Atlas for `/tmp/c11-validator-vm-wanted`; if it exists, do not start one (finish what you have, then wait or do non-VM work). The Validator creates that file when it is waiting for a guest and deletes it when its lease starts.
