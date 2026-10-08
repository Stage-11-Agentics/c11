# Retro follow-ups (Cairn, tab:687)

Held until 1.0 releases: c11 PRs stay draft; Cairn lands them (gh pr ready, then squash with --match-head-commit) after C11-293.

| Ticket | PR | Owner tab | Reviewer tab | State | After merge |
|---|---|---|---|---|---|
| C11-331 incremental staging | c11#587 | (closed) | (closed) | MERGED 4785de26f9, completed | sync-installed-skills.sh c11-hotload; delete Atlas ~/c11-builds/bundles once unused |
| C11-332 un-quarantine tests | c11#588 | (closed) | (closed) | MERGED 3fdb7e2317 (attested rebase 859d3210f2, Atlas green), completed | — |
| C11-335 CI backstop | c11#589 | (closed) | (closed) | MERGED 1edebf8d27 (attested 86584a6d91, proof 37534378879 green), completed; workflow re-enabled; pi/grok/kimi/opencode skill copies synced | gh workflow enable ci-hourly.yml; sync installed lattice-orchestrator copies (list in PR body) |
| LAT-395 review lifecycle | lattice#147 (base v2) | 969 | (closed) | MERGED f3eb00ebf3; LIVE in 0.2.3 (8b1273d) on Hyperion, Atlas client and hosted server | after release: `lattice migrate validation-done` on the c11 board, commit the config |
| LAT-420 auto-review off by default | lattice#148 (base v2) | 969 | (closed) | MERGED bb55cbc17a; LIVE in 0.2.3 | — | merge on PASS (not frozen); then auto-review-default PR |

Paused: `ci-hourly.yml` disabled (gh workflow disable) until C11-335 lands.

Incident 2026-10-06 00:28 UTC: LAT-395 reviewer tests wrote into Lattice's live board. Cleaned: workflow.review_cycle_limit removed (was set to 1), two "{not json" lines dropped, LAT-397..418 erased except LAT-402 (LAT-396 and LAT-402 were archived by the tests). Backups in the session scratchpad. Guard filed as LAT-419.

Landing owner for sign-off follow-ups: the 1.0 Driver (tab:966). Cairn waits for its "released" line before landing #587/#588/#589.

2026-10-06: Atin approved landing now (no wait for release). Driver (tab:966) has nothing in flight.
Gotcha: moving a c11-board ticket to planned auto-fired a plan-review (board still inherits auto-review on); killed pid 91540. Use --no-auto-review on every transition here until the board is migrated.

2026-10-06 22:00Z: all three c11 follow-ups merged and completed. Deferred until the Driver reports 1.0 released (release-local-v1-0-0 build running on Atlas): prune ~/c11-builds/bundles on Atlas (12 GB, old-script cache; never module-* while a build runs), and `lattice migrate validation-done` on the c11 board + commit config.json alone.

Closed out after v1.0.0 tag: c11 board migrated (in_validation -> done) and committed alone as da0c104934 on main; Atlas ~/c11-builds/bundles pruned (no builds running; Atlas free space 26 -> 33 GiB, still low). All follow-ups done.
