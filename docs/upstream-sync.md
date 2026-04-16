# Upstream Sync Playbook

c11mux is a surface-only rename fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux).
Almost every upstream change merges cleanly — we only diverged on app-identity files
(bundle ID, display name, Sparkle feed, about-box copy, cask, etc.). See the full
divergence contract in `notes/c11mux-backcompat-contract.md` (if present) or the
original contract document.

This playbook is for the person or agent keeping c11mux in sync with upstream.

## Remotes

```bash
# origin  = our fork (Stage-11-Agentics/c11mux)
# upstream = manaflow-ai/cmux
git remote -v
```

If `upstream` is not set up yet:

```bash
git remote add upstream https://github.com/manaflow-ai/cmux.git
git remote set-url origin https://github.com/Stage-11-Agentics/c11mux.git
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

These files are where c11mux intentionally diverges from cmux. Expect conflicts here
on any upstream merge that touches them — and prefer to keep c11mux's identity choices
while accepting upstream's functional changes.

| File | Why it conflicts | Resolution rule |
|------|------------------|-----------------|
| `Resources/Info.plist` | `CFBundleName`, `CFBundleDisplayName`, `SUFeedURL`, bundle-ID-adjacent keys | Keep `c11mux` / `com.stage11.c11mux` / stage11 Sparkle feed. Merge any new plist keys from upstream. |
| `README.md` (and translations) | Branding, install instructions, fork notice | Keep c11mux branding + fork-attribution block. Pull in upstream feature copy, feature-list changes, screenshots. |
| `CHANGELOG.md` | Release notes | Merge entries; prefix our c11mux-only changes clearly. |
| `Sources/SocketControlSettings.swift` | Socket path constants, `baseDebugBundleIdentifier` | Keep `com.stage11.c11mux` debug base. Socket filenames stay upstream-compatible per the contract. |
| `Package.swift` | Product executable name | Keep executable product name as per contract (`cmux` internal, display `c11mux` only in bundle). |
| `Resources/shell-integration/*` | `C11MUX_SHELL_INTEGRATION` env gate plus upstream `CMUX_*` vars | Keep both gates live; never remove the upstream `CMUX_*` env names. |
| `Sources/cmuxApp.swift` | About dialog attribution | Keep "c11mux — a fork of cmux by manaflow-ai" string. |
| `GhosttyTabs.xcodeproj/project.pbxproj` | Bundle IDs, `PRODUCT_NAME` for DEV variant | Keep `com.stage11.c11mux(.debug/.apptests/...)`. `PRODUCT_NAME` stays upstream-compatible per contract; only the DEV variant is renamed. |
| `Sources/AppDelegate.swift` | Prefs migration shim | Keep `migrateLegacyPreferencesIfNeeded()` + its call at the top of `applicationDidFinishLaunching`. |

Files upstream rarely touches but which are entirely ours:

- `NOTICE` (AGPL § 7 attribution — created by us)
- `docs/upstream-sync.md` (this file)
- `scripts/sync-upstream.sh`
- `homebrew-c11mux/` (if vendored)

## Resolution tips

- **Info.plist:** Open in Xcode or a plist-aware diff tool. Accept upstream for anything
  that is not `CFBundleName`, `CFBundleDisplayName`, `CFBundleIdentifier`, or `SUFeedURL`.
- **project.pbxproj:** Merges are textual. After resolving, open the project in Xcode and
  confirm `Build Settings → Packaging → Bundle Identifier` is still `com.stage11.c11mux`
  for each target (main app, debug, app tests, UI tests).
- **Shell integration files:** Both `CMUX_*` and `C11MUX_*` env gates must remain active.
  Upstream only knows about `CMUX_*`. Always keep ours additive, never replacing.
- **AppDelegate:** If upstream refactors `applicationDidFinishLaunching`, re-seat the
  `migrateLegacyPreferencesIfNeeded()` call as the very first statement. The helper method
  itself should never need changes unless legacy domains expand.

## When to take patches vs re-roll

- **Routine `main` sync (default):** `git merge upstream/main`. Fast-forward when possible.
- **Cherry-pick individual commits:** when we only want a specific fix from upstream ahead
  of a merge (e.g. a security patch), or when an upstream commit is entangled with a feature
  we're not ready for. Use `git cherry-pick -x <sha>` so the commit message retains the
  original SHA.
- **Re-roll (fresh branch from upstream):** only if the divergence accumulates enough that
  merge commits become noisy. Create `sync/YYYY-MM-DD` off `upstream/main`, re-apply our
  identity patches as a curated set, then fast-forward `main`. Rare.

## Release coordination

- Upstream cmux cuts releases on its own cadence. We do **not** auto-pull upstream into a
  c11mux release.
- Our release flow (`/release` command, `./scripts/bump-version.sh`, tag `vX.Y.Z`, CI
  produces `c11mux-macos.dmg`) is independent.
- When we do merge upstream before a release, call it out in `CHANGELOG.md` with a line
  like: `Synced with manaflow-ai/cmux @ vA.B.C — includes <notable features>`.
- Sparkle appcast (`SUFeedURL`) must point at our releases; double-check after every merge.

## Sanity checks after any upstream merge

Do all of these before pushing:

1. **Build:** `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-sync build`
2. **Launch app:** `./scripts/reload.sh --tag sync-YYYYMMDD` and confirm the window opens,
   display name reads "c11mux", About box attribution still says "a fork of cmux".
3. **Smoke test socket:** from another terminal, `cmux new-split right --surface <id>` and
   confirm it works (socket path/filename unchanged for upstream compat).
4. **Shell integration:** open a new pane, confirm `CMUX_SURFACE_ID` and `C11MUX_SHELL_INTEGRATION`
   are both set.
5. **Prefs migration smoke:** blow away `~/Library/Preferences/com.stage11.c11mux.plist`, seed
   `~/Library/Preferences/ai.manaflow.cmuxterm.plist` with a known key, launch, confirm
   the key transfers.
6. **Info.plist inspection:** `defaults read <path-to-app>/Contents/Info.plist CFBundleName`
   returns `c11mux`. `SUFeedURL` points at stage11.

If all six pass, push.

## Helper script

`scripts/sync-upstream.sh` automates fetch, divergence inspection, and the merge attempt.
See `scripts/sync-upstream.sh --help` for flags. It does not auto-resolve conflicts —
it surfaces them and hands control back to you.
