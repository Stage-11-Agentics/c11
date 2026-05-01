# Divergence Map

Areas where c11 has diverged from `manaflow-ai/cmux`. Used by `/upstream-triage` to decide skip vs attempt.

**Categories:**

- **`skip`** — never cherry-pick changes here. Will always conflict, low reward.
- **`careful`** — attempt the cherry-pick, but expect conflicts. Use the playbook patterns to resolve.

Seeded from `analyze-hotspots.sh` on 2026-05-01 (c11 had 251 unique commits over upstream merge-base `53910919`). Re-run periodically and prune.

---

## skip

Upstream changes here will conflict and the resolution is c11-specific or low-reward.

| Path / glob                     | Reason                                                              |
| ------------------------------- | ------------------------------------------------------------------- |
| `README.md`                     | c11-specific tone and project description.                          |
| `README.*.md`                   | c11-specific localized READMEs.                                     |
| `CHANGELOG.md`                  | c11 maintains its own release notes.                                |
| `TODO.md`                       | c11-only working file.                                              |
| `C11_TODO.md`                   | c11-only.                                                           |
| `CLAUDE.md`                     | c11-specific agent instructions.                                    |
| `AGENTS.md`                     | symlink to CLAUDE.md.                                               |
| `PHILOSOPHY.md`                 | c11-specific.                                                       |
| `PROJECTS.md`                   | c11-specific.                                                       |
| `LICENSE`                       | unchanged but not subject to upstream churn.                        |
| `NOTICE`                        | unchanged.                                                          |
| `CONTRIBUTING.md`               | c11-specific contributor flow.                                      |
| `homebrew-c11/**`               | c11-only homebrew tap; no upstream equivalent.                      |
| `.lattice/**`                   | Lattice (Stage-11 task system) is not present in upstream at all.    |
| `skills/c11/**`                 | c11-specific Claude Code skill.                                     |
| `skills/cmux/**`                | c11's wrapped cmux skill — diverged from upstream skill content.     |
| `.github/ISSUE_TEMPLATE/**`     | c11 issue templates.                                                |
| `.github/workflows/release.yml` | c11 release flow diverged (own version stream).                     |
| `.github/workflows/nightly.yml` | c11 nightly diverged (own bucket, own signing).                     |
| `.github/workflows/build-ghosttykit.yml` | c11-specific GhosttyKit build pipeline.                    |
| `.github/workflows/update-homebrew.yml`  | c11-only homebrew tap updater.                              |
| `vendor/bonsplit`               | Submodule pointer; c11 may track a different ref.                   |
| `.gitmodules`                   | Submodule URLs — c11 vendors differ.                                |
| `Sources/c11App.swift`          | Renamed from `cmuxApp.swift`. Upstream changes need path translation — see playbook entry "cmux→c11 rename". |
| `Sources/cmuxApp.swift`         | No longer exists on c11. Upstream changes here are handled via path translation, not direct cherry-pick. |
| `CLI/c11.swift`                 | Renamed from `cmux.swift`. Same path-translation rule.              |
| `CLI/cmux.swift`                | No longer exists on c11. Same as above.                             |

> Note: the four rename rows above are tagged `skip` because direct cherry-pick will fail or recreate stale paths. The actual upstream change still gets imported — via path translation. See `playbook.md` → "cmux→c11 rename".

## careful

Touched in c11's 251 commits. Cherry-picks will likely conflict; resolve by hand, with care.

| Path / glob                              | Why it's hot in c11                                              |
| ---------------------------------------- | ---------------------------------------------------------------- |
| `GhosttyTabs.xcodeproj/project.pbxproj`  | 48 c11 commits. Xcode project files conflict on every PR. Stage-11 Sentry, target IDs, file refs all differ. |
| `Resources/Localizable.xcstrings`        | 37 c11 commits, ~100k lines. String catalogs merge poorly; usually safe to take both sides and let Xcode regenerate. |
| `Resources/InfoPlist.xcstrings`          | Same family.                                                     |
| `Sources/AppDelegate.swift`              | 31 c11 commits — heavy customization.                            |
| `Sources/Workspace.swift`                | 25 c11 commits — c11 workspace persistence and surface logic.    |
| `Sources/ContentView.swift`              | 25 c11 commits.                                                  |
| `Sources/TerminalController.swift`       | 18 c11 commits.                                                  |
| `Sources/TabManager.swift`               | 15 c11 commits.                                                  |
| `Sources/GhosttyTerminalView.swift`      | 14 c11 commits.                                                  |
| `Sources/AgentSkillsView.swift`          | 10 c11 commits — c11 skills layer.                               |
| `Sources/SessionPersistence.swift`       | c11 claude-session-resume work (PR #89).                         |
| `Sources/SurfaceMetadataStore.swift`     | c11 surface metadata.                                            |
| `Sources/SkillInstaller.swift`           | c11 skills installer.                                            |
| `Sources/Theme/ThemeManager.swift`       | c11 custom theming. Most upstream theme PRs need adaptation.     |
| `Sources/Panels/**`                      | c11-built panel system (Markdown, Browser, Mermaid, PaneInteraction). Upstream has none of this. |
| `Sources/Update/UpdateViewModel.swift`   | c11 update flow routes to c11 release endpoint, not cmux.        |
| `Sources/WorkspaceLayoutExecutor.swift`  | c11 workspace layout work.                                       |
| `Sources/WorkspaceSnapshotCapture.swift` | c11 snapshot work.                                               |
| `Sources/WorkspaceApplyPlan.swift`       | c11 apply-plan work.                                             |
| `Sources/cmuxApp.swift` (legacy)         | Pre-rename file — see skip section above.                         |
| `CLI/cmux.swift` (legacy)                | Pre-rename file — see skip section above.                         |
| `.github/workflows/ci.yml`               | Shared CI but heavily customized by c11.                         |
| `.github/workflows/ci-macos-compat.yml`  | c11 customizations.                                              |
| `.github/workflows/test-e2e.yml`         | c11 customizations.                                              |
| `c11Tests/**`                            | c11 test target (renamed from cmuxTests).                        |
| `docs/socket-api-reference.md`           | c11 maintains its own copy with c11-specific notes.              |

---

## How to extend this file

When a triage run hits a SKIP-divergence or NEEDS-HUMAN that isn't represented here:

1. Add a row above explaining what about c11 makes upstream changes here troublesome.
2. Keep the reason to one line. Detail belongs in `playbook.md`.
3. Use globs over exact paths when the divergence is broad.

When a previously-skip area is no longer divergent (we caught back up, or the c11 customization moved), remove the row.

Re-run `scripts/analyze-hotspots.sh --top 80` quarterly to refresh.
