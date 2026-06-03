## Trident Critical Review — Synthesis
- **Date:** 2026-04-25
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8
- **Story:** CMUX-37
- **Sources:** critical-claude.md, critical-codex.md, critical-gemini.md

---

## Executive Summary

Two of three reviewers (Codex, Gemini) call the branch NOT production-ready. Claude calls it production-ready with a caveat. The gap between those verdicts is not aesthetic — it comes down to whether you treat unverified agent CLI flags as a blocker or a documented best-effort risk. The Codex review adds a confirmed hard bug (Codex restart command is syntactically wrong) that the other two reviewers did not catch, which independently makes the branch unshippable as-is.

The Blueprint and Snapshot core are well-constructed. The partial-failure handling in the layout executor, the layered Blueprint store discovery, and the snapshot round-trip mechanics all received positive marks from all three reviewers. The problems live at the edges: Phase 5 agent restart commands, schema documentation, CLI help text, and a handful of silent failure paths.

---

## Production Readiness Verdict

**NOT READY.** One confirmed incident-level bug (Codex restart command) must be fixed before merge. Three additional important issues should be resolved in the same pass. None of the remaining concerns are blockers on their own, but several will cause confusion or silent failures in real operator workflows.

---

## 1. Consensus Risks — Multiple Models Identified

These are the highest-priority items. All three reviewers touched the same failure mode.

1. **Unverified kimi and opencode CLI flags.** All three reviewers flagged `kimi --continue` and `opencode --continue` in `AgentRestartRegistry.swift` (lines 130-136) as unverified. The flags may not exist. If they do not, every session restore for Kimi and Opencode agents types a rejected command into a live terminal instead of resuming silently. Claude rated this UX-degradation; Gemini rated this a blocker; Codex confirmed the Codex variant is already syntactically wrong (see item 2 below), which upgrades the entire Phase 5 row from "risk" to "confirmed incident pattern."

2. **`snapshot --all` hides per-workspace write failures.** Claude and Codex both identified that `TerminalController.swift:4597` appends error entries into the same `.ok` payload, and `c11.swift:2947` never checks for `"error"` keys. A disk-full or permission failure on any individual workspace prints `OK snapshot=? path=?` to the operator. Scripts relying on this output will treat partial failures as full success.

3. **Stale `~/.c11-blueprints/` comment in `WorkspaceBlueprintFile.swift`/`WorkspaceBlueprintIndex.swift`.** Both Claude and Codex flagged the same stale comment. Real path is `~/.config/cmux/blueprints/`. Operators reading source or docs will search for the wrong directory.

---

## 2. Unique Concerns — Single-Model Findings Worth Investigating

These were raised by only one reviewer but are credible and consequential enough to require a disposition.

1. **Codex only: Codex restart command is syntactically wrong (confirmed incident-level).** `AgentRestartRegistry.swift:123` emits `codex --last\n`. The installed Codex CLI rejects `--last` at top level; the supported form is `codex resume --last`. The test at `AgentRestartRegistryTests.swift:249` locks in the wrong string, so CI passes while the behavior is broken. Every Codex surface restore types a command that fails immediately. This is a confirmed blocker.

2. **Codex only: Interactive blueprint picker never passes `cwd`, repo blueprints are invisible.** `c11.swift:2793` calls `workspace.list_blueprints` with `params: [:]`. `WorkspaceBlueprintStore.swift:122` only includes repo-local blueprints when `merged(cwd:)` receives a non-nil cwd. Result: `.cmux/blueprints/` entries are never shown to the operator in the interactive picker, despite being documented as the highest-priority source. The feature exists in the store but is unreachable from the CLI.

3. **Codex only: Schema doc tells users to write keys the decoder cannot read.** `docs/workspace-apply-plan-schema.md` describes snake_case keys (`working_directory`, `file_path`, `pane_metadata`, `custom_color`). `WorkspaceApplyPlan.swift` Codable types have no snake_case coding keys, so the actual wire format is camelCase. A user following the docs authors a plan that applies silently with those values dropped to nil. No error, no warning.

4. **Gemini only: Empty sanitized blueprint name creates a `.json` file.** `CLI/c11.swift` does not validate the result of name sanitization. A name like `"!!!!"` sanitizes to an empty string, creating a file literally named `.json` in the blueprints directory. A guard that checks `sanitizedName.isEmpty` before writing would prevent this.

5. **Claude only: `selectedIndex > 0` guard skips index-0 selectTab call.** `WorkspaceLayoutExecutor.swift:601` guards on `selectedIndex > 0`, meaning a Blueprint or snapshot with `selectedIndex: 0` never calls `selectTab`. In practice, index 0 is the construction default, so no wrong tab is displayed today. But the validator accepts `idx >= 0` as valid, the contract promises fidelity, and a future change to bonsplit's default selection would break this silently. Fix by changing to `>= 0` or adding a comment that index 0 is intentionally skipped as a construction-time invariant.

---

## 3. The Ugly Truths — Hard Messages Recurring Across Reviews

1. **Phase 5 tests confirm the implementation, not the behavior.** All three reviewers noted that the `AgentRestartRegistry` tests pass by asserting the exact strings the code emits, without verifying those strings are accepted by the actual CLIs. Codex confirmed Codex's string is wrong; Gemini called it a process failure. Writing tests that lock in incorrect output is worse than having no tests — it creates false confidence and makes the CI green while the feature is broken.

2. **"Best-effort" is not a documented contract, it's a deferred decision.** The plan divergence notes acknowledge `kimi --continue` and `opencode --continue` may not exist. Shipping a known-uncertain behavior under the label "best-effort" without a fallback path (bare `kimi` / bare `opencode`) or a runtime verification step is the wrong call. The correct response to "this flag may not exist" is to verify it or fall back, not to ship it and document the uncertainty in comments.

3. **Documentation shipped out of sync with implementation.** The schema doc (snake_case vs. camelCase), the `WorkspaceBlueprintFile.swift` comment (wrong path), and the `c11 snapshot --help` text (missing `--all`) all describe a product that is not what ships. Operators writing automation against documented interfaces will get silent failures.

---

## 4. Consolidated Blockers and Production Risk Assessment

### Blockers (must fix before merge)

1. **Codex restart command is wrong.** `codex --last` is rejected by the installed CLI; correct form is `codex resume --last`. Fix `AgentRestartRegistry.swift:123` and update the test at `AgentRestartRegistryTests.swift:249` to assert the correct string. (Codex review)

### Important (fix in same pass, strong recommendation)

2. **Unverified kimi/opencode flags need verification or safe fallback.** Either confirm `kimi --continue` and `opencode --continue` exist with the tool authors, or fall back to bare `kimi` / `opencode` (the original plan behavior for the no-id case) when a `--continue` variant is unverifiable. The current "best-effort with a comment" posture is not sufficient for code that types commands into operator terminals. (All three reviews)

3. **`snapshot --all` partial failure is invisible.** Add an `"error"` key check in the CLI loop (`c11.swift:2947`) and print a visible failure line for any workspace that returned an error entry rather than a snapshot. (Claude + Codex)

4. **Schema doc mismatches implementation.** Either add explicit snake_case `CodingKeys` to `WorkspaceApplyPlan.swift` so the documented format actually works, or update `docs/workspace-apply-plan-schema.md` to show camelCase keys. The current state means users following the docs will silently lose field values. (Codex)

5. **Interactive blueprint picker omits repo blueprints.** Pass the caller's `cwd` through `c11.swift:2793` when calling `workspace.list_blueprints` so that `.cmux/blueprints/` entries appear in the picker. (Codex)

### Potential (lower priority, address before 1.0)

6. **Empty sanitized blueprint name.** Add an empty-string guard in `c11.swift` after name sanitization to reject inputs that produce an empty filename. (Gemini)

7. **`selectedIndex > 0` guard.** Change to `>= 0` or add an inline comment documenting the construction-time invariant. The current code violates the stated validator contract without explanation. (Claude)

8. **Stale path comment.** Update `~/.c11-blueprints/` to `~/.config/cmux/blueprints/` in `WorkspaceBlueprintFile.swift` and any other occurrence. (Claude + Codex)

9. **`--all` missing from `c11 snapshot --help`.** Add the flag to the help text at `c11.swift:8453`. (Codex)

10. **`isRegularFileKey` pre-fetched but not checked in `WorkspaceBlueprintStore.swift`.** Add a `.isRegularFile` check in the extension filter. Directories with `.json`/`.md` names currently silently skip — no user-visible impact, but the pre-fetch is wasted and the logic is incomplete. (Claude)

11. **Em-dash in blueprint picker output.** `c11.swift:2812` uses an em-dash in CLI output. Per project convention (`feedback_no_em_dashes.md`), replace with a colon or dash. (Claude)
