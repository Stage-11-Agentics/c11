[Area D review] Self-review of the workflow/scripts/docs hygiene diff (PR pending):

- update-homebrew.yml: `timeout-minutes: 10` on the update-cask job. Cap with a 5-line comment explaining why (curl+sha256+heredoc+push, not a 6-hour job).
- sparkle_generate_appcast.sh:19-20: defaults flipped from manaflow-ai/cmux → Stage-11-Agentics/c11. release.yml + nightly.yml both already export the correct URLs explicitly, so production is unaffected; this only matters for a human regenerating an appcast locally. Verified `grep manaflow scripts/sparkle_generate_appcast.sh` returns nothing — the validator's strict grep passes cleanly.
- bump-version.sh: introduced `RELEASE_TAG_BUMP=1` env var. When set, the Sparkle-floor curl is hard-required; when unset (default), preserves the existing 'continue with local baseline' behavior so non-release iterative bumps still work. The check fires when the curl returns empty body OR the appcast contains no <sparkle:version> tag — both legitimate hard-fail conditions for a release-tag bump. Documented in the usage header.
- claude.yml: deleted. Never invoked; references missing CLAUDE_CODE_OAUTH_TOKEN secret; only file in the repo with floating action tags (actions/checkout@v6, anthropics/claude-code-action@v1).
- test-e2e.yml: deleted. Last 3 manual dispatches failed against the renamed cmuxUITests scheme; nothing in the repo dispatches it on automatic triggers.
- mailbox-parity.yml: updated the inline comment that referenced test-e2e.yml since the workflow no longer exists. Out-of-area but directly necessary to avoid stale doc-rot.
- CLAUDE.md 'Ghostty submodule workflow' section: manaflow → stage11 throughout, with the `git remote -v` comment clarifying that origin = upstream (manaflow-ai/ghostty), stage11 = fork (Stage-11-Agentics/ghostty). Matches the audit §4 observation of the actual remote layout.

Out-of-scope observations (not touched, captured here for follow-up):
- `scripts/run-e2e.sh:11` still hardcodes REPO=manaflow-ai/cmux and dispatches against upstream's test-e2e.yml. Dangling; unrelated to c11's deletion of its own test-e2e.yml. Worth a separate scrub.
- CLAUDE.md line 108 'submodule safety' generic check uses `origin/main` — for ghostty specifically that's manaflow-ai/ghostty's main, not the fork. Audit §4 used `stage11/main` explicitly. Could be tightened in a future docs pass; not in Area D pre-decided scope.
- No submodule edits; out of scope per delegator rules.