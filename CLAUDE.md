# c11 agent notes

`AGENTS.md` is a symlink to this file, so every harness (Claude Code, Codex, Grok, …) reads the same rules. Project rules belong here, not in one harness's memory.

Mission, current state and next steps for each c11 workspace: `C11.md`.

## Mission

c11 is a macOS command center for the operator:agent pair. Terminals, browsers, and markdown panels composed in one window: addressable, scriptable, held in one field of view while many agents work in parallel. It embeds Ghostty as the terminal engine and treats the workspace as the atom of work.

**Who it's for.** The operator running eight, thirty, two hundred agents at once, tired of `cmd-tab` roulette across a screen of terminal windows. Not less work, just enough shape that the whole orchestra stays legible while the agents drive.

**What that implies for this codebase.** Every panel has a handle. Every handle is scriptable from outside the process. The CLI and socket exist so agents compose their own environment without the operator in the loop for routine moves.

### Host and primitive, never configurator

c11 provides workspaces, areas, panels, a socket, a CLI, and a metadata seam, all scoped to its own runtime. The operator's tenant config (`~/.claude/settings.json`, `~/.codex/*`, `~/.kimi/*`, shell rc files) is off-limits: c11 never installs hooks, persists configuration, or injects behavior into a TUI's on-disk state. `c11 install <tui>` stays rejected, consent prompts or not.

The one exception is the **session-resume wrappers** in `Resources/bin/` (`claude` is the reference; `codex`, `grok`, `opencode`, `pi`, `copilot`, `omp` follow it). A wrapper must:

- be prepended to PATH only inside c11 terminals (gated on a live socket plus `CMUX_SURFACE_ID`, the legacy name every wrapper still reads; a residual to rename);
- write nothing outside c11's own runtime (`/tmp` is fine, `~/.claude/` and friends are not);
- capture only what resume needs (session id, `terminal_type`, lifecycle status where the TUI exposes it);
- fall through to the real binary unchanged outside c11 or when the socket is unreachable.

The same wrapper may attach optional lifecycle or attention observations that the journal already allows. Delivery is best-effort: a dead socket may spool or drop an observation, and the agent is never held for an answer. `PermissionRequest` is observe-only. The wrapper still does not write tenant config, store a tool body, prompt, answer, or permission decision, or broaden trust. Upstream's blocking `hooks feed` `PermissionRequest` bridge is outside this exception.

A wrapper may also load a bundled c11 extension or plugin into that one process by launch flag, never through tenant config, to report the agent's prompt cache use (request times, provider and model ids, token counts, never text) through `agent.prompt_cache.report`, fire-and-forget with a timeout.

The Claude wrapper may add a bundled mailbox bridge through the same per-launch `--settings` hooks file. An async SessionStart hook subscribes to c11's native mailbox stream and sends only the doorbell invitation to Claude's own session inbox socket, while idle. Its session token stays in process memory. The bridge may inspect new records in that bound session's transcript to confirm the invitation arrived; it never stores or forwards transcript contents. It does not claim mail, change inbound permissions, or expose tools. Missing support, a rejected connection, or no confirmation within two seconds leaves the existing typed doorbell as the fallback. The bridge retires with its Claude process or subscription; it writes no tenant configuration and adds no MCP server or channel consent prompt.

The Grok wrapper may launch an interactive Grok with Grok's own `--leader --leader-socket` flags on a c11-owned socket in `/tmp`, and start a bundled `c11 grok-mailbox` sidecar that sends only the doorbell invitation to the bound session through that leader's ACP interface, while idle. It reads Grok's session registry to refuse delivery unless the TUI holds only the bound session, and confirms the invitation from the leader's own echo; it stores and forwards nothing. It does not claim mail or answer permission prompts. The operator's own leader or sandbox flags, a Grok without `--leader`, a refusal, or no confirmation within two seconds leaves the typed doorbell. The wrapper stops that leader when its Grok exits; it writes no tenant configuration.

Outside that bounded wrapper exception, lifecycle remains agent-reported: agents that read the c11 skill call `c11 set-metadata` / `c11 set-status` for the state they own. The wrapper contributes only optional, allowlisted observations at launch; it does not install or configure hooks in a tenant's environment.

## Vocabulary

**window → workspace → area → panel.** An area is a split region; a panel is a terminal, browser, or markdown viewer inside it; a sidebar entry is a workspace, never a panel. The Tab key and the tmux-compat names are not the c11 panel. Use these words everywhere. Old names (commands, flags, refs, socket methods, env vars, JSON keys) keep working as hidden aliases that never appear in help, skills, or docs.

- Say **workspace**, never "room", in c11 copy.
- Ghostty-facing code keeps Ghostty's names (`TerminalSurface`, `GhosttySurfaceScrollView`, `ghostty_surface_*`), as do the tmux-compat commands (`--pane`, `--surface`).
- **c11, never cmux.** Residual `cmux`/`CMUX`/`cmuxterm` in this tree is a bug to rename, except lineage talk and the deliberate `cmux` CLI compat alias. Write `C11_*` env vars, never `CMUX_*`. Rename as you touch files; a tree-wide sweep needs Atin's go.
- Short name **c11**; formal long name **c11 terminal multiplexer** for first references in press, docs landing pages, legal copy.
- Theme copy: **c11 theme** and **Light/Dark theme slots**. "Chrome theme" is internal only, to disambiguate from Ghostty terminal themes.

## Quick commands

```bash
./scripts/remote-build.sh --tag <slug>                       # tagged Debug app, built on Atlas, no launch
./scripts/remote-build.sh --tag <slug> --mode test -- -only-testing:c11LogicTests/<Class>
./scripts/launch-tagged-automation.sh <tag> --qa fresh       # launch on an authorized machine, dialogs off
scripts/sandbox-up.sh <run-id> <tagged.app>                  # guest for clicks, drags, tests_v2
scripts/sync-installed-skills.sh [name]                      # after ANY skill source edit
```

Never `open` an untagged `c11 DEV.app`. Full build workflow and remote variants: `skills/c11-hotload/SKILL.md`. Release: `skills/release/SKILL.md` (`/release`).

## Repo, release state, autonomy

- c11 lives on **GitHub** (`Stage-11-Agentics/c11`, public), an exception to Stage 11's Forgejo default. `upstream` is `manaflow-ai/cmux`, fetch-only. Only `origin` tags mean anything; prune cmux tags that leak in.
- **c11 is publicly released with live users.** Cutting a release, tags, the appcast, Homebrew, or anything else users receive needs Atin's named approval. PRs to `main` follow normal review and merge.
- **Check content, not topology.** Releases are tagged on the tested `release/*` head and merged back into `main` afterwards, hotfixes branch from a tag, and older reconciles were cherry-picks, so `main` and a shipped tag can differ in either direction and `merge-base --is-ancestor` misleads. An unmerged branch says nothing about whether its code is on `main`. Before fixing a bug found by reading `main`, or claiming code is absent from a ref, compare content: `git grep <symbol> <ref>`, `git diff <tag> main -- <path>`.
- Text-only README and CLAUDE.md edits go straight to `main`; everything else goes through a PR. Atin authors most PRs: check `gh pr view <n> --json author` before naming anyone else.
- **README.md is Atin's voiced document, not a feature list.** Agents may fix facts and vocabulary in place and add lines written in its voice. Rewriting, restructuring, replacing or cutting sections needs Atin's sign-off on the exact diff first, even when a ticket says "rewrite" or "refresh" the README: show him the diff and wait. Feature inventories belong in `CHANGELOG.md`. (#583 replaced the whole README with a feature list for 1.0 and had to be reverted in #614.)
- A PR with merge conflicts gets **no** `pull_request` CI while Drawbridge still passes. A missing `build` job means rebase onto `origin/main`.
- CI runs no eslint (`web-typecheck` is tsc only). Green CI on a lint-dependency bump proves nothing; run `bun run lint` locally.
- Drawbridge (`TRIAGE_POLICY.md`) triages issues and PRs, currently in dry-run. Flipping it live is Atin's call.
- The app icon's source art (`design/c11mux-lattice-icon-source.png`, from `gregorovitch/art/`) is public by Atin's authorization. No other Gregorovitch art enters this repo without asking.

## Lineage

tmux → [cmux](https://github.com/manaflow-ai/cmux) → c11. cmux (manaflow-ai) gave us the Ghostty embed, the browser substrate, and the CLI shape; [Bonsplit](https://github.com/almonk/bonsplit) (almonk, forked in `vendor/bonsplit/`) gave us the panel and split chrome. c11 adds the operator:agent primitives: markdown panels, addressable handles, the skill system, agent-written sidebar telemetry.

- **Pull freely.** Cherry-pick or merge upstream fixes cleanly with original authorship, so provenance stays obvious (`upstream-triage` skill). Divergence is deliberate; don't push for a resync.
- **Never write upstream.** No push, branch, issue, or PR against `manaflow-ai/*`. If a c11 fix would help cmux, tell Atin in one line.
- **Keep inherited features.** Removing something cmux shipped defaults to keep-and-adapt; cmux migrants may rely on it.

## The skill is the contract

c11's value to an agent is `skills/c11/SKILL.md` and its peers (`c11-browser`, `c11-markdown`, `c11-fanout`, `c11-debug-windows`, `c11-computer-use`, `c11-hotload`, `release`). The bar: an agent that read the skill drives a whole c11 session (spawn, dissolve, report, recover) without the operator stepping in. **A change to the CLI, socket protocol, metadata schema, or panel model is incomplete until the skill matches it.**

**Syncing the installed copy is part of the edit (HARD RULE).** c11 installs skills as one-time copies in every agent harness's skills folder (`~/.claude/skills/<name>/`, `~/.codex/skills/<name>/`, `~/.pi/agent/skills/<name>/`, …; stamped `.c11-skill.json`) and never tracks the repo afterward. The sync script refreshes every harness copy that exists. Editing or committing a skill under `skills/` changes nothing an agent loads. For any skill in `skills/MANIFEST.json`, the edit is done only after `scripts/sync-installed-skills.sh [name]` and a check of the live copy.

To validate what the operator actually sees, load `c11-computer-use`. Socket and CLI checks prove state, not UI.

## Lattice tickets

Non-trivial tickets run through **`lattice-hosted-orchestrator`**, because the c11 board is hosted (`stage11/c11` on lattice.stage11.ai; `lattice remote status` shows the binding). The in-repo `skills/lattice-orchestrator` is the legacy version, still shipped for installs; don't use it for c11 tickets. It runs one owner per ticket in its own worktree, independent review, runtime proof, a Merge Captain, terminal audit. c11 tickets earn it: typing-latency hot paths, tagged builds, localization passes, and submodule state that must not bleed between parallel work. Inline is fine for one-line edits, mechanical changes with no review surface, or when Atin says "just do it." `.lattice/` is a read-only cache of the hosted board and is gitignored; write the board only through the `lattice` CLI. Run only as many owners as Atlas can admit to its shared fleet slot; the other slot is reserved for the poller. Sustained high load reduces admission to one build, so fleet gates wait while slot 1 is occupied.

## Builds

- **Build on Atlas.** `remote-build.sh` ships the exact parent and submodule commits plus your dirty files, builds there, and retrieves the app and logs under `build-remote/`; it runs no local xcodebuild. Delegators and headless runs build and test only this way. In the c11 1.0 run, packaged-app validation and computer use happen on Atlas; the laptop receives the app but doesn't launch it.
- **Admission is mandatory.** Atlas reserves slot 1 for the PR Swift poller; owner gates and every other Atlas build share slot 2, one at a time. At normal load, one poller build and one fleet build may overlap. After one-minute load stays above 40 for 60 s, starts serialize: a fleet build takes slot 2 only while slot 1 is idle, then holds slot 1 as a guard; a poller build takes slot 1 only while slot 2 is idle, then holds slot 2 as a guard. Both slots stay held through the build, so new builds wait; builds admitted before load rises may finish. Same-tag requests serialize. At normal load, the poller keeps slot 1 when slot 2 is occupied; feature heads yield to a running sandbox guest; `release/*` heads bypass guest yielding while retaining slot and load rules. Any Atlas build outside `remote-build.sh` must be coordinated with its slots. Hyperion is one build at a time through `scripts/with-build-lock.sh` (`/tmp/c11-build.lock`; dead-owner takeover, exit 75 after 90 min), which every `reload*.sh` and `test-unit*.sh` uses. Never call `xcodebuild` bare: `scripts/with-build-lock.sh xcodebuild …`. `C11_BUILD_LOCK=0` is for single-tenant CI runners only. Uncontrolled parallel builds hit load 250 on 2026-09-11.
- **Hyperion does small loops only:** incremental builds and narrowed `-only-testing` slices, one at a time. Full suites go to Atlas or CI.
- **One Atlas tag per seat, reused.** A tag is a build cache: about 4.7 GB, and a rebuild on a warm tag takes seconds to two minutes where a fresh tag takes about five. Per-attempt tags filled Atlas on 2026-10-08. The seat that completes a ticket prunes its tags (`skills/c11-hotload/SKILL.md`, Tag hygiene).
- **PR CI stays cheap.** `ci.yml` runs workflow guards, agent-runtime checks, remote-daemon tests and web typecheck in parallel. Main requires `workflow-guard-tests`, which judges all four and always reports: on a docs-only PR (Markdown, `docs/`, `notes/`, `Localizable.xcstrings`) the `scope` job skips them and the check passes in under a minute. The complete PR Swift poller harness runs in the hourly backstop; offline activity and its memory probe use the backstop's exact-head CLI rather than a separate PR compile. `ci-timing.yml` records completed-attempt wall, queue, job and step seconds for CI, the hourly backstop and Drawbridge without mixing rerun attempts. Its `workflow_head_sha` identifies the workflow trigger, not necessarily the newer tip selected by the hourly target; the target log and green commit status identify that tested tip. Mailbox parity runs Python syntax only; native mailbox tests are in the main backstop's logic tests. The native backstop (`ci-hourly.yml`, "CI main (macOS)") has one build job followed by four independent macOS test jobs: logic, host A, host B and Python/shell checks, with the Linux poller-validation job running alongside the build. Every job is required before recording green. It runs hourly and by `workflow_dispatch` on the free `macos-15` runner; one run at a time, never cancelled, with one pending run that each newer request replaces. An admitted run tests main's tip at that moment (not its trigger), so pending pushes coalesce into the next admitted tip; a pass posts a `CI main (macOS)` commit status on the tested commit, and a run whose tip already has one skips. A failed tip lookup fails the run; a failed green-record lookup builds. The separate Atlas main-tip backstop (`scripts/c11-main-backstop.py`, install gated by the Orchestrator) posts `c11/main-atlas`, shares slot 1 with the PR poller and yields to PR work; it never writes the GitHub backstop context. Its independent install, health, update, stop and teardown are in `docs/c11-main-backstop.md`. Compatibility smoke and GhosttyKit packaging run hourly and by dispatch on `macos-15`. Only release, signing and nightly use the billed `macos-15-xlarge`; no self-hosted runner is used. Atin decides the boundary for any future access-restricted runner. Stage 11's CI tiers (`code/platform/github-actions.md`): push ≤30 s, PR ≤2 min, backstop merge-triggered or hourly and only when something changed, every test with a hard timeout. PR CI still compiles no Swift; `c11/pr-swift` is the advisory Atlas compile plus full `c11LogicTests` gate, posted by the existing Atlas user (same trust boundary as `remote-build.sh`; not a self-hosted runner and not a required check) with the Atlas `gh` login. Atlas reserves slot 1 for the poller and slot 2 as a shared lane for owner gates and all other fleet builds. At normal load, one poller build and one fleet build may overlap. Under sustained load above 40 for 60 seconds, starts serialize: a fleet build takes slot 2 only while slot 1 is idle, then holds slot 1 as a guard; a poller build takes slot 1 only while slot 2 is idle, then holds slot 2 as a guard. Both slots stay held through the build, so new builds wait; builds admitted before load rises may finish. The installed slot script changes only after merge, using the SHA-verified update procedure in `docs/c11-pr-swift-poller.md`. The armed build is Debug scheme `c11-logic` with the full `c11LogicTests` suite on eight parallel workers. Its status reports seconds and is red only for a build or test failure, including zero tests; elapsed time alone never posts failure. A successful first cold build posts success immediately, even over 120 s; zero executed tests fail and an unreadable result bundle posts error. A `release/*` head may reuse a successful main `c11/pr-swift` or `CI main (macOS)` result only when Git trees differ solely in numeric project version values, `CHANGELOG.md`, and Markdown under `docs/` or `skills/`; any non-success in either accepted context blocks reuse, and its status cites the exact main commit and context. Compile and XCTest suite wall timings are observational xcresult fields; missing timings never change the verdict. Fork PRs are not built. Live on Atlas since 2026-10-10 (LaunchAgent `com.stage11.c11-pr-swift-poller`, root `~/c11-poller`); maintenance owner Atin and the Orchestrator fleet; install, health, update, stop and teardown in `docs/c11-pr-swift-poller.md`. Historical one-class gate timings: cold pre-warm 115 s; warm builds 99 s (#632), 102 s (#586), 60 s (#585). The margin is thinnest when consecutive heads sit on different `main` bases. `scripts/host-test-quarantine.tsv` has exact `c11Tests` or `c11LogicTests` selector, scope (`all` or `atlas`), and reason columns: CI skips only `all`, while Atlas `remote-build.sh` skips both scopes and logs each scope. An exactly named `-only-testing:<target>/<class>/<method>` selector is run with its automatic skip omitted; `--no-host-quarantine` disables automatic skips. The poller update procedure stages and SHA-verifies the new poller script before stopping admission, then runs that staged script's `recover` to terminate and wait for the recorded build process tree (including descendants in other process groups), atomically replaces the scripts, and bootstraps the LaunchAgent; do not restart launchd alone while a build is active. DerivedData is keyed by dependency set (`Package.resolved` plus submodule gitlinks; at most 3 kept), because one shared cache posted false failures when heads pinned different Sparkle versions.
- **Landing gate.** Require fresh review and cheap checks at the exact PR head after merging current `origin/main`; Atlas `remote-build.sh` gates every Swift/native change. The poller rebuilds once from a clean cache after a quick linker or CodeSign failure and waits at most 10 minutes in all for guests, however many come and go. When `c11/pr-swift` still cannot post, the gate is the owner's full `c11LogicTests` run at the exact head, whose `build.log` and `result.json` the lead reads (`docs/c11-pr-swift-poller.md`). Docs-only changes are exempt only when no Swift, native workflow, script, project, submodule, test, or build input changes. Main's ruleset requires `workflow-guard-tests` but lets admin logins bypass it, and every agent merges as an admin, so GitHub will not stop an early merge: merge only after that check passes at the exact head, and never with `--admin`. After merge, a red main backstop is fixed forward.
- **QA launches suppress the startup dialogs.** A bare launch can block on the Agent Skills sheet, the "Resume previous session?" picker, and the "Turn on notifications for c11" sheet. `launch-tagged-automation.sh --qa [fresh|resume]` sets `C11_QA_LAUNCH`; `reload.sh --tag` does not. Both `fresh` and `resume` suppress those dialogs; unset leaves them. The flag is read per launch and never persisted. Policy: `Sources/QALaunchPolicy.swift`.
- **A fresh worktree needs its submodules** before any build: `git submodule update --init --recursive ghostty vendor/bonsplit`. Dirty submodules are refused by the remote route; commit and pin them first. For a local build, link the SHA-keyed GhosttyKit cache too (the build scripts repair a stale link):

  ```bash
  ln -s "${CMUX_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/cmux/ghosttykit}/$(git -C ghostty rev-parse HEAD)/GhosttyKit.xcframework" GhosttyKit.xcframework
  ```

## Testing

- **`c11-logic`** (`c11LogicTests`): logic only, no host app. Use it for Mailbox, Theme, workspace snapshots, the health parser, CLI runtime, persistence, parsers. `ci-hourly.yml` uses three parallel workers; `remote-build.sh --mode test` uses eight when all selectors target `c11LogicTests`, and `scripts/test-unit-local.sh` accepts `C11_TEST_PARALLEL_WORKERS` to enable parallel testing (the Atlas route sets eight). The Atlas poller runs the full suite on eight workers and reads its verdict from xcresult; a passing summary must report at least one executed test, and zero executed tests fail. Interactive Hyperion work may also run a narrowed local slice under the lock (`-project GhosttyTabs.xcodeproj -scheme c11-logic -destination platform=macOS test -only-testing:c11LogicTests/<Class>`). The first run after a clean checkout builds the whole app. Building `c11-unit` or `c11-ci` without the `test` action only compiles. Tests that construct a `Workspace`/`TabManager` crash the bare runner locally (`NSApp` is nil) and pass in CI; narrow to pure-logic classes and let CI cover those.
- **`c11-unit`** (`c11Tests`): host-required; spawns a DEV.app that beachballs for about 22 s. Locally, only through `scripts/test-unit-local.sh`, which isolates the socket from your running c11 and runs both test targets.
- **Atlas perf lane:** `scripts/c11-perf-lane.py` runs two command-search benchmarks from `c11LogicTests` and one corpus bridge benchmark from `c11Tests` on the current main tip once an hour through an Atlas LaunchAgent. It uses a separate checkout and DerivedData, enters the shared fleet build slot, and appends one JSONL row per benchmark to `~/c11-perf-lane/records/perf.jsonl`. It sets `C11_PERF_LANE=1`, posts no status, and never gates main. Setup, health, manual run and teardown are in `docs/c11-perf-lane.md`.
- A hung `c11LogicTests` or `c11Tests` case fails at 60 seconds and the suite continues. CI, `scripts/test-unit-local.sh` (including `remote-build.sh --mode test`), and `scripts/test-unit.sh` pass `-test-timeouts-enabled YES` with a 60-second default and maximum allowance. XCTest rounds allowances up to a minute, so 60 seconds is the effective bound.
- **`tests_v2/`** (plain `python3` socket scripts, not pytest): live runs only through `scripts/sandbox-tests-v2.sh` in a `sandbox-up.sh` guest, never against the operator's session.
- **There is no UI/e2e workflow.** Visible behavior is validated with `c11-computer-use`; clicks, drags, and app activation run in a sandbox guest, never on the operator's session. Atlas has two guest slots, shared by every run on the machine, and only the primary golden image is provisioned (C11-373): check before relying on the second slot.
- `build-for-testing` proves the tests link, not that they pass. Don't report a fix verified off it, and parse logs for `** TEST SUCCEEDED/FAILED **` rather than trusting a trailing `grep`'s exit code.
- **Window, view, event, or IME code:** iterate with a tagged build; tests go to Atlas or CI.

**Test quality.** Tests exercise runtime behavior through executable paths (unit, integration, CLI). No tests that grep source text, signatures, or AST shape, and none that read `Info.plist`, `project.pbxproj`, `.xcconfig`, or source files to assert a key exists; verify the built bundle or the behavior instead. If behavior can't be reached yet, add a small runtime seam first. If no meaningful test is practical, skip it and say so.

## Socket policies

**Threading.** Never `DispatchQueue.main.sync` on high-frequency telemetry (`report_*`, `ports_kick`, status/progress/log/metadata). Parse, validate, and coalesce off-main; hop to main with `async` only for the minimal mutation. Commands that manipulate AppKit/Ghostty state (focus, select, open, close, send key/input, exact snapshot queries) may run on main. New socket commands default to off-main; main-thread execution needs a comment explaining why.

**Focus.** Socket/CLI commands never activate c11 or raise a window. Agents cannot change any window's selected workspace: the selection setter returns `workspace_switch_blocked`, with no setting or override. `panel.focus` / `area.focus` update their target workspace's local focus, including hidden workspaces. Background creation, sends, browser automation and metadata remain allowed. Operator sidebar, shortcut, palette, notification, jump, menu and restore paths switch normally. Request focus policy is thread-local and explicitly propagated over main hops; never share a connection-wide or process-wide allowance stack. `workspace.selected` records cause; `workspace.switch_blocked` records target, method and caller panel.

## Pitfalls

- **Typing-latency hot paths.** Read before touching:
  - `WindowTerminalHostView.hitTest()` (`TerminalWindowPortal.swift`) runs on every event, keyboard included. Divider/sidebar/drag routing is gated to pointer events; add nothing outside the `isPointerEvent` guard.
  - `WorkspaceRowView` (`ContentView.swift`, the sidebar row) skips re-evaluation via `Equatable` + `.equatable()`. Don't add `@EnvironmentObject`, `@ObservedObject` (besides `workspace`), or `@Binding` without updating `==`; don't remove `.equatable()` at the `ForEach`; don't read `workspaceManager` or `notificationStore` in the body (use the precomputed `let`s).
  - `TerminalSurface.forceRefresh()` (`GhosttyTerminalView.swift`) runs per keystroke: no allocations, file I/O, or formatting.
  - No app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty's renderer wakeups.
- **`dlog` is DEBUG-only** (bonsplit's `DebugEventLog`). Gate every call with `#if DEBUG` (the logging, not the surrounding logic); CI's `build` job compiles Debug, so an ungated call only breaks at release staging.
- **`runModal()` on any agent-reachable path wedges the app.** Socket work runs through `v2MainSync`, so a nested modal loop blocks every terminal until a human clicks (C11-204: 6.8 hours). Fine only right after an operator's menu or button action. Browser modals use `browserPresentModalAlert` (`Sources/Panels/BrowserPanel.swift`).
- **Loops on long-lived threads drain an `autoreleasepool` per iteration.** A thread's root pool drains only at exit, and `leaks` won't flag what it holds. Applies to the socket accept loop, each per-connection `handleClient` thread, the hang-monitor watchdog, and any new one (C11-211: about 3 GB/day).
- **Terminal find overlay** (`PanelSearchOverlay`) mounts from `GhosttySurfaceScrollView` (AppKit portal layer), never from SwiftUI containers like `Sources/Panels/TerminalPanelView.swift`; portal-hosted terminals can sit above SwiftUI during split churn.
- **Custom drag-and-drop UTTypes** are declared in `Resources/Info.plist` under `UTExportedTypeDeclarations`.
- **Submodule commits are pushed to the Stage 11 fork's `main` first**, then the parent pointer. Never commit on a detached HEAD. For `vendor/bonsplit` verify with `merge-base --is-ancestor HEAD origin/main`; for `ghostty`, against `stage11/main` (its `origin` is manaflow-ai).
- **pbxproj edits via the `xcodeproj` gem reformat the whole file.** Review them with `xcodebuild -list`, file-membership counts, and `-showBuildSettings` spot-checks, not line diffs. Don't hand-restore whitespace.
- **A locked screen blocks every new terminal** in every c11 build: panels stay unattached and the ghostty log shows `error initializing surface err=error.OutOfMemory`. It is WindowServer refusing the GPU surface, not memory. Park the work and ask Atin to unlock; queued sends flush on attach. Don't reboot or reset anything.
- **CLI says `Socket not found` while c11 is still running:** the socket file was unlinked under a live listener. Run **Restart CLI Listener** from the command palette (Cmd+Shift+P); it rebinds without touching workspaces or PTYs. `tools/socket-watcher/` and `docs/c11-socket-unlink-diagnostic.md` catch any new unlink source.
- **Attention state stays simple.** A ticket that reaches for launch epochs, crash-durable markers, or transactional launch coordinators to track attention has hit the C11-188 failure signature (`docs/aar-c11-188-attention-loop.md`): stop and escalate.
- **Sidebar analytics are getting dense.** Before stacking more onto the workspace cards, raise a dedicated analytics screen with Atin.
- **`scripts/rebuild.sh` runs `pkill -9 -f c11`: it kills the running c11 and every agent and workspace in it.** Never run it during a live session. To validate CLI changes without bouncing the app, build only the `c11-cli` scheme (`xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-cli -configuration Debug -derivedDataPath <dir> build`) and run the fresh binary against the still-running app; app-side socket changes need an app restart the operator opts into. Worktrees need `git submodule update --init vendor/bonsplit` or the build fails.
- **Portal lifecycle debugging:** `C11_PORTAL_DEBUG=1` logs bind/detach/sync events to `/tmp/c11-portal.log` (override with `C11_PORTAL_LOG`; truncated per process). Drive churn with `scripts/repro-c11-18.sh`.

## Localization

English plus ja, uk, ko, zh-Hans, zh-Hant, ru, all in `Resources/Localizable.xcstrings`.

- Every user-facing string is localized at the call site: `String(localized: "key.name", defaultValue: "English text")`. No bare literals in `Text()`, `Button()`, alerts, menus, tooltips, or errors.
- Write English only. After adding or changing strings, hand the translation to a sub-agent (one per locale for a large batch).
- Validate with `jq . Resources/Localizable.xcstrings`, not `plutil` (which misparses JSON by extension). Check every interpolation token (`%@`, `%lld`, …) survives in all six locales; a dropped token crashes at format time.

## Ghostty and GhosttyKit

Remotes in `ghostty/`: `stage11` = our fork (`Stage-11-Agentics/ghostty`, the only one we push to), `origin` = manaflow-ai (fetch only, never push), `upstream` = ghostty-org. Commit Ghostty changes on a branch, push to `stage11`, then bump the parent pointer. To sync, fetch `origin`, merge into `main`, push `stage11 main`. Fork changes and conflict notes go in `docs/ghostty-fork.md`; keep it current.

- **A ghostty bump needs a checksum** in `scripts/ghosttykit-checksums.txt`; before merge, manually dispatch `Build GhosttyKit` against the internal bump branch, wait for the bot checksum commit, refresh PR checks at that head, then run the landing gate. The main backstop run is the post-merge check; red main is fixed forward.
- **Run 2 can stall in `action_required`** because the checksum commit is bot-authored. Approve it:

  ```bash
  for id in $(gh run list --branch <branch> --limit 5 --json databaseId,conclusion --jq '.[] | select(.conclusion=="action_required") | .databaseId'); do
    gh api -X POST repos/Stage-11-Agentics/c11/actions/runs/$id/approve
  done
  ```

- **`GHOSTTY_RELEASE_TOKEN` doesn't exist on this fork.** Workflows publish with `GITHUB_TOKEN` and `permissions: contents: write`; replace the secret in anything copied from upstream.
- **Artifact releases never take the `latest` slot.** Sparkle reads `releases/latest/download/appcast.xml`; an `xcframework-*` or nightly release marked latest 404s the feed and every shipped c11 reports `SUSparkleErrorDomain(2001)`. Publish with `--prerelease --latest=false` (`prerelease: true` / `make_latest: false`). Check: `gh api repos/Stage-11-Agentics/c11/releases/latest --jq .tag_name` prints a `v*` tag.
- **Workflows that commit back** use `ref: ${{ github.head_ref || github.ref_name }}` on `actions/checkout`, or the push fails with exit 128.
