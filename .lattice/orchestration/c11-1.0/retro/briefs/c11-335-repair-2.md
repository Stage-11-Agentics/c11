# C11-335 repair 2 (review FAIL at e3053fba38)

Review: `../reviews/c11-335-r2.md`. The normal path is verified (tip resolution, recorded green on the tested SHA, benchmark skip, green proof run 37395038191). One blocker left:

1. **No silent fallback to the triggering commit.** `scripts/ci-backstop-target.sh:28-45`: when the ref API fails, returns malformed JSON, or returns no valid SHA, the script currently substitutes the triggering SHA, which can skip or build a stale commit. Fail target selection instead (non-zero exit, no `sha`/`tested` outputs, a clear log line). Keep "status lookup unavailable means build" only after a real tip has been resolved. Replace the test expectations at `tests/test_ci_backstop_target.sh:92-97` that endorse the fallback, add the "older trigger already green, tip lookup fails" negative case, and say in the docs that a ref-lookup failure fails the run while a green-record lookup failure builds.
2. **Attachment-test diagnosis** (open, separate): finish it and put the conclusion in your handoff. The reviewer's data: the failing run logged `attach-to-launch=3.06 s`, the passing run `1.26 s`.

One push, keep draft, hand off as before. This is round 3: the reviewer verifies only these two items.
