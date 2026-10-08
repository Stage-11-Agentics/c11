C11-322 complete. PR #562 squash-merged to origin/main as fbf5bbe88bd0b613ea576d6d21e97bcf2f39b0ba (merged at head 6b5e072aaf with --match-head-commit; main was 4 commits ahead with no overlap in the changed files, clean merge-tree, sandbox scripts byte-identical to the gated head). Upstream: overwatch 39d90b8 (seat.sh export-cred).

Proof: validation (Atlas guest, Claude and Codex C11-257 sign-off steps 3-8 inside one Tart clone, Hyperion idle; Grok login-only, quota) and validation r2 (SIGTERM and SIGINT during staging, default and inherited-ignored, each exit non-zero with the clone gone; teardown failure reported; rotation and scanner fail closed).

Review: Review 1 Astra FAIL (5) -> same-session verify FAIL (finding 1, inherited SIG_IGN) -> verify2 PASS at 6b5e072aaf. Review 2 Fable PASS at 1065c68e73 (normal-use bar); the +12-line delta to 6b5e072aaf was verified by Astra's verify2. Exact-head Atlas gate: compile=ok (scripts/docs only, tests n/a). Installed c11-computer-use skill synced from main.

Follow-ups: C11-326 (including the Grok mail rerun after the Oct 6 reset).