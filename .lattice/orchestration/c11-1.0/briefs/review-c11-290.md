# Review: C11-290 (smoke c11 ssh atlas and correct the API reference), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-290**. PR https://github.com/Stage-11-Agentics/c11/pull/520, head `688016659e5eb9ce436c473f2ddb23369921d11a`, base = merge-base with origin/main.
- Title `C11-290 Review Astra`. Actor `agent:astra-review-290`. Owner was Codex Sol.
- Plan `.lattice/plans/task_01M3X4FP1W7C1SERYV9M5B8T45.md`; validation `ev_01M3XT2QKPTQT18CA9W9HKJNFA`, artifacts `art_01M3XT0CTWVY5KDD3VS7G2R88X`, `art_01M3XT0CYDPRW7KF5PMZMT99YD`. Proof topology (Orchestrator-directed): tagged app on Hyperion, `c11 ssh atlas`, a listener bound to Atlas loopback only; a direct request from Hyperion fails (curl exit 7) and the same request succeeds through the remote proxy with a matching GET/body in the listener log (audit finding 10).
- Focus: the proof really demonstrates traffic through the remote side (not a local fallback); remote-to-local c11 commands are refused as shipped (#490); the API reference text matches the shipped behavior exactly and is timeless; bash/zsh bootstrap cases cover what the plan names; no credentials or private hostnames/paths in public evidence; tests behavioral.
- When done, send VERDICT and wait.
