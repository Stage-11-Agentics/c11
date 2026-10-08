# Review: C11-301 (cap how many background workspaces mount at once), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-301**. PR https://github.com/Stage-11-Agentics/c11/pull/514, head `e6c893cd119730137808f0d2e2c5836799d83d67`, base = merge-base with origin/main.
- Title `C11-301 Review Sol`. Actor `agent:codex-review-301`. Owner was Codex Astra.
- Plan `.lattice/plans/task_01M3X6K2A53E4THPWD9W0M9ARP.md`; validation comment on the ticket (60-workspace switch/restore scenario for the batch). CI pending; the captain gates on it.
- Focus: background workspaces beyond the cap stay unmounted without losing state (terminals keep running, scrollback, agent status, notifications, flags still reach the sidebar); switching to an unmounted workspace mounts it promptly and correctly; restore of 50+ workspaces does not mount them all at once; selected and recently seen workspaces are preferred; the ContentView change is small and does not touch TabItemView equality or add body work on typing paths (C11-260 edits ContentView next); no focus stealing; tests behavioral.
- When done, send VERDICT and wait.
