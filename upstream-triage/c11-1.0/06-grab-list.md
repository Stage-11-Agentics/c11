# Topic 06: The grab list

**Needs you:** six numbered questions. None blocks scoping. Each changes what gets built.

1. **Should a restored Claude tab come back on the account it ran on?**
   - **Yes, pin it (recommended).** The wrapper records `CLAUDE_CONFIG_DIR`, and resume replays it. A Bravo pane comes back as Bravo.
   - **No, follow the selected account.** This is today's behavior. It suits rotating away from an exhausted account, but the switch is silent.
   - **Pin, with a fallback.** Pin by default, and resume on the selected account if the pinned one has no valid login. This costs a login check per restore.
2. **Should tab numbers survive restarts and never be reused?**
   - **Yes (recommended).** A restored tab keeps its `tab:N`, so "send that to 292" still works after a relaunch. A ref to a closed tab fails instead of hitting a new one. Numbers keep climbing across weeks, into the thousands.
   - **No, cmux's model.** Each launch reserves a fresh block of 10,000, so stale refs fail, but every tab gets a new and much larger number after each restart.
3. **What should Cmd+[ and Cmd+] do?** They are browser Back and Forward today.
   - **Focus history everywhere (recommended).** Browser Back and Forward move to Cmd+Left and Cmd+Right (Safari has both bindings), so muscle memory is retrained once.
   - **Focus history everywhere except a focused browser.** Browser behavior is unchanged, but the keys mean two things depending on focus.
   - **Focus history on new keys.** Nothing moves, but it needs a free chord. Cmd+Ctrl+[ and ] are already prev/next workspace.
4. **What is a workspace group?**
   - **A folder (recommended).** The header is only a container with name, color, icon and collapse state. It is simpler and fits c11's existing workspace color, icon and pin.
   - **cmux's anchor model.** The header is a real workspace that owns the group; closing it promotes the next member. It is more powerful, but it is the source of most of cmux's follow-up bugs (#5253, #8925, #9176, #13688, #15892).
5. **How should workspaces get names automatically?** Today they stay "Workspace N" unless someone renames them.
   - **Derive, no model (recommended for 1.0).** The name comes from the workspace root and the agents' own tab titles, behind a user/auto ownership lock.
   - **Summarize with a model.** Do what cmux does: read the transcript and call `claude -p` or a local model. This is richer but needs a cost and doctrine call.
   - **Both, the model opt-in.**
6. **Should passkeys be in 1.0?** They need Apple's restricted `web-browser.public-key-credential` entitlement, a provisioning profile, and a change to how the app is signed. The approval is out of our hands.
   - **Apply now and ship when approved (recommended).** The code is ready, so the feature lands whenever Apple says yes.
   - **Defer to 1.x.**
   - **Drop it.**

**Read this first:** the local `main` checkout was 34 commits behind `origin/main`. Several of those commits matter here: C11-243 tab last-seen tracking, C11-248 tab/area vocabulary, #467 session history and #469 close safety. Every c11 citation below is against `origin/main` (`170d30f350`, 2026-10-01). File names follow the C11-248 renames (`WorkspaceManager.swift`, `Sources/Tabs/BrowserTab.swift`). cmux citations are against `upstream/main` (`920ff39ff7`).

## Summary

| # | Item | c11 today | Effort | Depends on |
|---|---|---|---|---|
| 1a | Fail closed on aliased routing keys (#13214) | Missing | S | none |
| 1b | Stable short refs (#13247, #13633) | Partial | M | none |
| 1c | `--command` on `new-split`, `new-pane`, `new-surface` (#9614) | Partial | S | none |
| 1d | Paste with submit and delivered/queued result (#14837, #13849) | Mostly done | S | none |
| 1e | `read-selection` (#10022) | Missing | S (terminal), M (all tab kinds) | none |
| 1f | `resize-window` (#9826) | Missing | S | none |
| 1g | `--window` routing (#4211) | Partial | S | none |
| 1h | Batch `reorder-workspaces --dry-run` (#4507) | Partial | S | none |
| 1i | `capabilities`, `guide`, `--skill`, `rpc` | Partial | S to M | 1a (for a param registry) |
| 1j | `config doctor` with JSON schema (#3454, #13146) | Missing, different shape | S | none |
| 2 | Restore through wrappers and accounts (#10503, #10347, #10440, #15375) | Missing | M | none |
| 3 | Workspace groups (#4815, #5018) | Missing | L | 1h; sidebar decision from topic 05 |
| 4a | Focus history (#4160, #8654, #9329) | Partial | M | C11-243 (done) |
| 4b | Recently Closed and Cmd+Shift+T (#4160, #9132) | Browser-only | L | 1b, 2 |
| 5 | Browser: profiles, import, allowlist, isolation, passkeys | Mixed | S to L | none |
| 6 | AI naming of workspaces (#5547) | Missing | S to M | none |

Suggested order: 1a, 1c, 1d, 1g and 1h first, as one small batch. Then 1b, 2 and 4a. Then 3 and 4b. 5 and 6 can run in parallel at any point.

---

## What cmux built

### 1. CLI and socket hardening

- **1a. Aliased routing keys fail closed (#13214, 2026-09-22).**
  - `ControlRequestParser.unsupportedTargetAlias(in:)` strips `_` from each param key, lowercases it, and matches seven names: window, group, workspace, surface, terminal, tab and pane id.
  - Any spelling other than the exact snake_case form fails with `invalid_params`: "Unsupported parameter 'surfaceId'; use 'surface_id'".
  - Code: `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Wire/ControlRequestParser.swift` in commit `78b9683d4a`.
  - It is not a general unknown-key check. A typo such as `surfce_id` is still ignored.
- **1b. Stable IDs (#13247, #13633).**
  - #13247 exposes the persisted `stable_surface_id` and `stable_workspace_id` as read-only join keys on catalog rows (`docs/surface-catalog-identity.md`).
  - #13633 (`e2143374cf`) stops short refs from rebinding. `ControlHandleOrdinalDefaultsStore` reserves a disjoint block of 10,000 ordinals per launch in UserDefaults. The first launch starts at 1,000,000,000.
  - A ref is never reused, so a stale `surface:7` resolves as unknown.
- **1c. `--command` (#9614, `7a0ba63056`).**
  - The CLI sends `initial_input = text + "\r"` on `surface.split`, `pane.create`, `surface.create` and `workspace.create`.
  - Ghostty types it into the normal interactive shell at spawn, so the shell outlives the command.
  - It is rejected for non-terminal types. Blank text is dropped.
- **1d. Paste (#13849 `ca060bda0c`, #14837 `c155ac0257`, #14937 `091d0ea74a`).**
  - `terminal.paste` returns `delivery: delivered|queued`. It is queued when the PTY is not attached yet.
  - Hard failures are `input_queue_full`, `surface_unavailable` and `process_exited`.
  - With `--submit`, the host sends an agent-aware submit key 150 ms later in a separate input turn: ctrl+enter for a multi-line Claude Code prompt. A failed submit returns `submitted:false` and is not an error, so callers don't double-paste.
  - `cmux paste` reads an argument or stdin and rejects unknown flags.
  - #14937 adds `cmux send --paste`, because cmux's plain `send` still types keystrokes.
- **1e. `read-selection` (#10022, `436fc1f62e`).**
  - The worker-lane method `surface.read_selection` returns `has_selection`, `kind`, `text` and `base64`, plus `file_path`, `line_range` or `url` where they apply.
  - It covers terminal, browser, markdown and file preview. The browser keeps its last selection through a document-start tracker, and password fields clear it.
- **1f. `resize-window` (#9826, `2fd3c403cb`).** A v1 `resize_window <uuid> <w|-> <h|->` command. It keeps the top-left corner fixed and clamps to `minSize`. `- -` reads the frame without changing it.
- **1g. `--window` routing (#4211, `dea2f64684`).**
  - `--window` becomes a `window_id` param, and every other ref is resolved inside that window.
  - An unparsable `window_id` is rejected. `--window` also turns off the `$CMUX_WORKSPACE_ID` fallback.
- **1h. `reorder-workspaces` (#4507, `b748ccb19e`).**
  - `--order a,b,c` sends one atomic `workspace.reorder_many` call, which keeps the pinned and unpinned segments.
  - `--dry-run` returns the plan. A `workspace.reordered` event fires only on a real change.
- **1i. Agent onboarding.**
  - `guide` and `--skill` (#12468) print a static Markdown guide before the CLI looks for a socket, so they work with no app running.
  - `capabilities` returns `{protocol, version, socket_path, access_mode, methods[]}` from a hand-kept list. #16460 shows that list drifting from the real dispatch.
  - `rpc <method> [json]` makes a raw v2 call.
- **1j. `config doctor` (#3454, #13146).**
  - `web/data/cmux.schema.json` is generated into Swift (`CmuxConfigSchema.generated.swift`).
  - A semantic validator checks paths, types, enums and bounds in `cmux.json`, and the same validator guards Settings writes.
  - `--json` returns `{ok, error_count, findings[], schema_url}`.

### 2. Restore hardening

- **`agents.launchers` (#10503, documented in `docs/configuration.md:464-497`).**
  - The `cmux.json` entry has `id`, `kinds`, `detect.argvExecutables`, `resumeArgvPrefix` and `includesAgentExecutable`.
  - At capture time cmux walks up to 8 ancestor processes and matches the executable name. It follows `env`, `npx` and `node` up to two levels.
  - On resume it puts `resumeArgvPrefix` in front of the resume argv. Fork is not wrapped.
  - A malformed declaration fails closed: that session resumes unwrapped.
  - Code: `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentExternalLauncher.swift`.
- **Account pin (#15375).** The routed Claude account is recorded as launch metadata (`CMUX_AGENT_LAUNCH_ROUTED_CLAUDE_ACCOUNT`) and is not replayed into the environment.
- **Later fixes:**
  - #15287 refuses to hibernate when the launcher no longer resolves.
  - #14412 and #15324 add a PATH check, and a stderr notice when resume falls back to a direct launch.
- **`launch_rejection_reason` (#10347, #10440).** `cmux sessions --json` shows why a captured argv was refused (`CLI/CMUXCLI+SessionsList.swift:186`). Tokens include `argvLooksLikeShellWrapper`, `sanitizerRejectedArgv` and `argvDecodeFailed`. It appears in the CLI only, never in the UI.
- **Capture path.** cmux's per-surface shim sets `CMUX_AGENT_LAUNCH_ARGV_B64` and similar variables. Hooks installed in each agent's own config read them at SessionStart. This is the tenant-config path c11 refuses.

### 3. Workspace groups (#4815, 0.64.11; CLI #5018)

- **Model.** `WorkspaceGroup` has `id`, `name`, `isCollapsed`, `isPinned`, `anchorWorkspaceId`, `customColor` and `iconSymbol`. Membership is `Workspace.groupId`, and member order is the order of `tabs[]`.
- **Persistence.** Groups are saved in the session snapshot. The anchor is stored by member index, because workspace UUIDs change on restore.
- **Sidebar.**
  - A collapsible header with chevron, tinted icon, name and a `+` on hover.
  - A collapsed header shows the summed unread count of its members.
  - Drop position decides membership.
  - Shortcuts: Cmd+Shift+G groups the selection, Ctrl+Cmd+G makes an empty group, and Cmd+N inside a group adds to it.
- **CLI.** `workspace-group list|create|ungroup|delete|rename|collapse|expand|pin|unpin|add|remove|set-anchor|new-workspace|set-color|set-icon|move|focus`, with `workspace_group:N` refs.
- **Placement of new workspaces.** An explicit flag first, then a per-cwd rule in `cmux.json`, then a global setting.
- **History.**
  - It was built in SwiftUI and later re-implemented in the AppKit sidebar (#8270, default in 0.64.20).
  - About ten follow-up fixes came after, most of them about the anchor (#5253, #8925, #9176, #13688, #15892).

### 4. Navigation

- **Focus history (#4160, #8654, #9329).**
  - `FocusHistoryModel` keeps a back/forward stack of `(workspaceId, panelId?)`, capped at 50.
  - Consecutive duplicates are skipped, a new focus truncates the forward branch, and closed targets are pruned.
  - #8654 adds the scope setting `panesAndTabs|workspacesOnly`.
  - #9329 (`81fe1ddd71`) gives Cmd+[ and Cmd+] to global focus history. #9296 split the browser and focus Back/Forward shortcuts apart so they no longer collide.
- **History UI.** Titlebar arrows, a History menu, and a searchable History pane grouped by day.
- **Recently Closed (#4160, #9132, #8841).**
  - `ClosedItemHistoryStore` holds panel, workspace and window entries as session snapshots. Each snapshot carries cwd, scrollback, agent and resume binding.
  - It is persisted with a cap of 500 entries total and 100 per workspace. No live PTY is kept.
  - Cmd+Shift+T pops the newest entry of any kind.

### 5. Browser

- **Profiles (#318).** `WKWebsiteDataStore(forIdentifier:)` per profile UUID, with a profile CLI added in #3770 and #8874.
- **Import (#318 and later).**
  - 23 browsers in three engine families.
  - Chromium cookies are decrypted with the Keychain "Safe Storage" key. Firefox is read through SQLite.
  - It imports cookies and history, with no bookmarks import found.
- **URL allowlist (#10540, #10947).**
  - `browser.urlAllowlist` plus an MDM key, with host rules only.
  - It is enforced on navigation, redirects, popups, automation, prewarm and restore, and shows a blocked page. Local files stay allowed.
- **Process isolation (#4987).**
  - A `WKProcessPool` per panel, plus recovery: a crashed WebContent process is replaced and popups tied to it close.
  - The PR touched about 300 lines, mostly recovery.
- **Passkeys (#2660, #2905, #6718, #8630).**
  - `ASAuthorizationWebBrowserPublicKeyCredentialManager` plus a JS bridge over `navigator.credentials`.
  - It needs the restricted entitlement, a provisioning profile, and inside-out signing (#2905). Only release bundle IDs can run the real ceremony.
- **Out of scope as agreed:** Design Mode (#8034 and later) and the standalone browser (`cmux-next` #15505 and later).

### 6. AI naming (#5547, 0.64.16)

- **Opt-in** through `automation.workspaceAutoNaming`.
- **How it runs.** At each turn end, a Stop hook in the agent's config reads the agent's transcript and calls the agent's own CLI on the user's account: `claude -p`, `codex exec`, or Grok, OpenCode, Pi and OMP adapters. The output is a 2-5 word title.
- **Throttling.** A transcript-growth floor and a minimum interval.
- **Ownership lock.** `CustomTitleSource` is `user|auto`. A manual rename always wins, and clearing the name hands it back to auto.

---

## What c11 has today

### 1. CLI and socket

- **1a. Routing keys.**
  - Param readers (`v2String`, `v2UUID`, `TerminalController.swift:2654-2711`) return nil on a miss.
  - `v2ResolveWorkspace` then falls back to the selected workspace (`:3044-3053`). So `{"surfaceId": …}` silently acts on the focused target.
  - C11-248 added one alias seam, `Sources/SocketHandlers/LegacyWireAliases.swift`, that maps `surface_*`, `pane_*` and `panel_*` to the canonical keys.
  - #469 made destructive verbs reject empty or unresolved refs (`v2RejectUnresolvedTargetRefs`, `TerminalController.swift:2713`). Tab-scoped metadata writes reject `missing_ref` and `empty_ref`.
  - No path rejects an unknown or misspelled key.
- **1b. Short refs.**
  - Per-kind counters start at 1 at every launch and are never persisted (`TerminalController.swift:283`, `v2EnsureHandleRef :2504-2518`).
  - After a restart, a stale `tab:N` either resolves to whatever now holds N or returns `not_found`.
  - Refs are re-minted while iterating a dictionary (`v2RefreshKnownRefs`), so numbering order across restarts is not deterministic (inferred).
  - UUIDs do survive restore, because snapshot ids are threaded into panel constructors.
  - This bites harder in c11 than in cmux: tab numbers are on screen ("Show Tab Numbers") and the operator says them aloud.
- **1c. `--command`.**
  - Only `new-workspace` has it. It is client-side: create, then `surface.send_text` (`CLI/c11.swift:2214`).
  - `workspace.create` also takes an `initialTerminalCommand` that replaces the shell (`WorkspaceHandlers.swift:229` on the stale tree).
  - c11's Ghostty already exposes `initial_input` (`ghostty.h:450`).
- **1d. Send.** c11 is ahead of cmux's plain `send`:
  - `deliverSocketSendText` (`TerminalController.swift:6703`) delivers printable multi-line text as one paste. It then sends one submit Return after a paste-settle delay.
  - The response carries `queued`, `delivered` and `submitted` (`SurfaceHandlers.swift:978-979`).
  - The CLI prints `queued=1` (`CLI/c11.swift:4942` on the stale tree).
- **1d. Send gaps:**
  - `unescapeSendText` rewrites `\n`, `\r` and `\t` (`CLI/c11.swift:11923`), so text is not byte-exact.
  - There is no stdin input.
  - Unknown flags are typed into the terminal (`:2947-2965`; also C11-140 B).
  - `new-workspace --command` drops the queued result.
  - The skill does not document `delivered` or `queued`.
- **1e. Selection.** No selection reader is exposed. Ghostty's `ghostty_surface_read_selection` is already called internally (`GhosttyTerminalView.swift:5030`).
- **1f. Windows.** `window.*` covers only list, current, focus, create and close.
- **1g. `--window`.** It is a global flag that sends `window.focus` before running the command (`CLI/c11.swift:1950`). That is a focus side effect, against the socket focus policy in c11's CLAUDE.md. It is honored per-command by only a handful of verbs.
- **1h. Reorder.** Singular `reorder-workspace` only (`CLI/c11.swift:2075`), with no batch and no dry-run.
- **1i. Onboarding commands.**
  - `capabilities` returns method names (`SystemHandlers.swift:26-292`).
  - There is no `guide`, `--skill` or `rpc`.
  - `c11 skill path|status|install` manages installed copies but does not print the skill text.
- **1j. Config.**
  - There is no settings file. App settings live in UserDefaults.
  - The text config c11 reads is `.c11/agents.json`, `.c11/blueprints` and themes. Only `themes validate` exists.
  - `c11 doctor` checks how `c11` and `cmux` resolve on PATH. `c11 config` manages saved agent launch configs.

### 2. Restore

- **Resume command.** The conversation store is the live path. `ClaudeCodeStrategy.resume` types the literal `claude --dangerously-skip-permissions --resume '<id>'` (`Sources/Conversation/Strategies/ClaudeCode.swift:57`). Codex does the same with `codex resume`.
- **What a ref holds.** `ConversationRef` stores kind, id, cwd, state, diagnostic reason and an opaque `payload` (`Ref.swift:91`). It stores no argv, env or launcher.
- **Wrappers.** `Resources/bin/claude` claims a placeholder with `--cwd "$PWD"` (`:192`) and execs the real binary. Neither it nor `Resources/bin/codex` records `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. A grep across `Sources`, `Resources` and `CLI` finds no capture of either.
- **Transcript check.** `transcriptExists` stats `$HOME/.claude/projects/...` and ignores `CLAUDE_CONFIG_DIR` (`ClaudeCode.swift:68-85`).
- **Agent configs.** They can carry `command` and `env` (`AgentConfigLibraryStore.swift:43-77`), but resume never reads them. A custom agent kind gets no resume at all.
- **Atin's accounts.**
  - `~/.zshrc:101-108` routes a bare `claude` through `claude-account exec`. That sets `CLAUDE_CONFIG_DIR` for the account selected by `claude-account use`, then execs `claude` through PATH, which reaches c11's wrapper.
  - Fresh launches are correct.
  - **Failure mode, inferred and not reproduced.** On restore, c11 types a bare `claude --resume` into a new shell.
    - The function routes it to the currently selected account, not the account the pane ran under.
    - Transcripts are shared through `projects/` symlinks, so resume still succeeds, but on the wrong account and with no warning.
    - A one-off `CLAUDE_ACCOUNT=bravo claude` launch is lost entirely.
    - `~/.claude/references/anthropic-accounts.md` already notes "c11 restores included" follow the default home.
- **Known adjacent bugs in C11-140 D (backlog):**
  - Claude resume does not `cd` into `ref.cwd`.
  - `shouldReplace` can demote a confident ref.
  - The strategy `capture(inputs:)` layer is never called.

### 3. Workspace groups

- There is no group concept.
- Workspaces already have the pieces a group reuses:
  - `customColor` (`Workspace.swift:250`, persisted).
  - An icon glyph (`c11 set-workspace-icon`, `CLI/c11.swift:3279`).
  - `isPinned` (`Workspace.swift:251`), and pinned workspaces float to the top.
  - Workspace description.
- The sidebar is SwiftUI: `WorkspaceSidebar` at `ContentView.swift:8392`, `LazyVStack` and `ForEach`. It never took cmux's AppKit rewrite.

### 4. Navigation

- **Workspace history exists but has no keys.**
  - `workspaceHistory`, `historyIndex` and `maxHistorySize = 50` live at `WorkspaceManager.swift:1085-1088`. Every selection is recorded (`recordWorkspaceInHistory :3886`). `navigateBack` and `navigateForward` are at `:3907` and `:3928`.
  - The only caller is the socket `workspace.last` (`WorkspaceHandlers.swift:41`). It tracks workspaces only, with no tab level.
- **Seen tracking is new and is the right foundation.**
  - C11-243's `TabSeenTracker` (`Sources/TabSeenClock.swift:83`) recomputes which single tab the operator is actually looking at.
  - It stamps the tab that left the screen. It ignores background socket focus changes, screen lock and occlusion.
  - Its stamps persist in the session snapshot.
- **Recently Closed is browser-only.**
  - `RecentlyClosedBrowserStack` (`WorkspaceManager.swift:565`, capacity 20 at `:1066`) is in memory only.
  - `reopenMostRecentlyClosedBrowserPanel` (`:4198`) restores the URL, profile and position.
  - Cmd+Shift+T is "Reopen Closed Browser Tab" (`c11App.swift:1056-1059`).
- **Close safety (#469) partly substitutes for undo.** Workspaces and windows now ask before closing, and Cancel is the default.
- **Session history (#467)** keeps the last ten session files, which is a coarse recovery path.
- **Shortcut map.**
  - Cmd+[ and Cmd+] are browser Back and Forward (`c11App.swift:1025-1030`).
  - Ctrl+Cmd+[ and Ctrl+Cmd+] are prev/next workspace (`KeyboardShortcutSettings.swift:157-160`).
  - Cmd+Shift+[ and Cmd+Shift+] are prev/next tab.

### 5. Browser

- **Profiles exist in the UI.** `BrowserProfileStore` uses `WKWebsiteDataStore(forIdentifier:)` (`Sources/Tabs/BrowserTab.swift:436`). There is no profile CLI and no c11-browser skill coverage.
- **Import exists, inherited.**
  - cmux #318 merged on 2026-03-17, one day before the fork.
  - c11 has the wizard: the "Import Browser Data…" menu (`c11App.swift:1079`), `BrowserImportBrowserDescriptor` (`BrowserTab.swift:6979`), and Chromium Safe Storage and Firefox `places.sqlite` readers.
  - It lacks cmux's later browsers (Aside, the Dia fix) and the agent-mode non-interactive import. I did not test whether it still works.
- **Allowlist.** Only the insecure-HTTP allowlist (`BrowserTab.swift:663`). There is no general URL allowlist.
- **Process pool.** One shared `WKProcessPool` (`BrowserTab.swift:1969`).
  - `webViewWebContentProcessDidTerminate` (`:6451`) forwards to a callback. I did not trace whether the tab recovers.
- **Passkeys.** None. `c11.entitlements` has no WebAuthn entitlement.

### 6. AI naming

- **Not shipped.** Atin's impression is half right.
- **Tabs get named by agents:**
  - The launch prompt and the c11 skill tell every agent to `rename-tab` and `set-description` as its first act (`CLI/c11.swift:16277` on the stale tree; `skills/c11/SKILL.md`).
  - Terminal OSC titles also flow into tab titles (`Workspace.applyProcessTitle`, `Workspace.swift:7231`). My unverified understanding is that Claude Code sets its own terminal title from the conversation, which would feel like AI naming.
- **Workspaces never get named.**
  - A new workspace is "Workspace N" (`WorkspaceManager.swift:758`). It is pinned by `stableDefaultTitle`, so a process title cannot override it.
  - It changes only through a manual or CLI rename.
- **No ownership lock.** There is no user/auto provenance on titles.
- **No doctrine conflict yet.** `PHILOSOPHY.md:13` names auto-titles as a feature c11 should produce by external observation and a small model, not agent cooperation. Nothing implements it.

---

## The gap

| Item | Gap in one line |
|---|---|
| 1a | Misspelled routing keys silently hit the focused tab. |
| 1b | `tab:N` from before a restart can point at a different tab. |
| 1c | No way to create a split or tab with a command in one call. |
| 1d | `send` is not byte-exact, has no stdin, and types unknown flags. Delivery status is undocumented. |
| 1e | Agents cannot read what the operator selected. |
| 1f | No window resize. |
| 1g | `--window` steals focus instead of scoping. |
| 1h | No atomic multi-move, no dry run. |
| 1i | No raw socket call. The skill cannot be printed from the running bundle. Capabilities carry no params. |
| 1j | Nothing validates `.c11/agents.json` or blueprints in one place. |
| 2 | Restore drops the account and any launcher wrapper, silently. |
| 3 | No grouping. |
| 4a | History exists for workspaces only and has no keys or UI. |
| 4b | Only browser tabs can be reopened, and only in memory. |
| 5 | No profile CLI, no URL allowlist, shared WebContent pool, no passkeys. |
| 6 | Workspaces are never named automatically. No ownership lock. |

---

## Proposed c11 1.0 shape

### 1. CLI and socket hardening

**1a. Fail closed on noncanonical routing keys (S).**
- Add the cmux check at the one seam C11-248 already built, `LegacyWireAliases`. Any key that normalizes to a routing selector but is neither canonical nor a listed legacy alias returns `invalid_params` with the canonical name.
- Canonical names are `tab_id` and `area_id`. Legacy aliases are `surface_id`, `pane_id` and `panel_id`.
- **Go one step further than cmux.** Also reject `*_ref` spellings the table does not list. This fits c11's existing "no silent fallback" rules (`missing_ref`, `empty_ref`, #469).
- **Alternative: a per-method param registry** that rejects every unknown key.
  - **Pro:** it catches all typos and can drive `capabilities`, help and the skill.
  - **Con:** about 200 methods to annotate.
- **Recommendation:** ship the seam check in 1.0 and open the registry as a 1.x ticket that 1i builds on.

**1b. Stable refs that survive restart (M).** This is the c11-specific improvement over cmux.
- Persist `{uuid: ordinal}` per kind, plus each kind's next ordinal, in the session snapshot.
- On restore, seed the maps before any topology work, so a restored tab keeps its `tab:N`. New tabs continue from the persisted maximum.
- A ref to a tab that no longer exists returns `not_found`, and no number is ever reused.
- Also expose a persisted id per tab and workspace in `tree --json`, the equivalent of `stable_surface_id`. c11 restores the same UUIDs, so this is mostly a documentation contract.
- **Alternative:** cmux's reserved blocks.
  - **Pro:** simpler; no snapshot coupling.
  - **Con:** every tab gets a new, very large number at each launch, which breaks the spoken "send it to 292" workflow.
- **Recommendation:** persisted map (question 2).

**1c. `--command` (S).**
- Add `--command` to `new-split`, `new-pane`/`new-area` and `new-surface`/`new-tab`, carried as an `initial_input` param through Ghostty's existing field.
- Move `new-workspace --command` onto the same path, so it stops racing a follow-up `send`.
- Reject it for browser and markdown types.
- Keep `initialTerminalCommand` (replace the shell) as a separate, socket-only param.

**1d. Paste (S).** c11 already delivers as a paste, so the job is to close the edges, not port the feature:
- **`c11 send` flags:** add `--raw` (no escape rewriting) and `-` for stdin. Reject unknown `--flags`, which also closes that part of C11-140 B.
- **`c11 paste`:** a documented alias for `send --raw`, for scripts written against cmux.
- **`new-workspace --command`:** surface the `queued` result instead of discarding it.
- **Skill:** document `delivered`, `queued` and `submitted` in `skills/c11/references/api.md`.
- **Submit key:** check whether a multi-line Claude Code paste needs cmux's ctrl+enter upgrade. c11's skill says multi-line sends arrive as one turn, so this may already be fine. Verify before porting.

**1e. `read-selection` (S for terminal, M for all).**
- Ship the terminal selection reader first, with `surface.read_selection` off-main and the cmux response shape.
- Markdown (`NSTextView`) and browser (document-start tracker) are a second step.
- **Value for Atin:** "look at what I highlighted" becomes a one-command move for an agent.

**1f. `resize-window` (S).** A v2 `window.resize` with a frame read. It is mainly useful for c11-computer-use validation runs, which need repeatable window sizes.

**1g. `--window` routing (S).**
- Make the global `--window` a `window_id` routing param and drop the `window.focus` side effect at `CLI/c11.swift:1950`.
- Fail closed on an unparsable value.
- This is a socket-focus-policy fix as much as a feature.

**1h. Batch reorder (S).**
- `reorder-workspaces --order` (one atomic `workspace.reorder_many`, pinned segments kept) and `--dry-run` on both the batch and singular verbs.
- Emit a `workspace.reordered` event into c11's events stream.
- Groups (3) reuse the same move core.

**1i. Onboarding commands (S to M).**
- **`c11 rpc <method> [json]` (S).** It removes the need for ad hoc `nc` calls in skills and tests.
- **`c11 guide` and `c11 --skill` (S).** Print the c11 skill bundled in the running app, with no socket needed.
  - **Why it matters:** c11's CLAUDE.md calls out a real recurring problem, installed skill copies going stale. The bundle's copy is always in step with the binary.
  - **Possible follow-on:** the installed copy could say "run `c11 guide` for the copy matching this build".
- **`capabilities` with feature flags (M).** Add a versioned `features` list next to `methods`, for example `paste.raw`, `refs.persistent`, `read_selection`. Skills and orchestrators can then branch on the build they are talking to. C11-248 already added a capability probe for older apps, so the pattern exists.
- **Parameter schemas for capabilities:** wait for the 1.x registry.

**1j. `c11 config doctor` (S).**
- c11 has no `cmux.json`, so this is not a schema port.
- It validates the text config c11 actually reads: `.c11/agents.json` (project and user), `.c11/blueprints/*`, and themes (it absorbs `themes validate`).
- It reports which file wins for the current directory, works with no app running, and returns `--json` findings.
- Publish JSON schemas for `agents.json` and blueprints next to `docs/workspace-apply-plan-schema.md`.
- If the restore launchers in item 2 land in `agents.json`, the doctor covers them too.

### 2. Restore hardening (M)

**The doctrine fit is good.**
- Recording the routing environment in the wrapper is exactly the "minimum needed for session resume" rule for `Resources/bin/` wrappers.
- It writes only c11's own store, never tenant config.
- cmux's version needs agent hooks; c11 does not.

**Shape:**

1. **Capture.** At claim time, `Resources/bin/claude` pushes `CLAUDE_CONFIG_DIR` and `CLAUDE_ACCOUNT_HOME` into the ref `payload`. `Resources/bin/codex` pushes `CODEX_HOME`.
   - These are an explicit allowlist of path-valued routing variables, never the whole environment and never secrets.
2. **Resume.** The strategy prefixes the typed command with the captured values, for example `CLAUDE_CONFIG_DIR='…' claude … --resume '<id>'`.
   - Atin's `~/.zshrc` `claude()` sees `CLAUDE_CONFIG_DIR` already set and runs `command claude`, which reaches the c11 wrapper.
   - `transcriptExists` must read under that config dir, not a hardcoded `~/.claude`.
   - Fix C11-140 D's missing `cd '<cwd>' &&` in the same change.
3. **Rejection reasons.** `c11 conversation list --json` gains `resume_skip_reason` (c11's `launch_rejection_reason`).
   - Values: `placeholder`, `state`, `invalid_id`, `transcript_missing`, `config_dir_missing`, `launcher_missing`.
   - `ResumeAction.skip(reason:)` already produces the text, so this mostly exposes it.
4. **Launchers, for argv routers like `teamclaude`.**
   - An optional `launchers` array in user-level `~/.c11/agents.json`, with the cmux shape.
   - The wrapper detects the launcher by walking ancestor PIDs at claim time and records the `launcher_id`.
   - Resume prefixes `resumeArgvPrefix` and fails closed. If the launcher is not on PATH, it resumes direct and says so.
   - Atin does not need this today, because his routing is env-based. It is cheap to add while the code is open, and it makes c11 correct for other operators' routers.
5. **Agent configs.** When a tab was launched from a saved agent config (`launch-agent`), record the config id. Resume then re-applies that config's `env` overrides. This covers per-call-sign launch configs.

**Alternatives:**
- **Launchers only, cmux-style.** It does not cover Atin's case, because `claude-account` execs `claude` directly with env, not argv.
- **Pin the account name instead of the dir.** This needs c11 to understand `claude-account`. Don't.

**Recommendation:** steps 1 to 3 and 5 for 1.0, step 4 if time allows. The default behavior depends on question 1.

### 3. Workspace groups (L)

**Shape:** cmux's feature, in c11's vocabulary, with the folder model (question 4).

- **Model.** `WorkspaceGroup {id, name, color, icon, isCollapsed, isPinned}` and `Workspace.groupId`. Member order is the workspace order.
  - Saved in the session snapshot.
  - The group reuses the existing workspace color palette (`WorkspaceTabColorSettings`) and the glyph icon from `set-workspace-icon`.
- **Sidebar header.** Chevron, icon, name, a member count, and an attention badge.
  - **The badge is the c11 improvement.** It aggregates c11's attention model, not only unread counts:
    - violet if any member is flagged,
    - the waiting count, excluding suppressed tabs,
    - unread.
  - A collapsed group still shows that something inside needs the operator. A flag inside a collapsed group also expands it, or pulses the header (pick one in design).
- **Interaction.**
  - Drag to join or leave.
  - Header context menu: Rename, Color, Icon, Pin, Ungroup, Delete. Delete never closes workspaces unless asked, and with #469 it asks.
  - Cmd+N inside a group adds to it.
- **Placement of new workspaces.** A group may carry a root-directory glob. A new workspace whose root matches joins the group. This reuses C11-238 workspace roots and fits the C11-240 New Workspace picker.
- **CLI and socket.**
  - `c11 workspace-group list|create|rename|delete|ungroup|add|remove|move|collapse|expand|pin|unpin|set-color|set-icon|focus`.
  - `group:N` refs, persistent like 1b. `--json` everywhere.
  - `tree` shows groups.
  - The skill teaches orchestrators to group their own fleets, for example one group per Lattice run.
- **Doctrine.** Groups are primitives the operator or an agent composes. c11 never infers group membership from what agents are doing.

**Dependencies:**
- 1h for the move core.
- Topic 05's sidebar verdict. If 1.0 rewrites the sidebar in AppKit to escape the SwiftUI livelock (cmux #6033 and others), build groups on the new sidebar, not before it. Otherwise group headers multiply the rows the SwiftUI list already struggles with. **Inferred risk:** headers add rows and drop targets to a list that cmux found livelocks with many workspaces.

### 4. Navigation

**4a. Focus history built on "seen", not on focus events (M).** This is better than cmux for Atin.

- **Source.** Feed history from `TabSeenTracker` transitions (C11-243), not from raw focus changes.
  - An entry is a tab the operator actually looked at, for longer than a dwell threshold (about 1 s, tunable).
  - Cmd+Shift+] through five tabs does not leave five entries.
  - Agent and socket focus changes while c11 is in the background never enter history, because they were never seen.
- **Model.** `(windowId, workspaceId, areaId, tabId, seenAt, dwell)`, capped at about 200.
  - A new entry after going back truncates the forward branch.
  - Closed targets are pruned or point into Recently Closed (4b).
  - Persisted with the snapshot, so history survives restart. That depends on 1b keeping refs stable.
- **Keys.**
  - Back and Forward (question 3).
  - "Last seen" toggles between the two most recent entries (like `cd -`). It needs a free chord. Ctrl+Tab is taken by legacy tab navigation (`AppDelegate.swift:11969`).
  - Replace the workspace-only `workspaceHistory` with this model, and keep `workspace.last` working on top of it.
- **CLI.**
  - `c11 history [--json] [--limit N]` lists seen entries with tab refs, titles and dwell.
  - `c11 history back|forward`, as focus-intent commands.
  - **Value for agents:** an Overwatch-style agent can ask "what has Atin been looking at for the last hour?" That is a strong attention signal, and it is legitimately operator-side data, not agent internals.
- **UI.** A History menu listing the last 10 entries with tab number and title. A full searchable pane can wait for 1.x.

**4b. Recently Closed and Cmd+Shift+T (L).**

- **Store.** `ClosedItemStore` holds tab, area, workspace and window entries as the existing session snapshot structs (`SessionPersistence.swift`). Entries carry cwd, scrollback, and the tab's `ConversationRef`.
  - Persisted with caps (cmux uses 500 total, 100 per workspace).
  - It absorbs `RecentlyClosedBrowserStack`.
- **Reopen.**
  - Restores in place if the original workspace and area still exist, otherwise as a split or new workspace.
  - An agent tab reopens by resuming its conversation through the store. That makes item 2 a hard dependency: a reopened Bravo pane must come back as Bravo.
  - The tab keeps its old `tab:N` (from 1b), so the agent's mailbox address and the operator's spoken number both still work.
- **Cmd+Shift+T** pops the newest entry of any kind. "Reopen Closed Browser Tab" stays as a menu item.
- **CLI.** `c11 closed list|reopen <id>|clear`.
- **Close confirmations.** With undo in place, #469's prompts could relax for single-tab closes. That is a separate call for later.

**Dependencies:**
- 1b, so refs survive.
- 2, so agents resume on the right account.
- #467 session history, already present as the coarse fallback.

### 5. Browser basics

| Piece | Shape | Effort |
|---|---|---|
| Profiles | Add `c11 browser profiles list\|add\|rename\|clear\|delete` and `--profile` on `browser open` / `new-surface --type browser`. Teach both in the c11-browser skill. Agents get a clean, isolated login per task, and `state.save`/`load` (C11-140 C) gets a better alternative. | S |
| Import | Already present. Smoke-test the wizard on today's Chrome, Arc and Safari. Pull in cmux's later browser descriptors. Add the non-interactive agent path (`c11 browser import --from chrome --scope cookies`). Never decrypt cookies without the operator's Keychain prompt. | S |
| URL allowlist | Host rules in a setting, plus a `c11 browser allowlist` CLI. Enforce on main-frame and subframe navigation, redirects, popups, automation and restore, with a blocked page. Fold in the C11-140 C subframe-bypass fix, since it is the same enforcement point. **Use case:** confining an agent's browser to `localhost` and one staging host. | M |
| Process isolation | **Verify before building.** I believe Apple deprecated `WKProcessPool` in macOS 12 and that separate pools no longer change process assignment (inferred, from memory; check the SDK docs). If so, cmux's real gain is #4987's crash recovery: replace the crashed web view, reset loading and focus state, close dependent popups. Port that recovery onto c11's existing `webViewWebContentProcessDidTerminate` hook (`BrowserTab.swift:6451`) whatever the pool answer. | S to M |
| Passkeys | Apply for the entitlement now. Port #2660's bridge and #2905's inside-out signing behind the release bundle ID only. Tagged builds can test only that the bridge loads. This is mostly release engineering, and it touches `skills/release`. | L, with an external dependency |

Out of scope as agreed: Design Mode and a standalone browser.

### 6. AI naming of workspaces (S to M)

- **The lock (S).** Add a user/auto source to workspace and tab titles. Any manual or CLI rename is `user` and permanent. Clearing the name returns it to auto. cmux's semantics are good; take them as they are.
- **Derived names, no model (S).**
  - When a workspace's title is still the default and auto, name it from:
    1. its root directory's basename (C11-238 already tracks roots), and
    2. once agents have titled their tabs, the most common role word, for example `c11 · Grab List`.
  - This costs nothing per turn and works for every agent kind, which fits the "observe from outside" doctrine.
- **Model summary, opt-in (M, later).**
  - c11 already reads agents' session files for live model detection and tab-sheet clocks (#463), so reading a transcript for naming has precedent.
  - The summarizer should run through a c11-owned call: a local model on Atlas, or an API key c11 holds. It must not go through hooks in the agent's config. That keeps it outside tenant config.
  - It is gated by a setting, throttled at turn end, and cost-visible.

**Recommendation:** the lock and derived names in 1.0, and the model as 1.x (question 5).

---

## Effort and risk

| Item | Effort | What could go wrong |
|---|---|---|
| 1a | S | Rejecting a spelling some old script relies on. Mitigation: the error names the canonical key, and the C11-248 alias table already defines what is legal. |
| 1b | M | The ref seed must run before any restore minting, or restored and new tabs collide. Duplicate restores (a workspace restored while its original is live) need fresh numbers. Mirror cmux's colliding-restore rule. |
| 1c | S | `initial_input` arrives before the shell's rc files finish. Ghostty buffers it in the PTY, but slow rc files with prompt redraws can garble the echo (inferred). |
| 1d | S | `--raw` must stay off by default, or existing `\n`-escaped callers break. |
| 1e | S/M | Browser selection tracking injects a script into every page. Keep it in the automation world and clear it on password fields. |
| 1f | S | None worth naming. |
| 1g | S | Some callers may rely on the focus side effect. Search the skills and tests. |
| 1h | S | Pinned-segment edge cases. Port cmux's validation-before-mutation. |
| 1i | S/M | The feature list drifts from reality, as cmux's did (#16460). Generate it from the dispatch table. |
| 1j | S | Low value if few people hand-edit `agents.json`. Keep it small. |
| 2 | M | Prefixing env into a typed command must quote safely, the same way the session id is quoted. Storing paths in the conversation store is a new class of data: keep it to an allowlist. An exhausted pinned account gives a worse resume than today (question 1). |
| 3 | L | Sidebar performance and drag-drop complexity. About six user-visible strings per surface go through the 6-locale translation pass. Collapsed groups hiding a flag: the badge rule above must be right. |
| 4a | M | Dwell threshold tuning. Shortcut churn (question 3). |
| 4b | L | Memory and disk for persisted scrollback. Cap it and drop scrollback first. Resuming the same conversation twice if the original tab also restores. Dedupe by conversation id. |
| 5 | S to L | Passkeys are blocked on Apple. The allowlist must cover subframes, or it is cosmetic. |
| 6 | S/M | The lock changes rename semantics everywhere titles are written: palette, CLI, sidebar, `set-title`. |

**Rough total:** the hardening batch (1a, 1c, 1d, 1f, 1g, 1h, 1i-rpc, 1i-guide) is about a week of delegator time across 3 or 4 PRs. 1b, 2 and 4a are about a week each. 3 and 4b are the two L items. Inferred, from diff sizes in cmux and c11's existing seams.

## Open questions

1. Account pinning on restore: see question 1 at the top.
2. Ref numbering policy: see question 2.
3. Cmd+[ and Cmd+]: see question 3.
4. Group model: see question 4.
5. Automatic naming depth: see question 5.
6. Passkeys timing: see question 6.
7. **Does topic 05 recommend an AppKit sidebar for 1.0?** If yes, groups (3) should wait for it and be built on it. If no, groups go onto the SwiftUI sidebar now, with a performance check at 50+ workspaces.
8. **Should Recently Closed relax #469's close confirmations?** Yes means fewer prompts once undo exists. No means two safety nets, which is fine but noisy.
9. **Should `c11 history` be readable by agents?** It reveals where the operator's attention goes. Yes gives Overwatch a strong signal. No keeps it UI-only.
10. **Which browsers matter for import?** Arc and Chrome are probably Atin's real sources. That decides which descriptors to smoke-test first.

---

Method: five Sonnet readers covered the cmux and c11 sides in parallel. I re-checked every load-bearing claim against `upstream/main` and `origin/main`. Line numbers marked "stale tree" come from the old local `main` and may have drifted by a few lines. Statements marked inferred were not read in code.
