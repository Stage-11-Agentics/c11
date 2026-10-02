# Review: C11-315 (hourly full CI on main + Atlas self-hosted runner for internal branches), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-315**. PR https://github.com/Stage-11-Agentics/c11/pull/537, head `129bc00875fd7601dc79bf63fd3371310490f633`, base = merge-base with origin/main.
- Title `C11-315 Review Astra`. Actor `agent:astra-review-315`. Owner was Codex Luna.
- Plan `.lattice/plans/task_01M3YH5C9N3DGBG42W4E07WRVA.md`; validation `ev_01M3YMD0AWF4HRBFVX7ETT2FN1`, scenario `ev_01M3YMF84Y5N43N9C5YBQH7TWF`, PR artifact `art_01M3YMDXXW10NQJQWVZ6CQ5YBJ`.
- Security first (the repo is public): no workflow path can schedule a job on the self-hosted Atlas runner from a fork PR, `pull_request_target`, `issue_comment` or any event an outsider controls; self-hosted jobs run only for push/schedule/workflow_dispatch on internal refs or same-repo PRs with an explicit guard; no secrets reachable from untrusted triggers; the runner's jobs respect Atlas's build lock/two-slot admission and cannot run `release.yml`.
- Then: full macOS CI runs hourly on main (schedule) and on demand; PR checks are fast and cheap; the GhosttyKit checksum flow for submodule bumps still works; Drawbridge unaffected; CLAUDE.md and the Merge Captain flow are updated truthfully (landing gate = Atlas exact-head gate; hourly main red = fix-forward); `latest` release slot and Sparkle feed untouched.
- When done, send VERDICT and wait.
