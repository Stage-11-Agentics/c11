# Validator (Claude Sonnet, rollover): close the validation queue fast

Atin's ruling (2026-10-02): validation was too slow. No new harnesses, no VMs, no builds unless one command proves a specific gap. Time-box: the whole pass within 60 minutes.

Read `/tmp/c11-validator-handover.md` (the parked Codex Validator's per-ticket state) and `owner-common.md` for the mailbox (Orchestrator tab:210, workspace 8D68EE13-823E-44FF-B2DE-611FFD7BDA7F). Actor `agent:sonnet-validator`. Rename your tab `Validator Sonnet`.

For each ticket in `in_validation` (264 265 269 274 275 276 277 280 282 283 286 289 297):
1. Collect the runtime evidence that already exists: the owner's pre-merge validation comments (Atlas tagged-build runs, packaged UI passes, guest runs, tests_v2 runs), the reviewer's independent reproductions, the Merge Captain's exact-head gate, and the parked Validator's passed checks (shared build 89d2, logic suite, socket/CLI fixtures).
2. Compare it with the ticket's acceptance criteria.
3. Covered: post `lattice comment <ticket> --role validation --file <summary>` listing each criterion with the evidence id that covers it, then `lattice status <ticket> pr_open --actor agent:sonnet-validator`, then `lattice complete <ticket> --review-file <summary> --actor agent:sonnet-validator`.
4. A real gap that only a human-visible run can close: append one numbered step (setup, action, expected result, ticket id) to `.lattice/orchestration/c11-1.0/signoff-additions.md` for the C11-292 sign-off script, name that routing in the summary, then complete the ticket the same way.
5. Evidence that contradicts the criteria (a failing check): do not complete; send `BLOCKED <ticket> <evidence> NEXT owner fix-forward` to tab:210.

C11-291 and C11-311 stay open: record a validation comment only. When done, send one line to tab:210: `VALIDATION DONE completed <list> routed-to-signoff <list> blocked <list>`.
