# Seat: Browser SSH Grok

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Browser SSH Grok
- **Actor:** `agent:grok-browser`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-browser` (branch `c11-1.0/C11-287-webview-crash`, base origin/main `0ff8887e5e`)
- **Seat id for envelopes:** `browser`

## Queue (each ticket its own branch and PR)
1. **C11-287** replace a crashed web view on the next turn and stop forced layout (`webViewWebContentProcessDidTerminate`, around `Sources/Tabs/BrowserTab.swift:3515` on origin/main; verify).
2. **C11-288** smoke Chrome, Arc and Safari import on a tagged build (plan the smoke and the evidence; it runs in build mode on an Atlas-built tagged app).
3. **C11-290** smoke `c11 ssh atlas` after #490 and correct `skills/c11/references/api.md` (~line 431). Skill/doc text corrections you are certain of may be written now on that ticket's branch; the smoke runs in build mode. If you edit an installable skill, note that `scripts/sync-installed-skills.sh` must run after merge.

Never use your own browser sessions, cookies or real accounts in evidence; synthetic data only.
