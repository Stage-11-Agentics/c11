# C11-136: Land PR #212 — Grok Build as built-in agent type

External PR #212 (commit 75c0550, author Atin <atin@atin.me>, 2026-05-26) adds Grok Build as a first-class c11 coding agent. Operator cleared to merge 2026-06-12 pending deep review + modern rebase.

## Review outcome
High-quality, mechanical addition across the canonical agent surfaces. Full review recorded as a ticket comment. One real gap: the PR predates the conversation store, so it only wires resume into the deprecated `AgentRestartRegistry` fallback.

## Execution steps
1. **Worktree**: `git worktree add ../c11-worktrees/pr-212-land -b land/pr-212 origin/main`; provision submodules + GhosttyKit symlink.
2. **Port (preserve authorship)**: `git cherry-pick 75c0550` onto `land/pr-212`. Resolve conflicts (expect AgentRestartRegistry.swift + skill docs). Keep contributor commit intact.
3. **Modernize (follow-up commit, my authorship)**:
   - Add `Sources/Conversation/Strategies/Grok.swift` — `GrokStrategy`: fresh-launch-only capture (push/wrapperClaim, like Kimi/Opencode); `resume()` types `grok --always-approve --resume` for alive/suspended, skips placeholder/other states.
   - Register `GrokStrategy()` in `ConversationStrategyRegistry.v1`.
   - Add `Grok.swift` to pbxproj `c11` target membership.
   - Update `ConversationStrategyTests.testV1RegistryContainsTheFourKinds` (→ assert grok present) + add a grok resume test.
   - Keep PR's `AgentRestartRegistry.phase1` grok row (fallback parity).
4. **Build**: full Debug build green.
5. **Tests**: `c11-logic` scheme (DefaultAgentConfigTests grok test). Conversation strategy tests live in `c11Tests` (host) → run via `scripts/test-unit-local.sh -only-testing:c11Tests/ConversationStrategyTests` or defer to CI.
6. **Skills**: `scripts/sync-installed-skills.sh c11` (PR touches skills/c11).
7. **Localization**: `agentType.grok` = "Grok Build" → 6-locale pass in Localizable.xcstrings.
8. **Tagged validation**: `./scripts/reload.sh --tag pr-212-land`; verify grok in Settings → Default Agent / A-button, `c11 set-agent --type grok` round-trips, sidebar chip renders. Grok CLI binary may be absent — validate c11-side plumbing only, say so.
9. **Land**: push `land/pr-212`, open PR crediting #212 + author, merge when CI green, comment on #212 thanking contributor, close it.
10. **Lattice**: validation evidence (`--role validation`) → in_validation → pr_open → complete after merge.

Then re-fetch main and start C11-137 (#215) from the new tip.
