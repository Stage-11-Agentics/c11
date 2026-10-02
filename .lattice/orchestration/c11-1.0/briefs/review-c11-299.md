# Review: C11-299 (restore a session that contains a duplicate tab id), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-299**. PR https://github.com/Stage-11-Agentics/c11/pull/499, branch `c11-1.0/C11-299-duplicate-restore`, head `45b86a521b7d9336cab8c4297591aaf2fe9a4ccc`, base origin/main merge-base.
- Title `C11-299 Review Sol`. Actor `agent:codex-review-299`. Owner was Astra.
- Plan `.lattice/plans/task_01M3X6K24XNY2WNJD2515MNN5E.md`; validation comment `ev_01M3XE7TC4K9135MA03B5RZJDM`.
- The Atlas relaunch/visual proof is not done yet (Atlas route not live). Review the code and tests now; list exactly what that Atlas proof must show under "Runtime proof still required". Its absence alone is not blocking for this verdict.
- Focus: restore never crashes on a duplicate tab id from a real or synthetic snapshot; the dedupe keeps every distinct tab's content and does not drop or merge the wrong one; persistence/snapshot code stays off hot paths; tests are behavioral.
