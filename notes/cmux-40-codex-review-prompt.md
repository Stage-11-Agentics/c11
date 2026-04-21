# Code review — CMUX-40 skill installer

Review the staged commit on branch `cmux-40-skill-installer` in the
c11mux (Stage 11 fork of cmux) repository at
`/Users/atin/Projects/Stage11/code/cmux`.

## Context

This ticket adds first-run and Settings UX for installing the bundled
c11mux skill files into agent skill directories (Claude Code, Codex,
Kimi, OpenCode). c11mux's project CLAUDE.md has a hard **"unopinionated
about the terminal"** principle:

- c11mux does NOT write hooks, shell rc files, or tool settings.json.
- The skill file is the one endorsed outgoing touch.
- Claude Code gets the grandfathered active-install treatment (same as
  `Resources/bin/claude`); every other TUI requires explicit operator
  intent (`--tool codex` / `--tool kimi` / `--tool opencode`) because
  "how the skill reaches each TUI is the operator's problem".

## Commit under review

- Branch: `cmux-40-skill-installer`
- HEAD: `69051783 Skill installer: Settings pane, CLI, manifest, first-launch wizard`
- Files: `Sources/SkillInstaller.swift` (core logic),
  `Sources/AgentSkillsView.swift` (SwiftUI), `CLI/cmux.swift` (new
  `cmux skill` subcommand), `Sources/AppDelegate.swift` (first-launch
  sheet presentation), `Sources/cmuxApp.swift` (Settings wiring),
  `GhosttyTabs.xcodeproj/project.pbxproj` (bundling), README.md,
  `skills/MANIFEST.json`, `Resources/Localizable.xcstrings`.

The full diff (code only, `.lattice/` and `vendor/bonsplit/` excluded)
is at `/Users/atin/Projects/Stage11/code/cmux/notes/cmux-40-code-diff.patch`.

## What I want reviewed

Please give me an honest, principled review focused on:

1. **Principle compliance.** Does this PR honor "c11mux does not reach
   into a tool's persistent config beyond skill dirs"? Any hidden
   writes, unexpected fs side effects, or places where the code would
   happily drop files somewhere it shouldn't? Check `SkillInstaller`
   install/remove paths in particular.

2. **Safety.** The remove path guards against nuking user-owned
   directories by refusing to remove a skill dir that lacks our
   `.c11mux-skill.json` manifest. Is that guard complete? Are there
   symlink / race / path-traversal issues with `copyItem` into the
   user's home? Any way `--home` (the test-override flag) could be
   coerced into writing outside the intended tree?

3. **Idempotency.** Install is supposed to be a content-hash no-op when
   the installed copy matches source. Trace the logic:
   `SkillInstaller.contentHash` → `status` → `install`. Any edge cases
   (empty dirs, large binary files, permission errors) that would break
   the "run install as often as you like" contract?

4. **Hash-canonicalization correctness.** `SkillInstaller.contentHash`
   filters dotfiles so the manifest doesn't perturb the hash. Is there
   any way the same directory can produce different hashes across runs
   (non-deterministic enumeration, locale-dependent sort, line-ending
   issues in file content)?

5. **CLI surface.** The `cmux skill` subcommand routing at
   `CLI/cmux.swift` — is the flag parsing robust? Is `--home` really
   honored everywhere? Does `--json` produce stable JSON? What happens
   when the user runs `cmux skill install --tool codex` and `~/.codex/`
   doesn't exist — does it fail cleanly?

6. **SwiftUI / AppKit integration.** In `AppDelegate.swift`,
   `presentAgentSkillsOnboarding()` creates a dedicated NSWindow hosting
   the sheet. Window is retained weakly; `isReleasedWhenClosed = false`
   is set. Is this leak-free? Is the window correctly torn down when
   closed? Any main-actor isolation violations from the 1.2s async
   dispatch that calls `presentAgentSkillsOnboardingIfNeeded()` inside
   `sendWelcomeCommandWhenReady`?

7. **Localization coverage.** Every user-facing string must go through
   `String(localized: "key", defaultValue: "English")` with entries in
   `Resources/Localizable.xcstrings`. Are any hardcoded UI strings
   missing from the xcstrings file?

8. **Anything else you think I got wrong.** I'm particularly interested
   in ergonomics concerns, error-message clarity, and anywhere the code
   quietly swallows errors when it should surface them.

## Output format

Write your findings to `/Users/atin/Projects/Stage11/code/cmux/notes/cmux-40-codex-review.md`.

Structure: one short intro, then a section per numbered concern above,
calling out specific file:line references and proposed fixes. If
something is fine, say "OK — nothing to flag" and move on. Prioritize
findings by severity (critical / major / minor / nit). End with a one-
paragraph overall verdict.

If you spot a bug you can fix in under ~20 lines, feel free to include
a patch snippet — but do not apply any changes yourself; I'll do the
edits after reading.

Be direct and specific. No pleasantries.
