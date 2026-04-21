# c11 ↔ upstream cmux coexistence: CLI-name and surface-brand policy change

**Status:** v2, revised after clear-codex and clear-claude reviews
**Reviews:** `/tmp/c11-cli-coexistence-codex-review.md`, `/tmp/c11-cli-coexistence-claude-review.md`
**Scope:** user-visible CLI name, skill installer surface, Homebrew cask, command palette, uninstall/install safety, welcome doc, CLI help strings, integrations menu
**Out of scope (explicit):** internal class/struct names (`CmuxCLIPathInstaller`, `CMUXCLI`, env var prefix constants), the socket protocol, the bundled env-mirror (`mirrorC11CmuxEnv`), the legacy `cmux install <tui>` integration-installer subtree's internal implementation (help strings for it ARE in scope)

## Motivation

c11 is a fork of upstream cmux (`manaflow-ai/cmux`). Under the prior plan, c11 kept `cmux` as a compat alias — but the reviews surfaced that the alias leaks in ways that break coexistence:

1. **CLI PATH installer** hardcodes `/usr/local/bin/cmux` (`Sources/AppDelegate.swift:1203`) — overwrites upstream's symlink.
2. **Shell integration prepends `Contents/Resources/bin` to PATH** (`Resources/shell-integration/cmux-zsh-integration.zsh:707-724`, bash analogue) — the bundled `bin/cmux` symlink shadows upstream's `cmux` inside every c11 terminal even without the PATH installer.
3. **Homebrew cask** creates `cmux` alias and zaps upstream-owned paths.
4. **Many user-visible strings** still say `cmux` (welcome doc, CLI help, error messages, integrations menu, `open -a cmux` calls that will literally fail now that the app is `c11.app`).

The result today is that a user with upstream cmux installed and c11 installed loses upstream `cmux` inside c11 terminals (PATH shadow), risks losing it at the `/usr/local/bin/cmux` layer (on install), and risks losing upstream's config dirs (on `brew uninstall --zap c11`). That's appropriation, not coexistence.

## Principle

**c11 owns `c11`. Upstream owns `cmux`.** c11 never claims `cmux` on the user's PATH, in their shell, or in their config dirs without explicit opt-in.

Carveouts (kept for upstream merge ergonomics, all invisible to users at the shell):
- Internal Swift type names (`CmuxCLIPathInstaller`, `CMUXCLI`, `CMUXTermMain`).
- Env var prefix constants — `mirrorC11CmuxEnv()` already mirrors both directions.
- The `c11` CLI still accepts `cmux` as a subcommand alias dispatch inside the binary. A user who types `cmux skill install` into a shell where `cmux` happens to still resolve to us (upgrade path) keeps working silently; we just never teach it and never install it.

## Changes

### A. CLI PATH installer — `c11`, with install/uninstall safety

**File:** `Sources/AppDelegate.swift`

1. `CmuxCLIPathInstaller.init()` default `destinationURL` → `/usr/local/bin/c11` (was `/usr/local/bin/cmux`). Line 1203.
2. `installWithoutAdministratorPrivileges(sourceURL:)` (line 1287-1295): before removing an existing destination entry, verify it is a symlink pointing at our bundled `c11`. If it is something else (user-owned regular file, a symlink to an unrelated target), refuse with a clear error: "`/usr/local/bin/c11` already exists and points at X. Remove it manually if you want c11 to replace it."
3. `uninstallWithoutAdministratorPrivileges()` (line 1297-1308): same check — only remove if the symlink points at our bundled `c11`. Handles dangling symlinks explicitly (where `symlinkDestinationURL()` returns nil because it uses `fileExists`, which follows symlinks): if the entry exists (via `destinationEntryExists()`) but the target can't be resolved, treat as "not c11-owned, refuse to remove".
4. **Both safety checks must also guard the privileged paths.** `privilegedInstaller` and `privilegedUninstaller` currently hand off to osascript with an unconditional `rm -f`. Move the Swift-level symlink-target check BEFORE `privilegedInstaller(...)` / `privilegedUninstaller(...)` calls, not just before the non-privileged branches.
5. Bundle relocation caveat: if the user moves `c11.app` from `/Applications` to `~/Applications`, the installed symlink target no longer matches `Bundle.main.executableURL`'s new path, so uninstall will refuse. Surface the refusal with an actionable message: "The installed c11 symlink at X points at an old c11.app location (Y). Remove it manually with `sudo rm X`." Document this limitation in CHANGELOG.
6. `InstallerError.bundledCLIMissing` message (line 1176): "Bundled **c11** CLI was not found at \(expectedPath)." (was "cmux CLI").
7. `InstallerError.installVerificationFailed` message (line 1182): "Installed symlink at \(path) did not point to the bundled **c11** CLI."
8. `@objc func installCmuxCLIInPath` and `uninstallCmuxCLIInPath` (lines 6240, 6262): method names stay (internal Swift symbol); user-visible alert titles flip to "c11 CLI Installed" / "Couldn't Install c11 CLI" / "c11 CLI Uninstalled" / "No c11 CLI symlink was found at …".

### B. Command Palette — c11-branded

**File:** `Sources/ContentView.swift`

- `command.installCLI.title` default (line 5084): `"Shell Command: Install 'c11' in PATH"`.
- `command.uninstallCLI.title` default (line 5093): `"Shell Command: Uninstall 'c11' from PATH"`.
- Keywords (line 5086, 5095) unchanged.

**File:** `Resources/Localizable.xcstrings`

Per the codex review, the catalog already carries c11 translations for several of these keys (lines ~9628-9748, 9967-10313, 14329-14342, 20883-20896). Confirm each key's current state and update only where the source English default disagrees with the catalog — don't duplicate work the rebrand PR already did.

### C. CLI help/error strings — c11-branded

**File:** `CLI/c11.swift`

1. `skillCommandUsage()` header (line 15748): `cmux skill — …` → `c11 skill — …`.
2. Error message referencing `cmux skill help` (line 15655): `"…Try \`c11 skill help\`."`.
3. `Unknown command` error (line 1435): `"Unknown command '…'. Run 'c11 help' to see available commands."`.
4. `cmux markdown open` usage strings (lines 2599, 2604, 2611, 2617, 2623 — 5 occurrences): rename to `c11 markdown`.
5. `cmux clear-metadata` example (line 3802): rename.
6. `cmux ssh user@host` example (line 4190): rename.
7. `"cmux app did not start in time"` messages (lines 1013, 1017, 1051): `"c11 app did not start in time"`.
8. **`open -a cmux` auto-launch calls (lines 2890, 2898).** BUG, not just branding — the shipped app is `c11.app`, so `open -a cmux` fails with "Application not found". Change to `open -a c11`. Both reviews flagged.
9. `resolveSkillSource` error message (line 15791-15792): mention `C11_SKILLS_SOURCE` as the primary env var; keep `CMUX_SKILLS_SOURCE` silently honored via the mirror for upgrade compat. Update read to `env["C11_SKILLS_SOURCE"] ?? env["CMUX_SKILLS_SOURCE"]` at line 15140 (verify line via grep during implementation).

**Internal comments** at lines 15628, 15663, 15734 — low priority, only change alongside the user-visible edits in the same diff so the file stays self-consistent.

### D. Clipboard snippet + onboarding surface

**File:** `Sources/AgentSkillsView.swift`

- `copyManualCommandToPasteboard` (line 167): snippet → `"c11 skill install --tool \(target.rawValue)"`.
- No localization layer involved; this is a plain Swift literal. Add a small unit test asserting the clipboard content shape.

The onboarding consent sheet body copy (lines 553-555) already says "agents only know about c11's CLI and sidebar metadata when they've read the c11 skill file" — no rename needed.

### E. Welcome doc — rewrite

**File:** `Resources/welcome.md`

Current state teaches `cmux identify`, `cmux tree`, `cmux new-split`, `cmux set-title`, `cmux --help`, and references `~/.local/bin/cmux` (wrong path — should be `/usr/local/bin/c11` after this change). The welcome is the literal first thing a user sees; it must match what `c11 skill install` in the README teaches.

Full pass: replace `cmux` commands with `c11`, correct the binary path, keep the lineage paragraph (line 15) unchanged because that's where "cmux" is *correct* as a reference to upstream.

### F. Integrations menu

**File:** `Sources/AppDelegate.swift:11882-11885`

`menu.integrations.install` tooltip: "Opens a new terminal tab and runs `cmux install`" → "Opens a new terminal tab and runs `c11 install`". The underlying integration-installer subtree's *internals* are out of scope (historical per CLAUDE.md), but the user-visible string at the menu layer is not.

Verify the command the menu actually runs (via `installIntegrationAction`) — if it sends literal `cmux install <tui>` to the terminal, update that too; if it uses argv[0] dispatch through the bundled binary, no runtime change needed.

### G. Shell integration — stop prepending the bundled `cmux` onto PATH

**Files:** `Resources/shell-integration/cmux-zsh-integration.zsh`, `Resources/shell-integration/cmux-bash-integration.bash`

The `_cmux_fix_path` function (zsh line 711-724; bash analogue ~554-567) prepends `Contents/Resources/bin/` to PATH. Today that directory contains both `c11` and a `cmux` → `c11` symlink. **The c11 binary is wanted on PATH; the `cmux` alias is not** — it shadows upstream cmux for every c11-spawned shell.

Two possible fixes:

- **Option 1 (recommended):** remove the `bin/cmux` symlink creation from the build script (`GhosttyTabs.xcodeproj/project.pbxproj:523` — the `ln -sfh "${EXECUTABLE_NAME}" "$BIN_DEST/cmux"` line and the analogous `$MACOS_DIR/cmux` line). Any internal code that expected to exec `bin/cmux` should exec `bin/c11` instead. Grep for references (CLI socket spawn paths, daemon binaries) and update.
- **Option 2 (smaller diff):** keep the symlink but modify the shell-integration functions to only prepend `bin/c11`, not the entire `bin/` directory. Use a targeted PATH entry that resolves just `c11`, not a directory prepend. Harder to implement cleanly in POSIX shell; not recommended.

**Pick Option 1.** Track down internal callers via grep and update them. This is the blocking item from codex review #1.

### H. Homebrew cask — hand `cmux` back to upstream

**File:** `homebrew-c11/Casks/c11.rb`

1. Drop line 21: `binary "#{appdir}/c11.app/Contents/Resources/bin/c11", target: "cmux"` — no `cmux` alias.
2. Drop `conflicts_with cask: "cmux"` (line 17). Rationale (per codex review): once c11 no longer installs any `cmux` binary, there is no PATH collision with the upstream cask. Allowing parallel install is the whole point.
3. Trim the `zap trash` array (line 23-33) to c11-owned paths only:
   - **Keep:** `~/Library/Application Support/c11`, `~/Library/Application Support/c11mux` (transitional from our rebrand), `~/Library/Caches/c11`, `~/Library/Caches/c11mux`, `~/Library/Preferences/com.stage11.c11.plist`, `~/Library/Preferences/com.stage11.c11mux.plist`.
   - **Remove:** `~/Library/Application Support/cmux`, `~/Library/Caches/cmux`, `~/Library/Preferences/ai.manaflow.cmuxterm.plist`. Those belong to upstream; `brew uninstall --zap c11` must not touch them.
4. Cask version: currently `"0.59.0"` (line 2) with a TODO comment. `update-homebrew.yml` rewrites this on release (line 3 comment confirms). Don't manually re-version; the release workflow handles it.

### I. CHANGELOG — rewrite the Unreleased entry, don't append

**File:** `CHANGELOG.md`

The current Unreleased entry (lines 7-12) says the `cmux` command remains as a compat alias. That's no longer true after this change. Rewrite it:

```markdown
## Unreleased

### Changed
- **c11 no longer claims the `cmux` name.** The CLI installs to `/usr/local/bin/c11` (the previous default was `/usr/local/bin/cmux`). The Homebrew cask no longer adds a `cmux` binary alias or conflicts with the upstream `cmux` cask — both can now be installed in parallel. The bundled shell-integration no longer shadows upstream `cmux` on PATH inside c11 terminals. If your scripts use `cmux skill install` or similar, update them to `c11 skill install`.
- Welcome markdown, CLI help text, error messages, and integrations menu now refer to `c11` throughout.

### Fixed
- `open -a cmux` auto-launch in CLI socket dispatch failed because the app bundle is `c11.app`; now correctly calls `open -a c11`.

### Migration
- Existing `/usr/local/bin/cmux` symlinks created by prior c11 versions are not auto-removed. `c11 uninstall` only removes `/usr/local/bin/c11`. If you have a stale `cmux` symlink you want gone, remove it manually: `sudo rm /usr/local/bin/cmux` (verify with `ls -l /usr/local/bin/cmux` first).
- App bundle relocation caveat: if you move `c11.app` between locations, the installed PATH symlink can't be removed via the in-app uninstall — use `sudo rm /usr/local/bin/c11` and re-run "Install 'c11' in PATH".
```

### J. README — minor addition

**File:** `README.md`

Current README already uses `c11 skill install` (lines 54-77). Two additions per codex review:

1. DMG-install paragraph (line 58): add a one-liner that users who go the DMG route must launch c11 and run "Shell Command: Install 'c11' in PATH" from the Command Palette (or use Homebrew) before they can use `c11` from Terminal.
2. Consider a "coexistence with upstream cmux" mini-section under the lineage paragraph — one sentence that says "c11 does not claim the `cmux` name on your PATH; install both side-by-side without conflict."

## Explicitly deferred

- **`sheetShownKey = "cmuxAgentSkillsOnboardingShown"`** — `UserDefaults` key name. Leave as-is; renaming it would re-prompt users who clicked "Don't ask again". Document the cosmetic `defaults read` artifact in the CHANGELOG only if it's a concern.
- **Env var prefix constants** (`CMUX_*`) — mirror function handles both sides. Individual error-message references to specific CMUX env vars get updated alongside their code sites (e.g., `CMUX_SKILLS_SOURCE`), but the prefix itself stays.
- **Legacy `cmux install <tui>` integration-installer subtree internals** — historical per CLAUDE.md. User-visible strings around it ARE renamed (tooltip, command it dispatches); internal code paths are untouched.
- **Internal Swift type names** — `CmuxCLIPathInstaller`, `CMUXCLI`, `CMUXTermMain`, `CmuxCLIPathInstaller.InstallerError`, etc. Renaming them would balloon the diff and complicate upstream merges. Not a user-visible concern.

## Test plan

**Unit:**

- `CmuxCLIPathInstaller.uninstall()` refuses to remove a symlink whose target is not our bundled `c11`. Tests: symlink pointing at `/bin/ls`, regular file at destination, dangling symlink, correct target.
- `CmuxCLIPathInstaller.install()` refuses to overwrite an existing non-matching entry without `force` (if we add a `force` flag; otherwise refuses unconditionally).
- Privileged path: inject a `PrivilegedInstallHandler`/`PrivilegedUninstallHandler` that asserts the safety check fired before handoff.
- `AgentSkillsView.copyManualCommandToPasteboard` pastes `c11 skill install --tool <tool>` for each target.

**Manual:**

- **Fresh machine, no prior `cmux` or `c11` on PATH:** DMG → palette "Install 'c11' in PATH" → verify `/usr/local/bin/c11` present, `/usr/local/bin/cmux` absent, `c11 skill install` works.
- **Upstream cmux first, then c11:** upstream DMG or upstream Homebrew places `cmux` on PATH. c11 DMG + palette install → verify upstream `cmux` untouched, `c11` runs c11, both commands work independently. Verify inside a c11 terminal that `which cmux` resolves to upstream, not our bundled binary.
- **c11 first, then upstream cmux:** c11 install → upstream Homebrew `brew install --cask cmux` should succeed (no conflict). Both binaries on PATH.
- **Uninstall safety:** manually replace `/usr/local/bin/c11` with `sudo ln -sfh /bin/ls /usr/local/bin/c11` → palette "Uninstall 'c11' from PATH" → verify refusal with clear error, symlink untouched.
- **App relocation:** install c11 in `/Applications`, install CLI, move app to `~/Applications`, relaunch, try uninstall → refusal with actionable error.
- **`brew uninstall --zap c11`:** on a machine with upstream cmux config dirs present → verify upstream's `~/Library/Application Support/cmux` and friends are not touched.
- **`c11 help` output audit:** run `c11 help` and every subcommand's `--help`; grep the output for `cmux` — the only allowed reference is in a lineage/attribution context, nothing actionable.
- **Welcome flow:** first launch from a clean machine → welcome.md renders → every command example copy-paste-works.
- **Auto-launch:** with c11 not running, issue `c11 identify` from a terminal where the app isn't launched — verify `open -a c11` fires correctly and the command completes.

**CI:**

- Add a grep-based lint that fails if any file under `Resources/welcome.md`, `Resources/Localizable.xcstrings`, `Sources/`, or `CLI/c11.swift` introduces a new *user-visible* `cmux` literal outside the lineage contexts. (Narrow the check to avoid catching internal identifiers.)

## Open question for operator

**One decision affects PR sizing.** This plan now covers:

1. CLI PATH installer (naming + safety)
2. Homebrew cask (alias, conflicts_with, zap)
3. Command Palette strings
4. CLI help/error strings (many call sites)
5. Welcome doc rewrite
6. Integrations menu tooltip
7. Shell integration PATH shadowing fix + build-script symlink removal
8. Clipboard snippet + onboarding
9. CHANGELOG + README updates

Options:

- **Full sweep in one PR (recommended).** The changes are coherent under one policy — "c11 owns c11, upstream owns cmux." Reviewers can evaluate the policy change holistically. Harder to split cleanly because the CHANGELOG and README need to describe the full delta.
- **Two PRs:** (a) CLI installer + Homebrew + CHANGELOG + README as the policy change; (b) welcome doc + CLI help strings + integrations menu + shell integration as a string audit. Downside: (a) lands an incoherent state where the command palette advertises `c11` but the welcome doc teaches `cmux` and shell integration still shadows.

Operator: confirm **full sweep** before implementation, or redirect to a different scoping.
