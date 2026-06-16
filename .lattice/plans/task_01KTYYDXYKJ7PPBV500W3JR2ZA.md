# C11-137: Land PR #215 — GitHub Copilot CLI as built-in agent type

External PR #215 (commit 81123c0, author MdMxMyr <maxmeyer@live.nl>, 2026-05-29) adds GitHub Copilot CLI as a built-in agent type + ships `Resources/bin/copilot` session wrapper. Operator cleared to merge 2026-06-12 with extra-scrutiny flag (external author). Rebases AFTER C11-136 (#212/grok) merged.

## Review outcome (recorded as ticket comment)
Swift is clean, mirrors the grok pattern. **Wrapper audit PASSED**: `Resources/bin/copilot` is PATH-scoped (gated on `CMUX_SURFACE_ID` + live socket), makes NO persistent writes outside c11's runtime (only `c11 set-agent` over the socket), clean fall-through to real binary, minimal capture (no session-id — copilot lacks `--session-id`), kill switch `CMUX_COPILOT_HOOKS_DISABLED`. Idiomatic, matches the codex/claude sibling wrappers (incl. CMUX_* naming). No security concerns.

## Execution steps
1. **Worktree** off NEW main (post-#212, includes grok): `git worktree add ../c11-worktrees/pr-215-land -b land/pr-215 origin/main`; provision submodules + GhosttyKit symlink.
2. **Port (preserve authorship)**: `git cherry-pick 81123c0`. Resolve conflicts — expect them in AgentType enum, canonicalTerminalTypes, AgentChip (grok now adjacent), CLI valid list, AgentSkillsView, SkillInstaller, DefaultAgentConfigTests, api.md, metadata.md. Keep contributor commit intact.
3. **Verify wrapper +x bit** survives (`Resources/bin/copilot` mode 100755).
4. **Modernize (follow-up commit, my authorship)**:
   - Add `Sources/Conversation/Strategies/GitHubCopilot.swift` — fresh-launch-only (copilot has no `--session-id`; `/resume` is in-session). Register in `ConversationStrategyRegistry.v1` + pbxproj.
   - Update `ConversationStrategyTests` registry assertion + add a copilot test.
5. **Localization**: `agentType.githubCopilot` = "GitHub Copilot" → 6-locale pass.
6. **Build**: full Debug build green.
7. **Tests**: `c11-logic` (DefaultAgentConfigTests). Gate pbxproj on `xcodebuild -list` + membership counts (gem-normalization bloat expected), not line-by-line.
8. **Skills**: `scripts/sync-installed-skills.sh c11` if skills touched (#215 touches api.md/metadata.md).
9. **Tagged validation**: `./scripts/reload.sh --tag pr-215-land`; verify github-copilot in default-agent set/get, set-agent round-trip canonical, chip resolves (paperplane.fill fallback). Copilot binary may be absent — validate c11-side plumbing + that bundled wrapper is executable; say so.
10. **Land**: push, open PR crediting #215 + author, merge when CI green, comment+close #215 with thanks, complete C11-137.
