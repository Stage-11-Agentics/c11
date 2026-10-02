# Review: C11-271 lifecycle fixture corpus (PR #495)

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket: **C11-271**. PR: https://github.com/Stage-11-Agentics/c11/pull/495 (draft). Branch `c11-1.0/C11-271-lifecycle-fixtures`. Head `ad7d761e328381972a4319eed80c6dbb96786e42`. Base origin/main `0ff8887e5e`.
- Title: `C11-271 Fixture Review`. Actor `agent:codex-review-271`.
- Owner: Grok. The run brief notes Grok work needs careful verification: check claims against the captures themselves, not the owner's summary.

## Focus
1. **Disclosure first** (public repo): every capture and normalized file must be synthetic or sanitized: no prompt/tool bodies, real session/conversation/thread IDs, account names, emails, home paths, hostnames, secrets. Check the sanitizer in `LifecycleFixtureCatalog.swift` and scan every fixture file.
2. **Acceptance:** all five providers/modes (Claude normal, Claude bypass, Codex, Grok, OpenCode); the incidents (bypass AskUserQuestion and ExitPlanMode, late async PreToolUse after Stop, Esc interrupt, restart while waiting, sibling tool start while another tab waits, the C11-189 child-completion case); each with source/arrival ordering, a visible-state oracle, missing native signals listed explicitly; manifest links normalized records to captures and separates current behavior from intended projection; derived variants (e.g. late PreToolUse) are labeled derived, not passed off as real.
3. **Amendment:** captures came from production c11, not a tagged build (run-brief amendment, commented on the ticket). Each capture records provenance (c11 version/build) and marks any case needing tagged recapture.
4. **Reader contract:** `LifecycleFixtureCatalog.swift` and its target membership in `project.pbxproj`: is it compiled into the right test target (not the app), does it load fixtures without network, is the replay contract usable by C11-273's fold tests? Tests must exercise runtime behavior, not grep source.
5. Truthfulness: anything presented as observed must be observed. Fabricated sequences are blocking.
