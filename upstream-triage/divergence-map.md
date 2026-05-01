# Divergence Map

Where c11 has diverged from `manaflow-ai/cmux`. The agent uses this as prior knowledge: it knows where to expect adaptation work, and where upstream changes simply don't apply.

**Categories:**

- **`skip`** — there is no c11 equivalent. Upstream changes here have no home in c11. Don't try to land them, even via rewrite.
- **`adapt`** — c11 has its own version, often heavily customized. Upstream changes here likely need rewrite, not cherry-pick. Read the upstream intent, find the c11 equivalent, write the c11 version.

Seeded from `analyze-hotspots.sh` on 2026-05-01 (c11 had 251 unique commits over upstream merge-base `53910919`). Re-run periodically and prune.

---

## skip

No c11 equivalent. Upstream changes here are not landed.

| Path / glob                              | Why no c11 equivalent                                              |
| ---------------------------------------- | ------------------------------------------------------------------ |
| `homebrew-c11/**` and `homebrew-cmux/**` | c11 has its own homebrew tap; upstream's tap is irrelevant.        |
| `.lattice/**`                            | Lattice (Stage-11 task system) is c11-only.                        |
| `skills/c11/**`                          | c11-only Claude Code skill.                                        |
| `.github/ISSUE_TEMPLATE/**`              | c11 issue templates.                                               |
| `.github/workflows/release.yml`          | c11 has its own release stream and version scheme.                 |
| `.github/workflows/nightly.yml`          | c11 has its own nightly bucket and signing.                        |
| `.github/workflows/build-ghosttykit.yml` | c11-specific GhosttyKit build pipeline.                            |
| `.github/workflows/update-homebrew.yml`  | c11-only homebrew tap updater.                                     |
| `LICENSE`, `NOTICE`                      | Static files, c11 carries its own copies; not subject to upstream churn. |

**Note:** identity files (`README.md`, `CHANGELOG.md`, `CLAUDE.md`, etc.) used to be on this list. They've moved to `adapt` — when an upstream README change is meaningful (e.g. documenting a new feature c11 also imports), the agent should adapt the doc change to c11's voice and shipping equivalent. When the change is purely cmux branding, the adapt step is "skip the change, don't bring it over."

## adapt

c11 has its own version. Upstream changes here usually need rewrite. The agent reads upstream intent, finds the c11 equivalent, writes the c11-shaped change. Often the playbook has a relevant entry.

| Path / glob                              | What's different on c11                                            |
| ---------------------------------------- | ------------------------------------------------------------------ |
| `Sources/cmuxApp.swift` → `Sources/c11App.swift`  | Renamed entry point. See playbook: "cmux → c11 entry-point rename". |
| `CLI/cmux.swift` → `CLI/c11.swift`        | Renamed. Same playbook entry.                                       |
| `cmuxTests/**` → `c11Tests/**`            | Renamed test target.                                                |
| `GhosttyTabs.xcodeproj/project.pbxproj`   | 48 c11 commits — Stage-11 Sentry, c11 target rename, extra source files. See playbook: "Xcode project file changes". |
| `Resources/Localizable.xcstrings`         | 37 c11 commits, ~100k lines. Auto-merge poorly. See playbook: "String catalog changes". |
| `Resources/InfoPlist.xcstrings`           | Same family.                                                        |
| `Sources/AppDelegate.swift`               | 31 c11 commits — heavy customization (Sentry, lifecycle hooks).     |
| `Sources/Workspace.swift`                 | 25 c11 commits — c11 workspace persistence and surface logic.       |
| `Sources/ContentView.swift`               | 25 c11 commits.                                                     |
| `Sources/TerminalController.swift`        | 18 c11 commits.                                                     |
| `Sources/TabManager.swift`                | 15 c11 commits.                                                     |
| `Sources/GhosttyTerminalView.swift`       | 14 c11 commits.                                                     |
| `Sources/AgentSkillsView.swift`           | c11 skills layer.                                                   |
| `Sources/SessionPersistence.swift`        | c11 claude-session-resume work (PR #89).                            |
| `Sources/SurfaceMetadataStore.swift`      | c11 surface metadata.                                               |
| `Sources/SkillInstaller.swift`            | c11 skills installer.                                               |
| `Sources/Theme/ThemeManager.swift`        | c11 custom theming.                                                 |
| `Sources/Panels/**`                       | c11-built panel system (Markdown, Browser, Mermaid, PaneInteraction). Upstream has none of this. |
| `Sources/Update/UpdateViewModel.swift`    | c11 update flow routes to c11 release endpoint.                     |
| `Sources/WorkspaceLayoutExecutor.swift`   | c11 workspace layout work.                                          |
| `Sources/WorkspaceSnapshotCapture.swift`  | c11 snapshot work.                                                  |
| `Sources/WorkspaceApplyPlan.swift`        | c11 apply-plan work.                                                |
| `.github/workflows/ci.yml`                | Shared CI but customized.                                           |
| `.github/workflows/ci-macos-compat.yml`   | c11 customizations.                                                 |
| `.github/workflows/test-e2e.yml`          | c11 customizations.                                                 |
| `docs/socket-api-reference.md`            | c11 maintains its own copy with c11-specific notes.                 |
| `vendor/bonsplit`, `.gitmodules`          | Submodule pointer / URL divergence. See playbook: "Submodule pointer changes". |
| `README.md`, `README.*.md`                | c11 voice; adapt only when the upstream change is content-meaningful, not branding. |
| `CHANGELOG.md`                            | c11 release notes; adapt only when the change documents a feature c11 is also landing. |
| `CLAUDE.md`, `AGENTS.md`                  | c11 agent instructions; rarely need an upstream change.             |
| `CONTRIBUTING.md`                         | c11 contributor flow.                                               |
| `TODO.md`, `C11_TODO.md`                  | c11 working notes; upstream `TODO.md` changes are rarely meaningful. |

---

## How to extend this file

When a triage run hits an adaptation pattern that isn't represented here:

1. Add a row under `adapt` (or `skip` if there's truly no c11 equivalent).
2. Keep the reason to one line. Detail belongs in `playbook.md`.
3. Use globs over exact paths when the divergence is broad.

When a previously-listed area is no longer divergent (we caught back up, or the c11 customization moved), remove the row.

Re-run `scripts/analyze-hotspots.sh --top 80` quarterly to refresh.
