# C11-289 plan

Verified on `0ff8887e5e`. B3. P2.

## Independence

This PR is the profile CLI and the `--profile` argument, branched from `origin/main` on its own. It does not change the Sparkle pin, the web-view crash hook, the import wizard, the SSH notes, or the title path. C11-288's import smoke does not wait on it. The existing `related_to` links stay; do not add a Lattice dependency. If it misses week-3 admission it stays out of 1.0, and the release does not wait. `clear` and `delete` ship in this PR only together with the in-use refusal and the `--yes` requirement. A half-finished pair stays out of the diff. A reviewer can merge this PR alone.

## What exists

`BrowserProfileStore` (`Sources/Tabs/BrowserTab.swift:341`) persists `browserProfiles.v1` (`:344`). The built-in id is `52B43C05-4A1D-45D3-8FD5-9EF94952E445` (`:346`). `createProfile(named:)` (`:377`) accepts any non-empty name, including a duplicate, then `persist()` and `noteUsed` (`:394`). `renameProfile` (`:398`) refuses an empty name and the built-in profile. `canRenameProfile` is `:416`. `websiteDataStore(for:)` (`:429`) returns `.default()` for the built-in id and `WKWebsiteDataStore(forIdentifier:)` otherwise. History for any other id is `browser_profiles/<uuid>/browser_history.json` (`historyFileURL(for:)`, `:453`). There is no `clear` and no `delete`.

`BrowserTab.init` (`:2877`) takes `profileID`. Nil uses `effectiveLastUsedProfileID` (`:2896`). An unknown id falls back to the built-in profile (`:2897-2899`). The constructor then `noteUsed` (`:2917`). Leave that fallback in place for the UI and for restore. The socket resolves `--profile` before `init` and returns `not_found` itself.

`newBrowserSurface` (`Workspace.swift:8587`) and `newBrowserSplit` (`:8507`, call through `WorkspaceManager.swift:4068`) already take `preferredProfileID`. Both call `setPreferredBrowserProfileID(browserTab.profileID)` (`Workspace.swift:8554`, `:8637`), and `installBrowserTabSubscription` does it again (`:6053`). `resolvedNewBrowserProfileID` (`:6065`) copies the source browser tab's profile before the workspace preference and last-used.

`v2BrowserOpenSplit` (`Sources/SocketHandlers/BrowserHandlers.swift:1122`) passes no profile. `tab.create` (`SurfaceHandlers.swift:443`) and `area.create` (`PaneHandlers.swift:248` and `:262`) pass no profile. `browser open` parses `--workspace`, `--window`, and `--allow-insecure-http` (`CLI/c11.swift:7210-7267`) and has no `--profile`. Help at `:10181` and the usage line at `:17993` match that. `new-tab` (`:2601`) and `new-area` (`:2350`) take `--type` and `--url` and no profile.

`c11 browser cookies set` writes the tab's own `WKWebsiteDataStore.httpCookieStore` (`BrowserQueryHandlers.swift:998-1000`). No `browser.profiles` feature flag exists. The only flag in this area is `AreaInteractionFeatureFlag`. Do not add one.

The profile menu still uses `NSAlert.runModal()` (`BrowserTabView.swift:2019`, `:2052`). Leave those prompts. CLI verbs do not call them.

## One-shot `--profile`

AC2 fails if an explicit profile is recorded. Three writes do that today:

- `createProfile` calls `noteUsed`.
- `BrowserTab.init` calls `noteUsed`.
- Creation writes `preferredBrowserProfileID`, and the next unscoped open in that pane copies the source browser's profile.

`createProfile(named:recordsLastUsed:)` keeps the default `true`, so the UI prompt still selects the profile it just made. CLI `add` passes `false`.

`BrowserTab` gains `sticksAsPreferred`, default `true`. An explicit `--profile` on `browser.open_split`, `tab.create`, or `area.create` passes `false`. Init then skips `noteUsed`. The three `setPreferredBrowserProfileID` call sites skip a tab whose flag is false. `resolvedNewBrowserProfileID` skips a source browser whose flag is false and continues to the workspace preference, then last-used. Unscoped open keeps today's selection. The UI menu still calls `setPreferredBrowserProfileID` (`BrowserTabView.swift:1996`).

Resolve the argument before `init`. A UUID matches an id. Any other string matches one trimmed, case-insensitive display name. Zero matches is `not_found`. Two matches is `ambiguous`. Do not fall through to the built-in profile. `--profile` on `new-tab` or `new-area` without `--type browser` is a CLI error and does not reach the socket. On a remote workspace, reject `--profile` with `invalid_params`. The remote data-store branch (`BrowserTab.swift:2906-2908`) stays as it is.

The open and create responses include `profile_id`. `list` returns `id`, `name`, `built_in`, and `in_use`. `in_use` is a short main-actor scan of live `BrowserTab.profileID` values. `list` does not construct a web view or a data store.

## Verbs

Socket methods, registered in `v2DispatchBrowser` and listed from `v2Capabilities`:

- `browser.profiles.list`
- `browser.profiles.add`
- `browser.profiles.rename`
- `browser.profiles.clear`
- `browser.profiles.delete`

None of them go in `focusIntentV2Methods` (`TerminalController.swift:252`). `browser.open_split` is already outside that set, so its `v2MaybeFocusWindow` (`BrowserHandlers.swift:1169`) does not raise the key window. Do not add a focus path for `--profile`.

`add` refuses a trimmed case-insensitive name that already exists, including `Default`, with `already_exists`, and creates nothing. An empty name is `invalid_params`. `rename` uses `renameProfile`, refuses the built-in profile, and uses the same duplicate rule.

`clear` and `delete` require socket `confirm: true`, which CLI `--yes` sets. Without it the command exits non-zero, code `confirmation_required`, and changes nothing. Both refuse the built-in profile and refuse a profile that any live browser tab uses (`in_use`). `clear` calls `removeData(ofTypes:modifiedSince:completionHandler:)` for `WKWebsiteDataStore.allWebsiteDataTypes()` on that profile's store only. Register profile verbs in TerminalController.socketWorkerV2Methods and SocketDispatch.socketWorkerV2Response; v2DispatchBrowser alone would use the default main-actor policy (:2039-2044, :2060-2099) and make a completion wait deadlock. Parse/validate on the worker, make bounded main hops for model snapshots, reservation, and WebKit invocation; wait only on the worker. Use a bounded wait with an operation result that distinguishes pending/error from success; completion finalizes on main even if the caller stops waiting. Never pump a nested run loop or wait on main. `delete` does that data removal, removes the history file from `historyFileURL(for:)`, drops the store's cached data store and history store, and removes the definition. It does not remove the built-in history file and does not touch a remote workspace store. Flush/cancel pending history saves before deleting its file so cached stores cannot recreate it. Reset a removed last-used id to the built-in id; existing workspace preferences resolve through the existing validity check.

New CLI error text uses `String(localized:defaultValue:)`. Help text stays in the existing usage strings. No new menu copy. Six-locale fill is C11-291.

## Destructive operation lifetime

During a bounded main hop, validate not built-in/not in-use and reserve the profile id until the WebKit removal completion. Concrete race fixture: clear/delete starts on an unused profile, then another request or UI selection opens it before removal completes. Current BrowserProfileStore.websiteDataStore and BrowserTab.init do not have a reservation guard (:429 and :2894-2908). Make existing creation/profile-switch paths reject the reserved id until completion; duplicate destructive requests return busy. Reservations are scoped to this async removal, not durable locks. Release them on completion/error, not merely on caller timeout. Do not report success before data removal and definition/file cleanup complete.

List all files: CLI/c11.swift; Sources/Tabs/BrowserTab.swift and BrowserTabView.swift for store and selection admission; Workspace.swift and WorkspaceManager.swift for one-shot preference propagation; SocketHandlers/BrowserHandlers.swift, SurfaceHandlers.swift, PaneHandlers.swift, SystemHandlers.swift and SocketDispatch.swift; TerminalController.swift for worker policy; the two c11-browser skill files and the runtime socket script.

New localization keys, English only, if the existing error vocabulary cannot express these cases: browser.profile.error.busy, browser.profile.error.notFound, browser.profile.error.ambiguous, browser.profile.error.alreadyExists, browser.profile.error.confirmationRequired, browser.profile.error.builtIn, browser.profile.error.inUse, browser.profile.error.invalidName, browser.profile.error.browserOnly, browser.profile.error.remoteUnsupported, browser.profile.error.operationPending, browser.profile.error.operationFailed. C11-291 fills six locales before sign-off. Record the actual subset on the ticket.

## Skill

Teach `c11 browser profiles` and `--profile` on `browser open`, `new-tab --type browser`, and `new-area --type browser` in `skills/c11-browser/SKILL.md` and `skills/c11-browser/references/commands.md`. State that an explicit `--profile` does not become the next unscoped open's profile, and that `clear` and `delete` need `--yes` and refuse a profile a live tab is using. After this PR merges, run `scripts/sync-installed-skills.sh c11-browser`. Do not sync an unmerged branch into `~/.claude/skills`.

## Tests

`tests_v2/test_browser_profiles.py` against a tagged build, on that build's socket. Synthetic names `smoke-b3` and `smoke-b3b` only.

1. `add`, `list --json`, `rename`, and a second `add` of the same name. The error is non-zero and `list` still has one row.
2. Record the profile id of an unscoped `browser open`. `browser open https://example.com --profile smoke-b3b` returns that profile's id. The next unscoped `browser open` returns the recorded id. Close both tabs afterward.
3. `delete` while the tab is open exits non-zero and `list` still shows the profile. `delete` without `--yes` leaves it. After the tab is closed, `delete --yes` removes it.
4. One real web view. On a synthetic profile, `browser cookies set` (`BrowserQueryHandlers.swift:998`), then `clear --yes`, then a later navigation in a new tab of that profile. `cookies get` does not show that cookie. A cookie set on a second synthetic profile is still there. Do not clear the built-in profile. Do not use a real account.
5. The key window is unchanged across `list`, `add`, `rename`, `open --profile`, `clear` without `--yes`, and `delete` without `--yes`. No dialog appears. Same observation shape as `tests_v2/test_focus_no_new_window.py`.

Add a delayed-removal runtime seam for the named race: start clear/delete, attempt open/switch and a second destructive call while pending, then complete. No tab may begin using that profile during removal, the other profile remains usable, and no request reports success early. Exercise a never-completing removal to verify the worker returns pending/error while tab/list queries remain responsive. Close both seeded tabs before clear, then reopen to inspect cookies. Verify built-in refusal and an unknown --profile returning not_found without opening a tab. No source-grep test. No soak. No `c11LogicTests` case that needs `NSApp`. The socket script is the proof.

## Cut

Import, the URL allowlist, passkeys, Chrome file writes, tenant config, a new modal, and restyling the UI create and rename prompts. Do not invent a separate feature flag. If C11-284's registry has landed, reconcile this feature's advertisement with its owner and register/enable the agreed browser.profiles capability; verify the integrated capabilities output. Exact main hops are required because BrowserProfileStore is an observable model and WKWebsiteDataStore is UI-owned. Do not rebuild web views from `list`. Do not make unscoped open always use the built-in profile.

## Dependencies and file barrier

C11-216 supplies the Atlas validation artifact. C11-257 owns send/mailbox files: wait for its landing before editing TerminalController.swift or SocketDispatch.swift, then re-check worker dispatch against that merged base. This is a shared-file barrier, not permission to change send logging. Keep C11-288 independent. Coordinate the actual capability id with the C11-284 registry at integration.

## Decisions

None. AC2 fixes the selection behavior.

## Branch

Build mode: `c11-1.0/C11-289-browser-profiles` from `origin/main`. Not the crash-recovery branch.


## Reset 2026-10-02 by agent:luna-289

## Reset 2026-10-02 by agent:luna-289
