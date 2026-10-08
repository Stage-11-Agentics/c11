# C11-329: Typing-path bug-sweep groups after 1.0 (B032, B049, B093, B148, B160, B018)

Typing-path bug-sweep groups deferred from C11-311 by Atin's ruling (2026-10-03): fix after 1.0, never in the 1.0 build. Groups: B032, B049, B093, B148, B160 (BACKLOG/sweep IDs in C11-311's comments). Each touches a typing-latency-sensitive path (see CLAUDE.md Pitfalls), so each needs a typing-latency measurement against main before and after. B093 stopped at the typing-path boundary with no PR (ev_01M3ZG18). Also includes B018, which C11-311 parked unmerged.
