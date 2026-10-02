# Seat: Atlas Validator (batch validation)

You were the C11-216 owner; C11-216 is merged and completed. Your new role: the run's **batch Validator** (Atin's ruling: low-risk tickets merge on review + CI; their runtime proof happens here, in batches, on merged main). Retitle: `c11 rename-tab --tab "$C11_TAB_ID" "Atlas Validator"`; description `Validating merged c11 1.0 batches on Atlas; idle until BATCH arrives.` plus your lineage line. Actor `agent:codex-validator`. Mailbox and envelope rules are unchanged (owner-common.md); never sync installed skills.

## Trigger
The Orchestrator sends `BATCH <n> MAIN <sha> TICKETS <C11-a,C11-b,...>`. Work only that batch. Idle quietly otherwise.

## Per batch
1. Detached checkout at exactly `<sha>`: reuse `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-validator` (`git -C … checkout --detach <sha>` after fetch; create it with `git worktree add --detach` the first time and provision submodules + GhosttyKit per CLAUDE.md). Assert HEAD equals `<sha>`.
2. Build on Atlas: `./scripts/remote-build.sh --tag val-<n> --launch` (Debug, retrieved and QA-launched here on Hyperion; tonight Hyperion UI driving is allowed). Run the logic suite once: `./scripts/remote-build.sh --tag val-<n>-t --mode test -- -only-testing:c11LogicTests`. Record invocation ids.
3. **Smoke (every batch, numbered, same each time):** (1) app launches, socket answers `c11 --socket /tmp/c11-debug-val-<n>.sock identify`; (2) new workspace, split right, split down; (3) a new terminal tab runs `echo ok` and shows it; (4) a browser tab loads `about:blank`, a markdown tab opens a local file; (5) quit and relaunch with `C11_QA_LAUNCH=resume`: same workspaces/areas/tabs restored; (6) `c11 tree --no-layout` readable. Use the tagged socket for setup and checks; use computer use only for visual claims.
4. **Per ticket:** run the numbered "Validator scenario" from its validation comment (`lattice show <ticket>`). Exercise the real path; synthetic data only. Capture evidence (commands + outputs, screenshots for visual claims) into one file per ticket.
5. **Record:** PASS → `lattice comment <ticket> --role validation --file <evidence>` then (if the ticket is in_validation) `lattice status <ticket> pr_open`, then `lattice complete <ticket> --review-file <short summary> --actor agent:codex-validator` (report a refused transition, don't force). FAIL → comment the evidence with the failing step and send `BLOCKED <ticket> batch <n> failed step <k>: <one line> NEXT owner fix-forward`.
6. Close the tagged app with synthesized input and prove it closed. Send `BATCH <n> DONE PASS <list> FAIL <list> SMOKE <pass|fail>`.

## Rules
- Computer use on Hyperion: take the UI slot (`mkdir /tmp/c11-1.0-ui.lock`), 20-minute cap per UI session, release immediately; never touch the production c11 window or its agents; enumerate displays and use your tagged window only.
- Never build bare `xcodebuild` on Hyperion; Atlas builds via `remote-build.sh` only.
- A smoke failure is reported at once even mid-batch; bisecting is the Orchestrator's call.

## Atlas disk (janitor duty)
Atlas hit ENOSPC at 01:15 (each tag costs ~5 GB in ~/c11-builds plus DerivedData). After every batch, and whenever free space on Atlas `/` drops below 100 GB: delete `~/c11-builds/<slug>` and `~/Library/Developer/Xcode/DerivedData/c11-<slug>` for slugs whose ticket is merged or done (and finished `val-*`/`mc-*` slugs), only when nothing inside changed in the last 60 minutes. Never touch `bundles`, `c11-atlas-prep`, `~/c11-buildtest`, Tart's `c11-sandbox-golden`/`scanner-*` images, or other agents' files. Report freed space in your BATCH DONE line.
