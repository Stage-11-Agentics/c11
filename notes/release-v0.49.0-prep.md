# Release v0.49.0 — Prep (drafted 2026-05-19)

Planning-only doc. Nothing here is committed yet. When the remaining inbound code change lands and you give the go, the "Go-time runbook" at the bottom converts this into a real release branch.

## Target

- **Marketing version**: `0.48.0` → `0.49.0` (minor bump, default policy)
- **Build version**: auto-incremented by `./scripts/bump-version.sh` (currently `102` → `103`)
- **Tag**: `v0.49.0` (annotated, per local git config)
- **Staging build identity**: `c11 STAGING` (`com.stage11.c11.staging`), produced by `./scripts/reloads.sh --tag <slug>` — runs side-by-side with prod.

## State to be aware of

- **Local `main` is 10 commits behind `origin/main`**. All overnight PRs (#174–#183) live on origin only. Need a `git pull --ff-only` (or rebase if the dirty tree should survive) before the release branch is cut.
- **Working tree is dirty**: `Sources/TabManager.swift` (~41 lines), `CLAUDE.md` (~1 line), plus the usual `.lattice/` churn. Per your direction, leaving it untouched until the agents finish.
- **More code coming**: the inbound change you mentioned is not yet on origin. Final changelog bullets get appended once that lands.

## Security threat-model recheck

Ran the canonical grep against `v0.48.0..origin/main`. Two files matched, both benign:

| File | What changed | Verdict |
|---|---|---|
| `Resources/Info.plist` | Added `com.splittabbar.tabitem` + `com.splittabbar.tabtransfer` UTType anchors mirroring upstream Bonsplit `UTType(exportedAs:)` declarations. No new URL handlers. | No threat-model change. |
| `Sources/SocketControlSettings.swift` | Pure rename `cmuxOnly` → `c11Only`. Localization keys kept stable; no new modes; no gating logic change. | No threat-model change. |

**`docs/security-threat-model.md` does not need an update for this release.**

## Draft `CHANGELOG.md` entry

```markdown
## [0.49.0] - YYYY-MM-DD

Stability + ergonomics release. Headline: **worktree + branch sidebar chips** make every workspace's git context visible at a glance, color-hinted so a worktree is never mistaken for the main checkout. Plus the long-running socket-unlink mystery (CLAUDE.md C11-105) is closed out: the c11 CLI socket now self-heals via a kqueue canary, no more "Socket not found at …" while the app is still alive. State-dir migration from c11mux gets a per-entry merge so mixed-state homes survive intact. Terminal links pick up an Opt+click escape hatch to the system browser. Update pill opens its popover on first click for background-detected updates instead of needing two.

### Added

- **Worktree + branch sidebar chips on every workspace.** The sidebar surfaces each workspace's current git branch alongside a worktree indicator, color-hinted so worktrees are visually distinct from the main checkout. The operator running parallel worktrees no longer has to read `cwd` to know which workspace is on which branch. ([#181](https://github.com/Stage-11-Agentics/c11/pull/181))
- **Opt+click on a terminal link forces the system default browser.** Adds an Option/Alt modifier override at the `GHOSTTY_ACTION_OPEN_URL` routing site so a single click can bypass `BrowserLinkOpenSettings` (cmuxBrowser default, host whitelist, regex patterns) and open externally. `Cmd+click` behavior unchanged. ([e45489764](https://github.com/Stage-11-Agentics/c11/commit/e45489764))

### Changed

- **State-directory migration is now per-entry, not blanket-copy.** Users with both a legacy `~/.c11mux/` state dir and a partial `~/.c11/` from earlier sessions used to get one or the other; the migration now merges entry-by-entry so neither side overwrites the other. ([#179](https://github.com/Stage-11-Agentics/c11/pull/179))
- **Default agent prompt now orients new sub-agents before the c11 skill loads.** Sub-agents launched into a c11 surface get a brief orientation pass (workspace/surface refs, role context) up front so the first turn isn't spent rediscovering the environment. ([#178](https://github.com/Stage-11-Agentics/c11/pull/178))
- **Update pill opens its popover on the first click for background-detected updates.** Previously a background-detected update required two clicks: one to "wake" the pill, one to actually open. Now opens directly on first click. ([ff2711b6d](https://github.com/Stage-11-Agentics/c11/commit/ff2711b6d))

### Fixed

- **CLI socket no longer goes unreachable while the app is still alive (C11-105).** Some shutdown paths in tagged debug builds were unlinking the prod `~/Library/Application Support/c11/c11.sock` path, leaving the live app interactive but every `c11 <cmd>` failing with `Socket not found`. A kqueue watcher now detects the unlink as a canary and the socket self-heals without needing the "Restart CLI Listener" command-palette workaround. ([#180](https://github.com/Stage-11-Agentics/c11/pull/180))
- **Bonsplit drag-and-drop UTTypes are now declared in `Info.plist`.** Resolves the runtime warning "Type was expected to be declared and exported in the Info.plist" emitted on every Bonsplit `UTType(exportedAs:)` construction. Cheap on Apple Silicon, expensive on shared-tenant CI runners — fix also unblocks a slow test that the warning storm was paging over its timeout. ([#182](https://github.com/Stage-11-Agentics/c11/pull/182))

### Built and shipped by

Stage 11 Agentics. Operator:agent, fused.
```

Categories audit:
- Skipped (internal-only): #174, #175, #176, #177, #183 (all C11-99 CI/test infra + AAR), `3246d82bf` notes, `50f6cb9ee`/`ef484b1c6` lattice churn, `fdbdc1cdd`/`19396e185` skill doc tweaks (no in-app surface).
- Pending: bullets for the inbound code change.

## Contributors

Single author across the diff: **@BenevolentFutures** (Atin). No external contributors. Following the v0.47.1 / v0.48.0 pattern of a single "Built and shipped by" byline rather than a `Thanks to N contributors!` section.

## Go-time runbook

When the remaining code change lands on `origin/main` and the tree is clean, this is the sequence. **Do not run any of this yet.**

```bash
# 0. Make sure the dirty tree is resolved (commit, stash, or discard the TabManager.swift + CLAUDE.md changes per direction).

# 1. Sync local main with origin (will fast-forward 10+ commits).
git checkout main
git pull --ff-only

# 2. Cut release branch from current main.
git checkout -b release/v0.49.0

# 3. Append the final inbound-change bullets to `notes/release-v0.49.0-prep.md`,
#    then port the [0.49.0] block from this prep file into CHANGELOG.md under [Unreleased].
#    Date stamp: today's date (YYYY-MM-DD).
$EDITOR CHANGELOG.md

# 4. Bump version (minor → 0.49.0; bumps build number too).
./scripts/bump-version.sh

# 5. Stage + commit.
git add CHANGELOG.md GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "Bump version to 0.49.0"

# 6. Push.
git push -u origin release/v0.49.0

# 7. **Before opening the PR**, build the tagged staging artifact for your hands-on test:
./scripts/reloads.sh --tag rel-v0.49.0
./scripts/launch-tagged-automation.sh rel-v0.49.0

# 8. After staging validation passes:
gh pr create --title "Release v0.49.0" --body "$(cat <<'EOF'
## Summary
Worktree+branch sidebar chips, CLI socket self-heal (C11-105), per-entry state-dir migration, Opt+click external-browser escape hatch, update pill popover ergonomics. Full notes in CHANGELOG.md.

## Test plan
- [ ] Staging build (c11 STAGING, `rel-v0.49.0`) exercised: open multiple workspaces with mixed branches/worktrees, confirm sidebar chips match git state.
- [ ] CLI socket survives a tagged-staging app shutdown + relaunch without manual "Restart CLI Listener".
- [ ] State-dir migration: clean install with both legacy `~/.c11mux/` and partial `~/.c11/` retains entries from both.
- [ ] Opt+click on a terminal link with `cmuxBrowser` default opens system browser.
- [ ] Update pill: with a background-detected update, single click opens the popover.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"

gh pr checks --watch

# 9. Once green, merge + tag + watch release workflow.
gh pr merge --squash --delete-branch
git checkout main && git pull --ff-only
git tag -a v0.49.0 -m "Release v0.49.0"
git push origin v0.49.0
gh run watch --repo Stage-11-Agentics/c11
```

## Open items waiting on you

1. The inbound code change (the "one more thing" the other agents are wrapping up) — once it lands on origin, append its bullets to the changelog draft above.
2. Disposition of the uncommitted `Sources/TabManager.swift` + `CLAUDE.md` diff in your local tree. Stash, commit, or discard before step 1 of the runbook.
3. Confirm the modifier-key memory: **Opt (⌥)**, not Control. Wording is consistent with the existing Cmd+click convention.
