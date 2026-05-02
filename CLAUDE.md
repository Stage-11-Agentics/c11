# c11 agent notes

## Mission

c11 is a macOS command center for the operator:agent pair. Terminals, browsers, and markdown surfaces composed in one window — addressable, scriptable, held in one field of view while many agents work in parallel. It embeds Ghostty as the terminal engine and treats the workspace itself as the atom of work.

Short name: **c11**. Formal long name (publicly): **c11 terminal multiplexer**. Use the short form in CLI, UI, filenames, and default prose; reach for the long form for first references in formal external contexts (press, docs landing pages, legal copy).

Theme naming: in user-facing product copy, say **c11 theme** and **Light/Dark theme slots**; reserve **chrome theme** for internal code/socket disambiguation from Ghostty terminal themes.

**Who it's for.** The operator running eight, ten, thirty agents at once. The one already feeling the pain of `cmd-tab` roulette across a screen full of terminal windows and wanting structure — not less work, just enough shape that the whole orchestra stays legible while the agents drive.

**What that implies for this codebase.** Every surface has a handle. Every handle is scriptable from outside the process. Agents are first-class; the CLI and socket exist so they can compose their own environment without the operator in the loop for routine moves.

## Lineage

tmux → [cmux](https://github.com/manaflow-ai/cmux) → c11. tmux was for humans driving shells. cmux by [manaflow-ai](https://github.com/manaflow-ai) is the parent — the Ghostty embed, the browser substrate, and the CLI shape all belong to them upstream. c11 is the fork-level iteration for the operator:agent pair: more primitives (markdown surfaces, addressable surface handles, the skill system, agent-written sidebar telemetry), same ancestry. The tab bar and split chrome come from [Bonsplit](https://github.com/almonk/bonsplit) by [almonk](https://github.com/almonk), forked in `vendor/bonsplit/`.

### The cmux ↔ c11 relationship is bidirectional

Both projects are open source. The relationship between them is unusual and worth making explicit so nobody has to guess:

- **Upstream → c11 (pull).** We may cherry-pick or merge PRs and commits from `manaflow-ai/cmux` when they fix bugs, improve performance, or add primitives we want. Credit stays with the original authors in the commit metadata. Don't rewrite their code to look like ours; import it cleanly so the provenance is obvious and future syncs stay clean.
- **c11 → upstream (suggest).** When a fix or improvement made in c11 would also benefit cmux — a bug fix in a shared code path, a performance win in Ghostty embedding, a CLI ergonomics improvement that isn't c11-specific — surface it. Options: open a PR against `manaflow-ai/cmux` directly, or flag it to the operator with a one-line note so they can decide. Default to offering the fix upstream; c11-specific work (skill system, agent telemetry, markdown surfaces, operator-centric primitives) stays here.
- **What stays c11-only.** Anything that only makes sense under "the operator:agent pair is the unit" framing. Agent-facing primitives, skill infrastructure, sidebar telemetry written by agents, the c11 brand surface. These are fork-level by design.

**Practical implication for agents working in this repo:** when you touch a file that clearly came from upstream and your fix isn't c11-specific, flag it. The operator can decide whether to land it here, upstream, or both. Don't silently diverge on shared code — it makes future upstream merges painful and costs both projects improvements they'd otherwise share.

Treat upstream patterns as load-bearing unless you have a specific reason to diverge. Gratuitous divergence burns goodwill and future merge bandwidth.

## The skill is the agent's steering wheel

c11's value to an agent is **the skill** — `skills/c11/SKILL.md` plus the peer skills (`c11-browser`, `c11-markdown`, `c11-debug-windows`, `c11-hotload`, `release`). An agent that's read the skill learns to split panes, open markdown surfaces, drive the embedded browser, report status to the sidebar, and navigate the workspace as infrastructure. An agent that hasn't just sees another terminal.

**The bar: fast, fluid, effective.** An agent should be able to fully drive a c11 session — spawning the surfaces it needs, dissolving them when done, reporting progress, recovering from its own mistakes — without the operator having to intervene for routine moves. That only happens if the skill teaches it how, accurately, tersely, and in the exact shape of the CLI that ships.

**Therefore:** every change to the CLI, socket protocol, metadata schema, or surface model is incomplete until the skill is updated to match. If you add a command, add it to the skill. If you rename a command, rename it in the skill. If you change defaults, update the examples. The skill is the contract; let it rot and agents get worse at using c11. Invest there first, not last.

## Computer use is a maintainer validation skill, not the c11 operating skill

There are two different genres here; do not blur them:

- **Agent operating skill (`c11`).** Teaches an agent inside c11 how to use the room: split panes, open surfaces, target handles, report status, drive browser/markdown surfaces, and compose its own working environment.
- **Maintainer validation skill (`c11-computer-use`, planned).** Teaches a maintainer/developer agent how to test c11 as a product through the real macOS UI: screenshots, clicks, keyboard focus, pane readability, visual recovery, and user-path validation.

The distinction matters. Socket/CLI commands are excellent for setup, orchestration, recovery, and deterministic oracle checks, but they do not prove that a human-visible workflow works. Computer use should validate behaviors that are visual, spatial, focus-sensitive, pointer-driven, or human-ergonomic.

When validating c11 with computer use:

- Launch only tagged builds (`./scripts/reload.sh --tag <tag>` and `./scripts/launch-tagged-automation.sh <tag>`). Never launch an untagged `c11 DEV.app`.
- Default handoff is a fresh c11 surface running interactive Codex: create a new terminal pane/surface, run `codex --yolo`, then send a file-backed expert prompt. Do not use `codex exec` for watched validation panes.
- The expert prompt should name the target tagged app/window, the scenario, success criteria, safety boundaries, artifact expectations, and the caller's workspace/surface refs so Codex can report back with `c11 send` or leave a readable result for `read-screen`.
- This pattern is cross-agent: Claude Code can delegate visual validation to Codex, and Codex can delegate a clean computer-use pass to another Codex surface. Keep the handoff explicit so the validation context is fresh and inspectable.
- Use the socket as setup/oracle infrastructure, not as a substitute for the UI path being tested.
- Capture screenshots and scenario artifacts for claims about visible behavior.
- Inspect `c11 tree --no-layout` before calling a run successful. If important panes are too small for a human to read, rebalance them and treat that as part of the validation, not cleanup.
- Prefer repeatable harness scenarios for comparisons across providers. Manual computer-use runs are useful, but they should feed back into reusable scenarios and skill guidance.

The lesson from the OpenAI CUA runner work: "it executed" is not enough. If the resulting workspace is hard for the operator to read, the validation found a product/workflow issue worth preserving.

## Principle: unopinionated about the terminal

c11 is **host and primitive, not configurator.** It provides surfaces, panes, a socket, a CLI, and a metadata seam — all scoped to c11's own runtime. The operator's tenant config files (`~/.claude/settings.json`, `~/.codex/*`, `~/.kimi/*`, shell rc files, etc.) are off-limits: c11 never reaches in to install hooks, persist configuration, or inject behavior into any TUI's on-disk state.

**One narrow exception: session-resume wrappers under `Resources/bin/`.** When a TUI's lifecycle is otherwise opaque to c11, c11 may ship a PATH-scoped wrapper that captures the minimum lifecycle signal needed for *session resume* across c11 reboots. The wrapper must:

- Live in c11's own bundle, prepended to PATH **only inside c11 terminals** (gated on `CMUX_SURFACE_ID` + a live socket).
- Make **no persistent writes** to tenant config, dotfiles, or any path outside c11's own runtime (`/tmp` is fine; `~/.claude/`, `~/.codex/`, etc. are not).
- Capture only the minimum needed for session resume — usually a session id and `terminal_type`, plus lifecycle status where the TUI exposes it (Claude Code does via hooks; codex does not).
- Fall through to the real binary unchanged when outside a c11 terminal or when the c11 socket is unreachable.

`Resources/bin/claude` is the reference implementation. New TUIs (codex, opencode, kimi, …) may add equivalent wrappers under the same constraints.

Consequences:

- **`c11 install <tui>` remains rejected.** Any proposal that writes to a user's persistent tool config is a non-starter, even with consent prompts and markers. The wrapper pattern is the upper bound on what c11 reaches for; persistent writes to tenant config are still off-limits. The 691-line installer spec (since removed; see `notes/cmux-40-*` for the post-mortem) exists only as historical artifact.
- **Skill-driven self-reporting is still the standard pattern** for status/lifecycle telemetry. Agents that read the c11 skill learn to call `c11 set-metadata` / `c11 set-status` from their own lifecycle. The `cmux` CLI is a compat alias that dispatches to the same binary. The session-resume wrappers do not replace this — they handle only the resume capture path that the skill cannot, because they have to run *before* the agent process exists.
- **The skill file is the only outgoing touch for behavior.** How it reaches each TUI (cc's `~/.claude/skills/`, codex's equivalent, etc.) is the operator's problem, not c11's.

When in doubt: c11's job stops at the edge of its surfaces, save for the narrow session-resume rail above. What happens inside an agent's process is the agent's business.

## Default workflow for Lattice tickets: lattice-delegate

When the operator hands you a Lattice ticket to execute (or asks to "run", "delegate", "walk through" a ticket), the default response is the `lattice-delegate` skill at `/Users/atin/Projects/Stage11/.claude/skills/lattice-delegate/SKILL.md`. Do not attack the ticket inline from the orchestrator pane.

Why this is the default here:
- c11 tickets routinely involve typing-latency hot paths, tagged builds, localization passes, and submodule discipline. The delegator pattern carves a worktree per ticket so build artifacts and submodule state cannot bleed across parallel work.
- Multi-phase work (plan → impl → review → validate → handoff) is hard to keep coherent in a single chat. Surfaces-per-phase plus a Lattice-as-comms-bus give every reader (operator, future agent, retro-AAR) a clean trail.
- Trident reviews produce a `synthesis-action.md` that the Review sibling executes against directly; the delegator only sees items that genuinely need human or delegator judgment.

Skip the pattern only when the ticket is a one-line text edit, a trivially mechanical change with no review surface, or the operator explicitly says "just do it inline." When in doubt, default to the skill.

## Local dev

See `skills/c11-hotload/SKILL.md` for the full workflow — `reload.sh --tag` build-and-launch, Release variants, the debug event log, tag hygiene, and the tagged-build reporting format.

The one-liner: after any code change, `./scripts/reload.sh --tag <your-branch-slug>`. Never `open` an untagged `c11 DEV.app`.

## Pitfalls

- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.stage11.c11.tabtransfer`, `com.stage11.c11.sidebar-tab-reorder`).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- **Typing-latency-sensitive paths** (read carefully before touching these areas):
  - `WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift`: called on every event including keyboard. All divider/sidebar/drag routing is gated to pointer events only. Do not add work outside the `isPointerEvent` guard.
  - `TabItemView` in `ContentView.swift`: uses `Equatable` conformance + `.equatable()` to skip body re-evaluation during typing. Do not add `@EnvironmentObject`, `@ObservedObject` (besides `tab`), or `@Binding` properties without updating the `==` function. Do not remove `.equatable()` from the ForEach call site. Do not read `tabManager` or `notificationStore` in the body; use the precomputed `let` parameters instead.
  - `TerminalSurface.forceRefresh()` in `GhosttyTerminalView.swift`: called on every keystroke. Do not add allocations, file I/O, or formatting here.
- **Terminal find layering contract:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), not from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Submodule safety:** When modifying a submodule (ghostty, vendor/bonsplit, etc.), always push the submodule commit to its remote `main` branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch — the commit will be orphaned and lost. Verify with: `cd <submodule> && git merge-base --is-ancestor HEAD origin/main`.

## Localization

c11 ships in English plus six translations: Japanese (ja), Ukrainian (uk), Korean (ko), Simplified Chinese (zh-Hans), Traditional Chinese (zh-Hant), and Russian (ru). All strings live in `Resources/Localizable.xcstrings`.

- **Write English only.** The `defaultValue:` in `String(localized:)` is the source of truth. Don't hand-author other languages in product code — that's a separate pass.
- **All user-facing strings must be localized at the call site.** Use `String(localized: "key.name", defaultValue: "English text")` everywhere — labels, buttons, menus, alerts, tooltips, error messages. No bare string literals in SwiftUI `Text()`, `Button()`, alert titles, etc.
- **Delegate translation to a sub-agent in a new c11 surface.** After adding or changing English strings, spawn a translator in a fresh c11 pane to sync `Localizable.xcstrings` for the other six locales. Point it at the new/changed English values; it reads the xcstrings, emits the six translations, writes back.
- **Parallelize when there's a lot to translate.** For a handful of strings, one sub-agent is fine. For a larger batch, spawn one sub-agent per locale — six in parallel — so the translation pass doesn't gate the next piece of work.

## Test quality policy

- Do not add tests that only verify source code text, method signatures, AST fragments, or grep-style patterns.
- Do not add tests that read checked-in metadata or project files such as `Resources/Info.plist`, `project.pbxproj`, `.xcconfig`, or source files only to assert that a key, string, plist entry, or snippet exists.
- Tests must verify observable runtime behavior through executable paths (unit/integration/e2e/CLI), not implementation shape.
- For metadata changes, prefer verifying the built app bundle or the runtime behavior that depends on that metadata, not the checked-in source file.
- If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first, then test through that seam.
- If no meaningful behavioral or artifact-level test is practical, skip the fake regression test and state that explicitly.

## Testing policy

**Never run tests locally.** All tests (E2E, UI, python socket tests) run via GitHub Actions or on the VM.

- **E2E / UI tests:** trigger via `gh workflow run test-e2e.yml` (see cmuxterm-hq CLAUDE.md for details)
- **Unit tests:** `xcodebuild -scheme c11-unit` is safe (no app launch), but prefer CI
- **Python socket tests (tests_v2/):** these connect to a running c11 instance's socket. Never launch an untagged `c11 DEV.app` to run them. If you must test locally, use a tagged build's socket (`/tmp/c11-debug-<tag>.sock`) with `C11_SOCKET=/tmp/c11-debug-<tag>.sock` (or `CMUX_SOCKET=…` as compat).
- **Never `open` an untagged `c11 DEV.app`** from DerivedData. It conflicts with the user's running debug instance.

## Socket command threading policy

- Do not use `DispatchQueue.main.sync` for high-frequency socket telemetry commands (`report_*`, `ports_kick`, status/progress/log metadata updates).
- For telemetry hot paths:
  - Parse and validate arguments off-main.
  - Dedupe/coalesce off-main first.
  - Schedule minimal UI/model mutation with `DispatchQueue.main.async` only when needed.
- Commands that directly manipulate AppKit/Ghostty UI state (focus/select/open/close/send key/input, list/current queries requiring exact synchronous snapshot) are allowed to run on main actor.
- If adding a new socket command, default to off-main handling; require an explicit reason in code comments when main-thread execution is necessary.

## Socket focus policy

- Socket/CLI commands must not steal macOS app focus (no app activation/window raising side effects).
- Only explicit focus-intent commands may mutate in-app focus/selection (`window.focus`, `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`, browser focus commands, and v1 focus equivalents).
- All non-focus commands should preserve current user focus context while still applying data/model changes.

## Ghostty submodule workflow

Ghostty changes must be committed in the `ghostty` submodule and pushed to the `manaflow-ai/ghostty` fork. Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

```bash
cd ghostty
git remote -v  # origin = upstream, manaflow = fork
git checkout -b <branch>
git add <files>
git commit -m "..."
git push manaflow <branch>
```

To keep the fork up to date with upstream:

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push manaflow main
```

Then update the parent repo with the new submodule SHA:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## GhosttyKit xcframework and checksums

When the ghostty submodule SHA changes, `scripts/ghosttykit-checksums.txt` must have a matching entry or CI fails across `build`, `workflow-guard-tests`, and `compat-tests`. The entry is auto-generated by the `build-ghosttykit` workflow — you don't add it manually.

**Expected CI pattern after a ghostty bump:** run 1 will show the three guard jobs red (they fire before the 10-minute Zig build finishes). After `build-ghosttykit` completes, it downloads or uses the just-built tarball, computes the SHA256, and pushes the checksum commit. Run 2 (triggered by that push) goes fully green. Run 1 red is expected — check whether `build-ghosttykit` is still in progress before treating it as a real failure.

**`GHOSTTY_RELEASE_TOKEN` is not configured on this fork.** Any workflow step using that secret will get an empty `GH_TOKEN` and fail with exit code 4. xcframework releases are published to `Stage-11-Agentics/c11` using `GITHUB_TOKEN` with `permissions: contents: write`. If you copy a workflow from upstream that references `GHOSTTY_RELEASE_TOKEN`, replace it.

**Workflows that commit back to the branch must use `ref: ${{ github.head_ref || github.ref_name }}`** on their `actions/checkout` step. Without it, Actions checks out a detached merge commit and `git push` fails with exit 128.

## Release

See `skills/release/SKILL.md`. Invoke with `/release`.
