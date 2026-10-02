# C11-269 plan

## Citations (base `0ff8887e`)

Match. `CLI/c11.swift:18117-18118` sets `SIG_IGN` in `main` so `c11SafeWrite` (`:18094`) gets `EPIPE` instead of abort (C11-210, crash c11-2026-08-12). `runClaudeTeams` (`:15820-15834`) `execv`s a resolved path or `execvp`s `claude` without restoring the default, so the child inherits `SIG_IGN`. The backlog's line 17639 is not this code.

`SkillInstallerTarget.supportsPlugins` (`Sources/SkillInstaller.swift:54-56`) is true only for OpenCode. `installPlugins` (`:776-874`) `createDirectory`s `~/.config/opencode/plugins/` and copies `c11-notify.js` plus a `.c11-plugin.json` sidecar. Callers: `CLI/c11.swift:18511` (`skill install`) and `Sources/AgentSkillsView.swift:178` (Settings). `removePlugins` (`:879`) deletes only a sidecar-marked file and is called from `skill remove` (`:18573`) and Settings remove (`:209`). `Resources/bin/opencode:73-92` already loads the bundled plugin per process via `OPENCODE_CONFIG_CONTENT`, else `OPENCODE_CONFIG=/dev/fd/3`, and leaves both alone when both are set. It does not write tenant config.

## SIGPIPE

Immediately before the `execv` / `execvp` pair in `runClaudeTeams`, `signal(SIGPIPE, SIG_DFL)`. On exec failure, restore the previous disposition before throwing, so the CLI's own `c11SafeWrite` path stays `SIG_IGN`. Do not change `main` or `c11SafeWrite`. No other exec sites.

## OpenCode plugin

`supportsPlugins` returns false. `installPlugins` and `removePlugins` return without creating, copying, or deleting, even if called directly. Skill install/update still runs `SkillInstaller.install` (skills only). Settings and `skill remove` stop reaching into `plugins/`.

`Resources/bin/opencode` stays as it is. `skills/opencode-plugins/c11-notify.js` stays in the bundle.

## Copies already on disk

Do not delete them. `~/.config/opencode/plugins/` is OpenCode's directory, shared with the user's plugins. A `.c11-plugin.json` sidecar marks files c11 once wrote, but the user may have edited the `.js`, and the directory is tenant config, not a c11-owned tree. Doctrine and this ticket's Out line already forbid the delete, so this is not an Atin decision.

Until the operator removes them, OpenCode can load the old plugin in addition to the wrapper's per-process copy. Docs say that plainly and do not claim the duplicate is gone. Operator cleanup, not performed by c11: inspect/back up `~/.config/opencode/plugins/c11-notify.js` and `c11-notify.c11-plugin.json`, then remove them manually if the operator chooses to retire that installed copy. Do not recommend blind deletion of an edited/user-owned plugin merely by filename. No new uninstall command.

## Acceptance → incident → test → Atlas proof

1. A fake Claude through `c11 claude-teams` sees `SIGPIPE` at `SIG_DFL` on both routes; the CLI still exits cleanly when its reader closes. Incident: inherited `SIG_IGN` from `main`; C11-210 abort. Test: `tests/test_claude_teams_sigpipe.py` against `C11_CLI`. Route 1: a non-wrapper fake `claude` first on `PATH` (`execv` of the resolved path). Route 2: copy the CLI to a temp dir with no sibling `claude`, and put on `PATH` a fake whose first 512 bytes contain `cmux claude wrapper - injects hooks and session tracking` so `resolveClaudeExecutable` (`:15687`) skips it and `execvp` runs it. Both print `DFL`. Regression: spawn `c11 help` with stdout/stderr pipes closed immediately; exit status is not SIGPIPE (`-13` / 141). Atlas: same script against the tagged CLI.
2. OpenCode skill install/update on a temp home leaves `plugins/` absent when it started absent, and leaves a pre-seeded `c11-notify.js`, its sidecar, and an unrelated file byte-identical. Skills still install. Incident: `installPlugins` creates and copies. Test: `c11LogicTests` call `SkillInstaller.install` and `installPlugins` on a temp home with a fixture source. Assert the skill dir gained the package and the plugin bytes did not change. Atlas: `c11 skill install --tool opencode --home <temp>` from the tagged CLI, same assertions.
3. A live wrapper launch loads the bundled plugin when a runtime slot is free; an existing `OPENCODE_CONFIG_CONTENT` is kept and the fd/3 fallback is used. Incident: none new; lock the rail so the install change cannot regress it. Test: extend `tests/test_opencode_wrapper_hooks.py` (already covers the free slot and the content-occupied slot). Atlas: run that script; no app required.
4. No socket, or outside c11: exec the real binary, no config exports. Both `OPENCODE_CONFIG_CONTENT` and `OPENCODE_CONFIG` set: neither value changes, and a temp `HOME` grows no `plugins/` file. Incident: doctrine, persistent plugin as compensation. Test: two cases added to the same wrapper script. Atlas: same script.
5. Help and docs no longer say to persist `c11-notify.js`, and they say leftovers are left in place. Incident: `skillCommandUsage` (`CLI/c11.swift:18280-18284`), `docs/notifications.md:109-144`, `skills/c11/references/api.md` and `orchestration.md`. Edit those, plus the header comment in `skills/opencode-plugins/c11-notify.js` and the one install sentence in `docs/agent-exact-resume-plan.md`. `c11 skill` help text is the assertion (run the CLI, read stdout). Never sync or edit installed skills. The Merge Captain alone syncs these source changes from merged main. No new UI strings, so no xcstrings keys.

## Hot path, threading, persistence

None. `signal` runs once on the CLI thread before exec. Install I/O is the existing skill copy, off any typing path. No snapshot or session change. No tenant writes.

## Cut

Undoing C11-210. A process-wide signal redesign. Deleting or rewriting anything under `~/.config/opencode`. OpenCode resume (C11-151). New adapters. A doctrine rewrite (J8 / C11-278). No status change on those tickets.

## Dependencies

None. C11-210 must stay green. Wrapper runtime plugin stays. Atlas (C11-216) for the CLI probes.

## Decisions

None for Atin. Owner call: leftovers stay until the operator deletes those two filenames by hand.

## Codex takeover corrections (base 0ff8887e5e)

No build/test/product change performed. Citations and the exec-boundary restoration above match this base. Tests use a native signal-disposition helper (built on Atlas): a Python helper resets SIGPIPE itself at interpreter startup and therefore cannot observe inherited disposition reliably. Assert the helper's actual `sigaction` result on both exec routes, plus an exec-failure case returning through the CLI safe-write/error path.

Expand the installer cases to direct `removePlugins`, `skill remove` and Settings remove, with old managed and edited-plugin fixtures plus unrelated files unchanged. Both install/update and removal become plugin no-ops; ordinary skill operations still succeed. The existing `--home` CLI option is verified at `CLI/c11.swift:18291,18412`; seed `.config/opencode` for target detection without creating its `plugins` directory.

The inherited plan's “script, no app required” proof only covers the fake wrapper. Retain it, then perform the ticket's real packaged-path check: on Atlas after C11-216 and BUILD MODE, launch the tagged app with `C11_QA_LAUNCH=fresh`, use its bundled wrapper and real OpenCode in a disposable terminal with synthetic content, and observe one lifecycle event through the tagged socket/journal plus the corresponding tab metadata. Record exact CLI/app/head and distinguish this observation from fake-executable config assertions. No persistent plugin writes compensate for occupied runtime config slots; label that degraded case. Finish by closing the disposable workspace. No new Settings UI text is planned; any changed user-facing Swift label must have an English localization key and C11-291 handoff.

Respect C11-257's shared CLI/dispatch/wrapper file barrier before integration, even where intended hunks differ. C11-278 owns the doctrine chapter; preserve this ticket's explicit old-plugin residual there. No Atin decision: the authorized cut already excludes deletion of tenant files.


## Build-mode refresh (2026-10-01)

Branch c11-1.0/C11-269-runtime-hygiene starts at fresh origin/main 7bb785741750ddeb8ab12b4cf6472593fb8c3550, with Atlas C11-216. Current exec boundary is CLI/c11.swift:15900-15904; global SIGPIPE ignore at18251 remains untouched. Only exec reset/error restoration and skill help change in CLI; send/mailbox/SocketClient stay untouched. SkillInstaller plugin entry points become unconditional no-ops, so existing CLI/Settings capability guards skip them. Add SkillInstallerPluginBoundaryTests to c11LogicTests by hand; no project rewrite. The bundled runtime wrapper stays unchanged; notification and API/orchestration wording describes its current config-slot precedence, transparent fall-through and operator-controlled old-copy cleanup. No new user-facing Swift localization key. docs/agent-exact-resume-plan.md currently has no persistent-install instruction and needs no edit.

Use exact-head targeted Atlas logic tests and built CLI signal/helper probes. Per current go-owner low-risk validation flow, provide a numbered batch Validator scenario for actual OpenCode lifecycle and Settings installation; attempt a tagged packaged-path smoke where available. No heavy Hyperion builds or production app/config mutation. No new PR before handoff. C11-258 remains in review/CI; pause this work cleanly if its bundled repair arrives.


## Implementation validation refresh

Disable plugin capability and make direct installPlugins/removePlugins unconditional no-I/O compatibility entry points, including force and missing-source calls. Ordinary skill install/refresh/remove remains active; persistent old plugins and sidecars remain untouched. Native sigaction observer calibrates IGN/DFL preservation, exercises both exec routes and both failed-exec closed-error-pipe paths. Use --help/--version for output calibration without a socket; bare help first connects and cannot be tested with an intentionally missing socket. Installer fixtures normalize Foundation's /var and /private/var URL components before comparing tenant snapshots.

Fresh-context review repaired old contradictory OpenCode wrapper/install prose and corrected the documented skill destination to ~/.config/opencode/skills. No installed source sync is authorized. Final integration merges main 2d2440ac65425b0041aad2b3117f6c1c5e612768 without conflicts; preserve the SIGPIPE boundary, plugin no-ops and executable fixtures. Rerun targeted Atlas installer assertions and native CLI/wrapper probes at the integrated head before draft-PR handoff. Packaged OpenCode lifecycle and Settings installation are numbered batch Validator scenarios under the current low-risk ruling, not claimed per-ticket proof.
