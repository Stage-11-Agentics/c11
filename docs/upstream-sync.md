# Upstream Sync Playbook

c11 is a fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux). The bulk
of upstream changes merge cleanly. We diverge intentionally on app-identity files
(bundle ID, display name, Sparkle feed, about-box copy, cask, etc.) and on a small
set of fork-only primitives (markdown surfaces, the c11 skill system, sidebar
agent telemetry).

This playbook is for the person or agent keeping c11 in sync with upstream.

## Remotes

```bash
# origin   = our fork (Stage-11-Agentics/c11)
# upstream = manaflow-ai/cmux
git remote -v
```

If `upstream` is not set up yet:

```bash
git remote add upstream https://github.com/manaflow-ai/cmux.git
git remote set-url origin https://github.com/Stage-11-Agentics/c11.git
```

## TL;DR routine sync

```bash
git switch main
git pull --ff-only origin main

./scripts/sync-upstream.sh --dry-run        # inspect what's incoming
./scripts/sync-upstream.sh --merge          # attempt the merge
# resolve any conflicts, then:
git commit
git push origin main
```

Then run the sanity checks below before declaring the sync done.

## Conflict hotspots

These files are where c11 intentionally diverges from cmux. Expect conflicts here
on any upstream merge that touches them. Prefer to keep c11's identity choices
while accepting upstream's functional changes.

| File | Why it conflicts | Resolution rule |
|------|------------------|-----------------|
| `Resources/Info.plist` | `CFBundleName`, `CFBundleDisplayName`, `SUFeedURL`, bundle-ID-adjacent keys | Keep `c11` / `com.stage11.c11` / Stage 11 Sparkle feed. Merge any new plist keys from upstream. |
| `README.md` (and translations) | Branding, install instructions, fork notice | Keep c11 branding + fork-attribution block. Pull in upstream feature copy, feature-list changes, screenshots. |
| `CHANGELOG.md` | Release notes | Merge entries; prefix our c11-only changes clearly. |
| `Sources/SocketControlSettings.swift` | Socket path constants, `baseDebugBundleIdentifier` | Keep `com.stage11.c11.debug` debug base. Socket directory name remains `c11mux` for upstream/installed-app compatibility (see Whitelist below). |
| `Package.swift` | Product executable name | Keep executable product name as per upstream-compat contract. |
| `Resources/shell-integration/*` | `CMUX_*` env contract (gate: `CMUX_SHELL_INTEGRATION`, plus `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, etc.) | Keep the `CMUX_*` namespace as-is. It is the canonical, upstream-compatible public contract. Do not rename to `C11_*`. |
| `Sources/c11App.swift` | About dialog attribution + c11 branding | Keep "c11, a fork of cmux by manaflow-ai" string; the file is named `c11App.swift` on this fork. |
| `GhosttyTabs.xcodeproj/project.pbxproj` | Bundle IDs, `PRODUCT_NAME` for DEV variant | Keep `com.stage11.c11(.debug/.apptests/...)`. `PRODUCT_NAME` is `c11` (DEV variant `c11 DEV`). |
| `Sources/AppDelegate.swift` | Prefs migration shim | Keep `migrateLegacyPreferencesIfNeeded()` + its call at the top of `applicationDidFinishLaunching`. |

Files upstream rarely touches but which are entirely ours:

- `NOTICE` (AGPL § 7 attribution, created by us)
- `docs/upstream-sync.md` (this file)
- `scripts/sync-upstream.sh`
- `homebrew-c11/` (if vendored)
- `skills/c11/`, `skills/c11-browser/`, `skills/c11-markdown/`, `skills/c11-debug-windows/`, `skills/c11-hotload/`, `skills/release/`
- `Resources/bin/claude` (session-resume wrapper, see CLAUDE.md "session-resume wrappers")

## Whitelist: residual `c11mux` / `cmux` references that must NOT be auto-renamed

These are intentional and survive any rebrand sweep. If upstream sync touches
them, keep them.

- **Runtime path constant `c11mux`** for `~/Library/Application Support/c11mux/`
  (`Sources/SocketControlSettings.swift` `directoryName` and `socketDirectoryName`,
  plus call sites in `Sources/Mailbox/`, `Sources/SessionPersistence.swift`,
  `Sources/Workspace.swift`, `CLI/c11.swift`). Renaming this requires a paired
  migration of Application Support, which is out of scope for routine sync.
- **CamelCase Swift type `C11muxTheme`** and friends (`Sources/Theme/*`). Whitelist
  preserved by design; the type identifier predates the rename.
- **Integration installer marker `c11mux-v1`** (`Sources/AppDelegate.swift`,
  `CLI/c11.swift`, `tests_v2/test_integration_installers.py`). Marker recognizes
  pre-existing installs in user tenant configs.
- **Compat sweep globs** in `scripts/prune-tags.sh`, `scripts/run-tests-v1.sh`,
  `scripts/run-tests-v2.sh`, `scripts/smoke-test-ci.sh` matching `/tmp/c11mux-*`
  and `/tmp/c11-*`.
- **`CMUX_*` shell-integration env contract** (`CMUX_SHELL_INTEGRATION`,
  `CMUX_SURFACE_ID`, etc.). Public API; do not rename.

## Resolution tips

- **Info.plist:** Open in Xcode or a plist-aware diff tool. Accept upstream for
  anything that is not `CFBundleName`, `CFBundleDisplayName`, `CFBundleIdentifier`,
  or `SUFeedURL`.
- **project.pbxproj:** Merges are textual. After resolving, open the project in
  Xcode and confirm `Build Settings → Packaging → Bundle Identifier` is still
  `com.stage11.c11` for each target (main app, debug, app tests, UI tests).
- **Shell integration files:** The `CMUX_*` env gates remain active. Upstream
  only knows about `CMUX_*`. Keep ours additive when introducing c11-specific
  variables; never replace.
- **AppDelegate:** If upstream refactors `applicationDidFinishLaunching`, re-seat
  the `migrateLegacyPreferencesIfNeeded()` call as the very first statement. The
  helper itself rarely needs changes unless legacy domains expand.

## When to take patches vs re-roll

- **Routine `main` sync (default):** `git merge upstream/main`. Fast-forward when
  possible.
- **Cherry-pick individual commits:** when we only want a specific fix from
  upstream ahead of a merge (e.g. a security patch), or when an upstream commit
  is entangled with a feature we are not ready for. Use `git cherry-pick -x <sha>`
  so the commit message retains the original SHA.
- **Re-roll (fresh branch from upstream):** only if the divergence accumulates
  enough that merge commits become noisy. Create `sync/YYYY-MM-DD` off
  `upstream/main`, re-apply our identity patches as a curated set, then
  fast-forward `main`. Rare.

## Release coordination

- Upstream cmux cuts releases on its own cadence. We do **not** auto-pull upstream
  into a c11 release.
- Our release flow (`/release` command, `./scripts/bump-version.sh`, tag `vX.Y.Z`,
  CI produces `c11-macos.dmg`) is independent.
- When we do merge upstream before a release, call it out in `CHANGELOG.md` with
  a line like: `Synced with manaflow-ai/cmux @ vA.B.C, includes <notable features>`.
- Sparkle appcast (`SUFeedURL`) must point at our releases; double-check after
  every merge.

## Sanity checks after any upstream merge

Do all of these before pushing:

1. **Build:** `xcodebuild -project GhosttyTabs.xcodeproj -scheme c11 -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/c11-sync build`
2. **Launch app:** `./scripts/reload.sh --tag sync-YYYYMMDD` and confirm the
   window opens, display name reads "c11", About box attribution still says
   "a fork of cmux".
3. **Smoke test socket:** from another terminal, `c11 new-split right --surface <id>`
   and confirm it works (socket path / filename unchanged for upstream compat).
4. **Shell integration:** open a new pane, confirm `CMUX_SURFACE_ID` and
   `CMUX_SHELL_INTEGRATION` are both set.
5. **Prefs migration smoke:** blow away `~/Library/Preferences/com.stage11.c11.plist`,
   seed `~/Library/Preferences/ai.manaflow.cmuxterm.plist` with a known key,
   launch, confirm the key transfers.
6. **Info.plist inspection:** `defaults read <path-to-app>/Contents/Info.plist CFBundleName`
   returns `c11`. `SUFeedURL` points at Stage 11.

If all six pass, push.

## Helper script

`scripts/sync-upstream.sh` automates fetch, divergence inspection, and the merge
attempt. See `scripts/sync-upstream.sh --help` for flags. It does not
auto-resolve conflicts. It surfaces them and hands control back to you.
