# Review: C11-285 (add c11 rpc as a local raw socket call; P2), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-285** (P2). PR https://github.com/Stage-11-Agentics/c11/pull/524, head `02b1fc3ff3479887f5113740205385d2c0599f90`, base = merge-base with origin/main.
- Title `C11-285 Review Astra`. Actor `agent:astra-review-285`. Owner was Codex Sol.
- Plan `.lattice/plans/task_01M3X4FNHQ0075Q5Z5V5TXNK8F.md`; evidence `art_01M3XXVEX245DRRACW0X736D18` (17 Atlas tests, RPC/create fixtures). CI pending. The owner reports one additive CLI merge conflict where both behaviors were kept: confirm that.
- Focus: `c11 rpc <method> [json]` sends exactly one request to the local socket and prints the raw response; params JSON validated before sending; errors map to a non-zero exit; it adds no new socket method or bypass of auth/socket-control mode; works with --socket/env targeting like the other commands; documented; its registry feature enabled; tests behavioral.
- When done, send VERDICT and wait.
