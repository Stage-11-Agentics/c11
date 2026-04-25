# cmux residue and follow-ups (2026-04-24)

Captured at the end of the privacy/telemetry sweep that retargeted PostHog and Sentry away from the upstream cmux org and cut leak strings out of shipped code. This file is the punch list of what's left: naming residue, env-var decisions, and a few open follow-ups. It is not load-bearing for shipping — the privacy fixes are landed.

## What just landed

- `2be8f36a` Sentry DSN (app + CLI) retargeted to `stage-11-kl` org.
- `4fd49cbf` PostHog event names, env vars, platform tag renamed cmux → c11.
- `ad52caee` PostHog `stage11-c11` project provisioned and key embedded.
- `de54cfb4` Feedback default endpoint blanked; `founders@manaflow.com` → `hello@stage11.ai` everywhere it appears in user-visible copy (English + 6 translated locales + UI test); About-panel docs link → `https://github.com/Stage-11-Agentics/c11`; update-history commit links repointed off `manaflow-ai/cmux`.

After these commits, no shipped Swift, plist, xcstrings, or entitlement file references `cmux.com`, `manaflow.com`, or `manaflow-ai/cmux` as a runtime target.

## Open follow-ups

These are real work items, not just naming polish.

1. **Stand up a Stage 11-owned feedback endpoint.** The default is now empty, so feedback submission no-ops in shipped builds. Either bring up an endpoint at `feedback.stage11.ai` (or wherever) and embed it as `defaultEndpoint`, or remove the feedback UI entirely and direct users to `hello@stage11.ai` / GitHub issues. Decision needed.
2. **Create a `stage11-c11` Sentry project.** The app currently uses the org's default DSN (`o4511028450295808/4511028453900288`). Cleaner to provision a dedicated `stage11-c11` project under `stage-11-kl` and swap the DSN. Needs the Sentry org auth token from 1Password (`Stage11-Platform / <sentry-item>` — first sweep couldn't find an item literally named `Sentry`; verify the actual item name).
3. **Stand up a c11 docs site, or accept the GitHub repo as docs.** About-panel "Docs" link currently points at `https://github.com/Stage-11-Agentics/c11`. Fine for now, but if a real docs site exists later, point it there.
4. **Push the `platform/posthog.md` doc update.** Local commit `bf7b83d` records the new `stage11-c11` project and revises the policy so public PostHog project keys live in the markdown rather than 1Password. Not yet pushed; this conversation only authorized direct-to-main on `c11`, not `platform`.

## Naming residue

Categorized by how safe each is to rename. The standing rule (memory: `feedback_cmux_to_c11_naming.md`) is: rename cmux/CMUX/cmuxterm to c11/C11 when you visit the file, except for deliberate exceptions (lineage talk, the `cmux` CLI compat alias, pref-migration shims).

### Safe to rename (low risk, internal symbols)

These are window IDs, notification names, and other internal identifiers nothing external depends on. Mass-rename in a single pass is reasonable.

| Area | Files | Rough count |
|------|-------|-------------|
| Window/debug `NSUserInterfaceItemIdentifier("cmux.*")` | `Sources/c11App.swift` (~12 sites around lines 1533–1542, 1830, 1867, 2095, 2399, 2436, 2800, 2834, 2885, 3047, 3460, 3630, 6928); `Sources/ContentView.swift:916` | ~13 |
| Internal `Notification.Name("cmux.*")` | `Sources/TabManager.swift:5303–5326`, `Sources/KeyboardShortcutSettings.swift:6`, `Sources/c11App.swift:3015`, `Sources/ContentView.swift:9068–9069`, `Sources/TerminalController.swift:9–11` | ~17 |
| Debug filename / error string | `Sources/c11App.swift:1473` (`cmux-theme-dump-…`), `Sources/c11App.swift:245` ("refusing to launch untagged cmux DEV") | 2 |
| Test fixture paths | `c11Tests/GhosttyConfigTests.swift` (theme paths, suite names — needs source-side rename of `cmuxAppSupportConfigURLs` first) | ~15 |

Recommended approach: dedicated commit per cluster (notification names, then window IDs, then test fixtures with the source rename). Don't bundle the env-var decisions below into the same commits.

### Operator decision (compat surface)

These look like cmux residue but probably need to stay for backward compat with the `cmux` CLI alias, shell integration, and external automation. Revisit only if we're willing to make a clean break.

| Symbol | Where | Why it likely stays |
|--------|-------|---------------------|
| `CMUX_SHELL_INTEGRATION` | `Resources/shell-integration/cmux-{bash,zsh}-integration.{bash,zsh}` and detection in CLAUDE.md | Documented load-bearing for compat; renaming breaks shell integration scripts users have already sourced. |
| `CMUX_SOCKET`, `CMUX_SOCKET_PATH`, `CMUX_SOCKET_ENABLE`, `CMUX_SOCKET_MODE` | `Sources/SocketControlSettings.swift:442, 449, 631, 648` | External agents/automation address the c11 socket through these vars. |
| `CMUX_FEEDBACK_API_URL` | `Sources/ContentView.swift:8693` | Runtime override; renaming breaks any operator-side scripts that already export it. |
| `CMUX_BUNDLE_ID` | `CLI/c11.swift:73` | Used by the CLI when embedded as a child of `c11.app`. |
| `CMUX_DISABLE_*`, `CMUX_UI_TEST_*`, `CMUX_RESTORE_SCROLLBACK_FILE` | `Sources/SessionPersistence.swift:34, 52, 68, 149, 152, 180, 534` | Internal test/debug toggles; *probably* safe to rename, but check that Stage 11 CI doesn't set them under the old name first. |
| `CMUX_POSTHOG_ENABLE`, `CMUX_POSTHOG_DEBUG` | (already renamed → `C11_POSTHOG_*` in `4fd49cbf`) | Done. Listed here so the policy is visible. |

Suggested path: introduce `C11_*` aliases for each of the above and keep the `CMUX_*` names working as fallbacks for at least one minor release. Document the migration in CHANGELOG.md.

### Leave alone (deliberate)

These are not residue — they are correctly cmux-named and should stay. Re-flagging here so future audits don't undo them.

| File:line | Content | Why |
|-----------|---------|-----|
| `Sources/c11App.swift:3069` | `upstreamURL = URL(string: "https://github.com/manaflow-ai/cmux")` | About-panel attribution to the upstream project. |
| `Sources/c11App.swift:3070` | `forkURL = URL(string: "https://github.com/Stage-11-Agentics/c11mux")` | About-panel attribution to the `c11mux` fork stage. |
| `Sources/GhosttyTerminalView.swift:1230` | Comment: `// See: https://github.com/manaflow-ai/cmux/pull/1017` | Historical context for an upstream PR that explains the surrounding code. |
| `Sources/c11App.swift:3076` | `Bundle.main.infoDictionary?["CMUXCommit"]` | Build-system Info.plist key. Renaming requires updating the build script in lockstep; do that as a paired change or leave. |
| `Sources/AppDelegate.swift:2318` | `legacyDomains = ["ai.manaflow.cmuxterm", "com.cmuxterm.app"]` | Pref-migration shim for users coming from old cmux builds. |
| `Sources/SocketControlSettings.swift:68`, `CLI/c11.swift:560` | `legacyKeychainService = "com.cmuxterm.app.socket-control"` | Keychain-migration shim for saved socket passwords. |
| `Resources/bin/cmux` | (binary wrapper) | Intentional compat alias documented in c11's CLAUDE.md. |
| `CHANGELOG.md`, `TODO.md`, `C11_TODO.md`, `PROJECTS.md`, `README.md` lineage sections | Historical references | Lineage documentation. |
| `Resources/shell-integration/cmux-{bash,zsh}-integration.{bash,zsh}` | Shell integration scripts | Paired with the `cmux` CLI alias. |

## Suggested next pass

If picking this up later, in roughly this order:

1. Decide the feedback-endpoint question (open follow-up #1) — that's the only item with user-visible behavior impact.
2. Provision the `stage11-c11` Sentry project (open follow-up #2) once the vault item name is known.
3. Mass-rename the **safe internal symbols** in one or two commits (notification names + window IDs).
4. Introduce `C11_*` env-var aliases alongside the existing `CMUX_*` names; document in CHANGELOG.
5. Push `platform/posthog.md` once you're ready (open follow-up #4).

Everything else can wait or be skipped.
