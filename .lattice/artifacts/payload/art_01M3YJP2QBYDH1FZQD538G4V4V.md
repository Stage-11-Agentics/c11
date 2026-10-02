MERGED; reviewed runtime/validation evidence accepted
C11-314 / PR #532: https://github.com/Stage-11-Agentics/c11/pull/532
Landing head: d1d6cee460baa0c913832709c5af4142bb4ab029
Squash merge: 9f2173320a9dac428edaef1512dc0271b766802a
Base immediately before merge: 12d4f21a8822a3a7763d3a26b5295d8f6213c60a
GitHub MERGED verified; fetched origin/main contains the merge. Dependencies done; intended diff has 3 files, no Lattice noise. No behind-only Captain rebase.
Review: ev_01M3YJ5VVYRDB2VSFA4WGFK20F
Validation: ev_01M3YJ0W4XF10KEMTHGN5KZ7D0
Every non-skipped exact-head hosted check SUCCESS (build, compatibility, workflow guards, daemon, web, GhosttyKit, and any mailbox/Python checks). Draft Drawbridge SKIPPED. Snapshot and URLs: /tmp/c11-pr532-before-merge.json.
Exact-head Astra PASS ev_01M3YJ5VVYRDB2VSFA4WGFK20F; validation ev_01M3YJ0W4XF10KEMTHGN5KZ7D0. Three intended test files only, two ticket commits, no product/project/skill/submodule changes or Lattice noise; no dependencies or Captain rebase. Actual merge-tree is clean.
Captain read retained exact-head test result and log for invocation dd4150de5e2b4f40926b888f4e7c2654: compile=ok tests=ok, dirty=false overlay=[], only -only-testing:c11LogicTests, no -skip-testing flags. Executed 2384 tests with 3 intrinsic skips, zero failures, TEST SUCCEEDED; 2381 actual passing cases. Password-store class executes 8 tests, remote-connection class 2, messages class 11. Build log SHA-256 b0443c0d2387c19f5ebe7fda3fbe901c4325d6206081e185d30fa4226e54c434. Earlier deletion-only invocation failed password-file cases and is not relabeled green. No Captain test repeat or UI gate required for this test-only ticket.
Clarification: WorkspaceRemoteConnectionTests is not gone. Its four recorded flaky cases and unused helper/import are gone; deterministic relay-start refusal and SSH-environment tests remain. The messages steady-traffic timing case is deleted; eight password-store tests remain with absent-file fixture isolation. Deleted behavior-specific coverage has no existing deterministic replacement, as explicitly disclosed and accepted in the review.
After this merge, Captain build worker logic gates run both retained classes without the old class exclusions. The former remote-connection and password-store skips and historical flake landing waivers are retired; failures require ordinary diagnosis and owner repair. User explicitly authorizes ticket completion on this full logic proof. No installed-skill changes.
No Captain local build/test/app launch, release, tagging or publication.