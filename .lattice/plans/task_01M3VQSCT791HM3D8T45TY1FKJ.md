# C11-251 plan

Base: `origin/main` at `dedc6007a5bb886388af23d7c48c48d76025772f`.

## Scope and design

The reported cron incident is that targetless `c11 clear-status <key>` reaches the v1 resolver and acts on the selected workspace. Apply the same explicit-target rule to `clear-status`, `clear-progress`, `clear-log`, `list-status`, `list-log`, and text/JSON `sidebar-state`.

- `CLI/c11.swift`: accept `--workspace`, `C11_WORKSPACE_ID`, and the existing hidden `CMUX_WORKSPACE_ID` compatibility alias. Fail clearly if none resolves. A global `--window` scopes lookup but is not a workspace target by itself; when combined with an explicit workspace, normal scoped-window validation applies. Update command help.
- `Sources/TerminalController.swift` and `Sources/Metadata/SocketTabRefValidator.swift`: reject missing v1 `--tab` targets for the six text operations, so raw socket callers cannot fall through to selected context. Generalize the validator's rejection wording.
- `Sources/SocketHandlers/MiscHandlers.swift`: require an explicit workspace/tab ref for v2 `sidebar.state` before resolving a workspace.
- `tests_v2/test_cli_sidebar_metadata_commands.py`: use isolated workspaces and sentinel metadata to exercise targetless, `--window`-only, environment, explicit-workspace, compatibility-alias, and raw-socket behavior.
- `skills/c11/SKILL.md` and `skills/c11/references/api.md`: document workspace targeting and that `--window` alone is insufficient. Do not sync the installed skill; the Merge Captain owns that step.
- New localized defaults: `cli.sidebar.target.required`, `socket.tabRef.empty.noSelectedFallback`, `socket.tabRef.missing.noSelectedFallback`, `socket.sidebar.state.targetRequired`. English defaults only; C11-291 owns the locale pass.

No focus or threading changes: target validation runs before existing metadata operations. No persistence, schema, UI, or tenant-config changes.

## Acceptance and evidence

1. **Cron incident fixture:** with synthetic workspace A selected and seeded with status, progress, and log sentinels, each of the six CLI commands with neither `--workspace` nor workspace env exits with a target error; the same commands with only global `--window` also fail. A's sentinels remain unchanged. The targeted `tests_v2/test_cli_sidebar_metadata_commands.py` exercises this against the launched tagged app in the Atlas sandbox guest.
2. **Target routing:** explicit `--workspace` and `C11_WORKSPACE_ID` route list/clear/state operations to synthetic workspace B only; A remains unchanged. Explicit workspace beats the environment. The hidden `CMUX_WORKSPACE_ID` alias remains compatible. A workspace ref paired with `--window` works only within that window. Verify through CLI output and raw v2 `sidebar.state` with an explicit workspace.
3. **Socket boundary:** direct v1 clear/list/state calls without `--tab` and v2 `sidebar.state` without workspace/tab ref return `missing_ref`; targeted v2 state succeeds. Verify through the same behavioral script, not source inspection.

Run `c11LogicTests/SocketTabRefValidatorTests` through the Atlas test route and the behavioral script through `scripts/sandbox-tests-v2.sh` in an isolated Atlas guest. Build the tagged Debug app and launch it on Atlas with `C11_QA_LAUNCH=fresh`; no computer-use step is needed because acceptance is socket/CLI behavior. Record the test output and Atlas launch identity on the ticket.

Cut line: do not change sidebar write semantics, unrelated metadata commands, other socket target rules, or tenant configuration.
