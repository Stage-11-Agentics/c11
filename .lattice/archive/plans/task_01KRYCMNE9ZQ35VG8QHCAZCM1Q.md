# C11-102: Workflow hygiene: timeout, sparkle defaults, bump-version, claude.yml/test-e2e.yml decisions, docs

Workflow / scripts / docs housekeeping surfaced by the audit. Parent: C11-98. Independent of the other three children.

**Workflow tightening**
1. `.github/workflows/update-homebrew.yml` — add `timeout-minutes: 10` (currently inherits GitHub's 6h default).
2. `scripts/sparkle_generate_appcast.sh:19-20` — flip default `DOWNLOAD_URL_PREFIX` and `RELEASE_NOTES_URL` from `manaflow-ai/cmux` to `Stage-11-Agentics/c11`, OR require explicit envs (no default). Today `release.yml` exports the correct values so production is fine; the risk is a human regenerating an appcast locally and silently pointing at the wrong fork.
3. `scripts/bump-version.sh:28` — when invoked for a release tag, hard-fail when the Sparkle-floor curl returns 0 bytes (instead of silently falling back to `LATEST_RELEASE_BUILD=""`). The whole point of PR #153 was to prevent shipping a build number lower than the published floor.

**Decisions** (write outcome as a comment on this ticket before implementing)
4. `.github/workflows/claude.yml` — pin floating action tags (`actions/checkout@v6`, `anthropics/claude-code-action@v1`) to SHAs and add the missing `CLAUDE_CODE_OAUTH_TOKEN` secret, OR delete the workflow. It has never been invoked.
5. `.github/workflows/test-e2e.yml:212` — rename the hardcoded `cmuxUITests` scheme reference to the current scheme + fix the launch path, OR delete the workflow. Last 3 dispatches failed.

**Docs**
6. `code/c11/CLAUDE.md` "Ghostty submodule workflow" section — update "push to `manaflow`" → "push to `stage11`" (the actual remote name in the checkout; CLAUDE.md doc-drift).

**Acceptance**
- Three workflow tightening changes shipped (1, 2, 3)
- Decisions 4 + 5 written on this ticket and acted on either way (no half-deleted, half-kept state)
- CLAUDE.md ghostty section reflects the real remote layout

**Not in scope** — adding explicit `ARCHS="arm64 x86_64"` to `release.yml`. Audit confirmed the shipped DMG is already universal via pbxproj defaults; the addition is belt-and-braces, not a fix, and falls outside this hygiene pass.
