# c11 State Directory + Socket Rename Plan

Date: 2026-05-15

Status: drafted; not yet ticketed

## Background

The original C11-1 rebrand (landed via PR #111 plus the `c11-1-rebrand-cleanup` follow-on, the latter unmerged) deliberately preserved the `c11mux` name in three places: the CLI binary `cmux` (compat alias), the `CMUX_*` env vars, and **all on-disk state paths and socket paths**. The carve-out was justified at the time by ease of merging upstream `manaflow-ai/cmux` changes.

That carve-out has since been narrowed. Policy now (2026-05-15) is **never say `cmux` or `c11mux` anywhere except the compat `cmux` binary alias**. Env vars dual-read `C11_*` alongside `CMUX_*` (the `CMUX_*` form is preserved only because c11 binaries already dual-read it; new code uses `C11_*`). On-disk paths are the remaining surface and are user-discoverable — e.g., `~/Library/Application Support/c11mux/` is visible to anyone in Finder or `ls`, and `socket_path` is printed in CLI / daemon-status output.

This plan covers retiring `c11mux` from the four on-disk state surfaces. The companion branch `rename/c11mux-paths-to-c11` has already landed the safe-to-ship name fixes (xcstrings keys that were silently breaking non-English localization, internal comments, the theme env-key surface) — see "What landed on the rename branch" below. The remaining work in this plan is the on-disk migration, which requires a shim and is out of scope for the rename branch.

## Surfaces in scope

| Surface | File | Current path | Target path |
|---|---|---|---|
| Socket | `Sources/SocketControlSettings.swift:64,296` | `~/Library/Application Support/c11mux/c11.sock` | `~/Library/Application Support/c11/c11.sock` |
| Session persistence | `Sources/SessionPersistence.swift:559` | `~/Library/Application Support/c11mux/` (session subtree) | `~/Library/Application Support/c11/` |
| Workspace state | `Sources/Workspace.swift:4043` | same dir, workspace subtree | same dir |
| Mailbox state | `Sources/Mailbox/MailboxLayout.swift:29,68` | same dir, mailbox subtree | same dir |

All four currently use the literal directory name `"c11mux"`. They write into a shared `~/Library/Application Support/c11mux/` and the socket is a sibling file inside that directory.

## Constraints

- **The c11 daemon runs continuously.** A rename that takes effect at next launch must handle the case where an older daemon is still bound to the old socket while a newer CLI client is looking at the new path (or vice versa). The fix can't assume a clean cold start.
- **Bundle-ID variants exist.** `com.stage11.c11`, `com.stage11.c11.debug`, `com.stage11.c11.staging`, etc. (visible in `~/Library/Application Support/`). The current code uses a single hard-coded `"c11mux"` name regardless of bundle ID; the rename should preserve that flat shape unless we deliberately want per-bundle subdirs (probably no — keep it simple).
- **The shell-integration files (`cmux-bash-integration.bash`, `cmux-zsh-integration.zsh`) read `CMUX_SOCKET_PATH` from the env.** The app sets that env var at launch. So changing the socket path on the app side automatically propagates to any new shell session; older shells running before the upgrade hold the stale path until they're restarted. That's the existing reload pattern — no new work.
- **No upcoming hotbed.** This is a deliberate, tested change, not part of a hotfix release.

## Design

### Phase 1 — One-time directory migration on app startup

In `c11App` (or an equivalent early-startup hook before any of the four surfaces are read), run an idempotent migration:

```swift
// Pseudocode
let oldRoot = appSupportRoot().appendingPathComponent("c11mux", isDirectory: true)
let newRoot = appSupportRoot().appendingPathComponent("c11", isDirectory: true)

if FileManager.default.fileExists(atPath: oldRoot.path)
    && !FileManager.default.fileExists(atPath: newRoot.path) {
    // Take a per-bundle file-lock to serialize concurrent app launches
    try withMigrationLock(at: appSupportRoot()) {
        // Re-check inside the lock — another process may have migrated already
        guard FileManager.default.fileExists(atPath: oldRoot.path),
              !FileManager.default.fileExists(atPath: newRoot.path) else { return }
        // Atomic rename if same volume (which it always is for Application Support)
        try FileManager.default.moveItem(at: oldRoot, to: newRoot)
        // Leave a back-pointer symlink so a downgraded c11 binary still finds state.
        // (Drop in a later release; see Phase 3.)
        try FileManager.default.createSymbolicLink(at: oldRoot, withDestinationURL: newRoot)
    }
}
```

The symlink keeps a downgraded binary working through the transition release. Without it, anyone reinstalling an older build after upgrading would see an empty `c11mux/` and lose access to their session/workspace/mailbox state.

### Phase 2 — Change the four constants to read `"c11"`

Once the migration runs first, all four surfaces just use `"c11"`:

```swift
// SocketControlSettings.swift
static let directoryName = "c11"
private static let socketDirectoryName = "c11"

// SessionPersistence.swift, Workspace.swift, Mailbox/MailboxLayout.swift
.appendingPathComponent("c11", isDirectory: true)
```

No dual-read needed in the four surfaces themselves — the migration shim guarantees that by the time these constants are consulted, the state lives at the new path (or the symlink redirects to it).

### Phase 3 — Drop the back-compat symlink after N releases

In a later release (probably 2–3 versions out):

- Remove the symlink-creation step from Phase 1.
- Add a startup cleanup that removes a dangling `c11mux` symlink if found.
- Update CHANGELOG with a note that downgrading past this version will lose access to state without a manual `ln -s ~/Library/Application Support/c11 ~/Library/Application Support/c11mux`.

### Socket handling — special case

The socket file lives inside the directory and gets renamed with everything else as part of the directory move. The daemon binds to `c11/c11.sock` after Phase 1; nothing extra to do daemon-side.

CLI-side risk: an older `cmux` (or `c11`) binary holding the old socket path will hit a dead path after upgrade. Mitigation: the symlink at `c11mux/` → `c11/` makes the legacy `c11mux/c11.sock` lookup resolve correctly.

If we want extra safety, Phase 1 can also create a hard-link or socket-symlink at the legacy path. macOS doesn't allow hard-linking Unix domain sockets, so a symlink is the only option and Finder treats it the same as the parent directory. Recommended: just the directory symlink, no separate socket symlink.

## What landed on the rename branch (`rename/c11mux-paths-to-c11`)

The branch made the user-visible name fixes that don't need a migration shim. All four state-dir surfaces and the `C11muxTheme` struct were intentionally left alone — those are this plan's work.

| Change | File | Why |
|---|---|---|
| xcstrings key rename: `"New c11mux Workspace Here"` → `"New c11 Workspace Here"` (and `Window` counterpart) | `Resources/InfoPlist.xcstrings` | **Bug fix.** `Resources/Info.plist` already says `New c11 Workspace Here`. NSServices looks up translations by the live Info.plist value; the stale `c11mux` keys in xcstrings made all 5 non-English translations silently unreachable. |
| Comment rename `c11mux Module 1` → `c11 Module 1` | `Resources/shell-integration/cmux-{bash,zsh}-integration.{bash,zsh}` | Internal comment hygiene. The filenames themselves stay `cmux-*` (compat alias path used by shells sourcing them). |
| Comment rename `c11mux default Ghostty palette` + dead docs path | `Resources/ghostty/c11-default.conf` | The referenced spec doc is gone in either form; rename keeps it consistent. |
| Env-key rename `c11muxThemeManager`/`Context` → `c11ThemeManager`/`Context` | `Sources/Theme/ThemeEnvironment.swift` + 1 call site in `Sources/WorkspaceContentView.swift` | Small, self-contained, no on-disk impact. Public surface is internal-only (env keys are looked up by KeyPath; nothing serializes them). |

## Follow-on tickets (out of scope for this plan)

1. **`C11muxTheme` struct rename** — 42 references across 9 files (`Sources/Theme/{ThemeManager,ThemeSocketMethods,ThemeCanonicalizer,ThemeBindingControls,ResolvedThemeSnapshot,C11muxTheme}.swift` + 3 test files). Includes a source-file rename and a test-class rename (`C11muxThemeLoaderTests` → `C11ThemeLoaderTests`). No on-disk impact. Pure mechanical refactor. Worth its own ticket because it cuts across the theme socket surface and may collide with other in-flight theme work.

2. **`CMUX_*` env vars** — still in shell integration and `_cmux_send` etc. Per current policy, both `CMUX_*` (compat) and `C11_*` (canonical) coexist because c11 binaries already dual-read. Status quo holds — these are surfaced via the binary's own dual-read, not via a state migration. No action.

3. **Shell-integration filenames `cmux-bash-integration.bash` / `cmux-zsh-integration.zsh`** — these are the compat-alias surface (shells `source` them by name). Renaming would require updating every shell config that sources the old path. Defer indefinitely; treat as the documented compat-alias exception.

## Test plan

Unit:
- Migration shim with old-only state present → new path populated, symlink at old path.
- Migration shim with both old and new present → no-op (new takes priority; old left alone).
- Migration shim with neither present → no-op.
- Migration shim under concurrent process invocation (file-lock honored).

Integration:
- Boot daemon on a fixture profile with `c11mux/` populated; assert socket binds on `c11/c11.sock` and legacy path resolves via symlink.
- Run `c11 daemon-status` and confirm `socket_path` shows `~/Library/Application Support/c11/c11.sock`.
- Verify `c11 themes`, `c11 mailbox`, and workspace-restore all still work after migration.

Manual:
- Clean machine: install fresh build, confirm only `c11/` exists.
- Upgrade path: with existing `c11mux/` state, install new build, confirm migration ran, state intact, symlink in place.
- Downgrade path (during back-compat window): install older build over the symlink, confirm it reads through to `c11/`.

## Acceptance

- `~/Library/Application Support/c11/` is the canonical state root on new and upgraded installs.
- `~/Library/Application Support/c11mux/` is either absent (new install) or a symlink to `c11/` (upgraded install, removed in Phase 3).
- `socket_path` in any JSON / status output reads `~/Library/Application Support/c11/c11.sock`.
- All four state surfaces continue to work without data loss across the upgrade.
- No new daemons race-bind to mismatched paths.

## Related work

- [c11-1-rebrand-cleanup branch](https://github.com/Stage-11-Agentics/c11/tree/c11-1-rebrand-cleanup) — five unmerged commits cleaning up additional `c11mux` residue (header scripts, design assets, test prose). Worth resurrecting and merging alongside this plan's work; nothing in it conflicts.
- `feedback_never_say_cmux.md` in operator memory (2026-05-15) — policy basis for this rename: never say `cmux` *or* `c11mux`.
