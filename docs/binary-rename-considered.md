# Binary Rename (cmux → c11mux): Considered, Declined

**Date:** 2026-04-17
**Status:** Not proceeding. Current thin-fork boundary is retained.
**Context:** PR #2 (`features/c11mux-1-8`) in flight. The app bundle, bundle ID, sockets, display name, Sparkle feed, and Homebrew cask already carry the `c11mux` identity. The executable inside the bundle, the Swift target, source filenames, schemes, `CMUX_*` env vars, and the CLI source `CLI/cmux.swift` still carry the `cmux` name.

## Decision

**Do not rename the binary or any of the remaining internal `cmux` identifiers.** Keep the line exactly where it is today:

- User-facing surfaces → `c11mux` (already done).
- Upstream-compatible code-facing surfaces → `cmux` (keep).

This matches the posture codified in [`docs/upstream-sync.md`](upstream-sync.md): c11mux is a surface-only rename fork of `manaflow-ai/cmux`, diverging only on app-identity files.

## Why

The fork's value proposition is *"manaflow-ai/cmux's engineering + Stage 11's identity and extensions."* Upstream is actively shipping improvements (notably in the browser surface) and we want those for free. Every internal identifier we rename turns a future routine `git merge upstream/main` into a 3-way conflict on the file upstream is most likely to have edited — `CLI/cmux.swift`, `Sources/cmuxApp.swift`, `cmux-Bridging-Header.h`, the schemes, the shell-integration files.

The residual "collision" after the current rename is purely aesthetic: `ls /Applications/c11mux.app/Contents/MacOS/` shows a file named `cmux`. Nobody looks at that. `which cmux` only collides when both casks are installed side-by-side, and `conflicts_with cask: "cmux"` in `homebrew-c11mux/Casks/c11mux.rb` already prevents that.

## Dismissed concerns that would have argued for a rename

During the evaluation, several rename-favoring arguments were raised and explicitly set aside:

- **Muscle memory for `cmux` in PATH** — not a concern; no backcompat shim needed.
- **Human code legibility of mixed naming** — not a concern; the code surface is maintained by agents.
- **Existing users migrating across a rename** — not a concern; the fork is brand new, no users yet.
- **Setting a clean precedent for a new fork** — acknowledged, but subordinate to the sync-tax concern below.

## The concern that decided it

We want to keep pulling upstream. Upstream is active, especially on browser work. A full rename adds recurring merge-conflict tax on every sync, proportional to how much upstream edits the renamed files (which is: a lot). The 80/20 partial rename (executable-name-only) would eliminate the PATH collision, but the collision is already eliminated by `c11mux.app` + the Homebrew `conflicts_with`. So even the 80/20 buys nothing meaningful against the current state.

## Follow-up: one doc drift worth fixing

`docs/upstream-sync.md` currently claims a `C11MUX_SHELL_INTEGRATION` env gate exists alongside `CMUX_SHELL_INTEGRATION`. It does not — no file in `Resources/shell-integration/` sets it. Either:

1. Add it additively as an alias (read-only mirror of the `CMUX_*` gate), or
2. Correct the doc to reflect that only `CMUX_*` exists.

Flagged for a separate, small commit. Does not change the rename decision.

## Conditions under which this decision should be revisited

- Upstream drift grows large enough that we're already re-rolling on every sync (i.e., we've *de facto* hard-forked). At that point the sync tax is already paid, and full internal consistency becomes free.
- Concrete user- or operator-facing friction from the mixed naming emerges (support questions, confusion in logs, a tool that breaks because it assumed `CFBundleExecutable == CFBundleName`).
- A compelling reason to allow parallel install of upstream `cmux` and our `c11mux` without cask conflict (non-Homebrew install paths become a supported workflow).

Absent those triggers, revisiting is not scheduled.

---

## Appendix: inventory and plan-that-wasn't

Preserved below for future re-evaluation. This is the scoping work done on 2026-04-17 under `/tmp/binary-rename-plan.md`. Treat as a snapshot — file counts and line numbers will drift.

### Inventory

**Xcode project (`GhosttyTabs.xcodeproj/project.pbxproj`).** `EXECUTABLE_NAME = cmux` at Debug (line ~959) and Release (line ~1001). `PRODUCT_NAME = "c11mux DEV"` / `c11mux` for the app; `PRODUCT_MODULE_NAME = cmux_DEV` / `cmux`. CLI target named `cmux-cli` with `PRODUCT_NAME = cmux`. `TEST_HOST` references `c11mux DEV.app/Contents/MacOS/cmux` and `c11mux.app/Contents/MacOS/cmux`. Bridging header `cmux-Bridging-Header.h`. Entitlements file `cmux.entitlements`. AppleScript definition `cmux.sdef`. Test target directories `cmuxTests/`, `cmuxUITests/`.

**Package.swift.** `name: "cmux"`, `.executable(name: "c11mux", targets: ["cmux"])`, `.executableTarget(name: "cmux", path: "Sources")`. Source path still `Sources/` with `cmuxApp.swift` as the `@main` file.

**Schemes.** `cmux.xcscheme`, `cmux-unit.xcscheme`, `cmux-ci.xcscheme`. Every CI workflow and helper script invokes `xcodebuild -scheme cmux`.

**CLI source.** `CLI/cmux.swift` (14,788 LOC, 418 `cmux` occurrences). Welcome text ASCII logo at line ~11956 spells `c m u x` via color-ramped box characters. Help header at line ~12273 reads `cmux - control cmux via Unix socket`.

**App source.** `Sources/cmuxApp.swift`. Window identifiers `cmux.settings`, `cmux.about`, `cmux.menubarDebug`, `cmux.backgroundDebug`, etc. AppStorage keys `cmuxWelcomeShown`, `cmuxPortBase`, `cmuxPortRange`. Argument name `-cmuxUITestLaunchManifest`. About-dialog already reads `c11mux` + "A Stage 11 Agentics fork of cmux by manaflow-ai".

**Sockets (already migrated).** `Sources/SocketControlSettings.swift` uses `c11mux-*.sock` everywhere: stable `~/Library/Application Support/c11mux/c11mux.sock`, debug `/tmp/c11mux-debug.sock` / `/tmp/c11mux-debug-<tag>.sock`, nightly `/tmp/c11mux-nightly.sock`, staging `/tmp/c11mux-staging.sock`. Upstream stable cmux uses `/tmp/cmux.sock` — no collision.

**Shell integration.** `Resources/shell-integration/cmux-{zsh,bash}-integration.{zsh,bash}` plus `.zshenv` / `.zlogin` / `.zprofile` / `.zshrc` (~195 refs across 6 files). Env-var namespace: `CMUX_SHELL_INTEGRATION`, `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `CMUX_TAB_ID`, `CMUX_PANEL_ID`, `CMUX_SOCKET_PATH`, `CMUX_SOCKET_PASSWORD`, `CMUX_BUNDLE_ID`, `CMUX_TAG`, `CMUX_AGENT_{TYPE,MODEL,TASK,ROLE}`, `CMUX_OPEN_WRAPPER_*`, `CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD`, `CMUX_GHOSTTYKIT_CACHE_DIR`, `CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC`.

**Path shims.** `~/.local/bin/cmux` (user CLI), `~/.local/bin/cmux-dev` (reload.sh dev shim), `~/.local/bin/cmux-shims/{codex,opencode,kimi,claude}` (M4 TUI wrappers), `Resources/bin/cmux` (inside bundle), `Resources/bin/{claude,open}` (wrappers).

**Workflows and release.** `.github/workflows/{ci,release,nightly,test-e2e,test-depot,ci-macos-compat,update-homebrew}.yml`. Release artifact is already `c11mux-macos.dmg` per `release.yml`; `scripts/build-sign-upload.sh` still references `cmux-macos.dmg` and `homebrew-cmux/` (drift — worth tidying independently).

**Homebrew.** `homebrew-c11mux/Casks/c11mux.rb` — `app "c11mux.app"`, `binary "#{appdir}/c11mux.app/Contents/Resources/bin/cmux"`, `conflicts_with cask: "cmux"`, zaps both `c11mux` and `cmux` support/cache dirs.

**Docs and skills.** 20+ README locales (~32 refs each), `CHANGELOG.md` (173 historical refs, do not rewrite), `CLAUDE.md` (20), `docs/c11mux-*.md` specs, `skills/cmux/` (+ `references/{api,metadata,orchestration}.md`), `skills/cmux-browser/`, `skills/cmux-markdown/`, `skills/cmux-debug-windows/`. Global `~/.claude/skills/cmux*` are symlinks into this repo's `skills/`.

**Hotspots per `scripts/sync-upstream.sh`.** `Resources/Info.plist`, `README.md`, `CHANGELOG.md`, `Sources/SocketControlSettings.swift`, `Sources/AppDelegate.swift`, `Sources/cmuxApp.swift`, `Package.swift`, `GhosttyTabs.xcodeproj/project.pbxproj`, plus the prefix `Resources/shell-integration/`. A full rename would add `CLI/cmux.swift`, bridging header, entitlements, sdef, schemes, `cmuxTests/`, `cmuxUITests/`, `Resources/bin/{claude,open}`, and `Resources/Localizable.xcstrings` — roughly doubling the recurring conflict surface.

### Options considered

**Full rename.** Rename executable, Swift target, source filenames, schemes, test dirs, shell-integration filenames, user CLI, homebrew cask binary, welcome text, docs, and optionally env vars. ~8 commits, ~120 files, ~22 working hours, plus ~25 min/sync tax indefinitely.

**80/20 rename.** Flip only `EXECUTABLE_NAME` + the user CLI symlink + the welcome header string. ~1 commit, ~10 files, ~1 hour. No upstream-sync tax (pbxproj is already a hotspot; the one-line flip is absorbed by normal conflict resolution). Leaves Swift target, source filenames, schemes, tests, env vars, shell-integration untouched.

**No rename (selected).** Zero commits. Relies on `conflicts_with cask: "cmux"` to prevent dual-install via Homebrew. Accepts that `c11mux.app/Contents/MacOS/cmux` is named `cmux` internally as a non-user-facing artifact of the thin-fork posture.

### Recommendations that were considered and would apply if we ever revisit

- **Keep `CMUX_*` as the canonical env var namespace.** Never rename. Add `C11MUX_*` aliases additively if ever needed.
- **If renaming, land after PR #2 merges, not within it.** PR #2 is already large (30 commits, 162 files, 14,666 insertions) and CI is red. Do not bundle.
- **Post-sync rename helper.** If the full rename ever happens, write `scripts/post-upstream-sync-rename.sh` to reapply the curated rename diff after each `git merge upstream/main --no-commit`. Budget ~30 min/sync.
- **Skills stay named `cmux`.** `skills/cmux/` is a public API to the agent fleet. Rename contents (where about the product) but not the directory.
- **Keep `Resources/cmux.sdef` name regardless.** Renaming it breaks saved AppleScripts (`tell application "cmux"`).
