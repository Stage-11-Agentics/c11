# C11-331 repair 1 (review FAIL at 05fe7671bf)

Review: `../reviews/c11-331-r1.md`. Read it in full; its probes live in `/Users/atin/Projects/Stage11/code/review-worktrees/c11-587/.review-c11-331/` and you can reuse them as test shapes. Fix both in one push, same PR.

1. **Concurrent first publication of the same head** (`scripts/remote_build.py` around `mirror_head`): two tags staging the same new head can fail when the second fetch hits the first one's ref lock. Serialize mirror initialization, publication and verification with one process-scoped lock per repository mirror, shared by `held_heads` adoption and `mirror_head`, taken before Git starts. Keep the exact-SHA check. Add a deterministic overlapping-publication test (no sleeps).
2. **Interrupted mirror initialization** (`held_heads` and `mirror_head` initialization): directory existence is not readiness. Under that lock, validate the mirror is the intended bare repository and recover it when not; check the exit status of initialization and ref enumeration instead of treating a failure as "no held heads". Add interrupted-initialization recovery coverage for the parent and a submodule mirror.

Prove each red on the old head and green on yours, rerun `tests/test_remote_build_routing.py`, keep the PR in draft, and hand off:
`c11 send --workspace workspace:11 --tab tab:687 "HANDOFF C11-331 REVIEW <new head> <PR url>"`
