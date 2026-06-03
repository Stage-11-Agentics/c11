## Code Review

- **Date:** 2026-04-25T06:30:00Z
- **Model:** Claude Sonnet 4.6 (claude-sonnet-4-6)
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8
- **Linear Story:** CMUX-37

---

## Summary

This PR delivers Phases 2-5 of CMUX-37: Blueprint format + store + exporter + CLI + picker, snapshot `--all`, browser/markdown round-trip tests, and codex/opencode/kimi restart registry rows. The implementation is largely solid. `WorkspacePlanCapture` extraction is clean architecture. The threading model is correct throughout. Test coverage is meaningful and properly exercised through runtime behavior.

There are two confirmed bugs and several lower-priority findings below.

---

## General Feedback

**Architecture:** Extracting `WorkspacePlanCapture` as a shared walker between `LiveWorkspaceSnapshotSource` and `WorkspaceBlueprintExporter` is the right call. Both flows now have identical serialization fidelity by construction, not convention. The `@MainActor` boundary is clean.

**Blueprint store design:** Three-source priority with "stop on first hit" for per-repo discovery is intentional and coherent. The `directoryOverride` testing seam is well used across 9 store tests.

**Socket threading:** `v2WorkspaceListBlueprints` correctly runs its `WorkspaceBlueprintStore.merged()` call entirely off-main (the store is not `@MainActor`). `v2WorkspaceExportBlueprint` correctly gates the AppKit capture inside `v2MainSync` and writes to disk after returning. The `snapshot.create --all` path captures inside `v2MainSync`, then writes outside, consistent with the socket threading policy.

**Security:** The `AgentRestartRegistry` defense-in-depth (UUID re-validation at synthesis time even though the store already rejects non-UUIDs at write time) is well-considered. The `workspace.export_blueprint` filename sanitization correctly contains output to `~/.config/cmux/blueprints/` with no path traversal risk.

**B-IM2 focus gate:** The `selectAllowed` guard on `selectedIndex` application is correctly wired through `WalkState` and `ApplyOptions.select`.

**Localization:** All 7 required locales (en, ja, ko, ru, uk, zh-Hans, zh-Hant) are present for all 4 new Blueprint picker keys. The `String(localized:defaultValue:)` pattern is used correctly at call sites.

**Test quality:** All test classes exercise runtime behavior through actual data paths (Codable encode/decode, FS I/O with temp directories, executor materialization + capture cycle). No tests inspect source code text, method signatures, or project files.

---

## Findings

### Blockers

**1. ✅ Confirmed — `workspace new` picker silently omits all per-repo blueprints**

`workspaceBlueprintPicker` calls `workspace.list_blueprints` with `params: [:]` (no `cwd` key). The socket handler's `v2WorkspaceListBlueprints` only activates per-repo discovery when `params["cwd"]` is present. Since the CLI never sends a `cwd`, `.cmux/blueprints/` directories are never discovered during `workspace new` picker flow.

File: `CLI/c11.swift` line 2793
```swift
let payload = try client.sendV2(method: "workspace.list_blueprints", params: [:])
```

Fix: pass the caller's working directory:
```swift
let params: [String: Any] = ["cwd": FileManager.default.currentDirectoryPath]
let payload = try client.sendV2(method: "workspace.list_blueprints", params: params)
```

This renders the entire per-repo blueprint source class non-functional from the primary user-facing command.

**2. ✅ Confirmed — `snapshot --all` CLI prints "OK" for failed workspace writes**

When `snapshot.create --all` is called, the socket handler returns partial results: successful captures include `{snapshot_id, path, surface_count, workspace_ref}` while failed writes include `{snapshot_id, error, workspace_ref}` (no `path`, no `surface_count`).

The CLI at line 2947-2952 reads all entries through `?? "?"` fallbacks and unconditionally prints `"OK snapshot=... surfaces=0 workspace=... path=?"` for the failed entries. An operator running `--all` across 8 workspaces where 1 write fails will see `OK path=?` with no indication anything went wrong.

File: `CLI/c11.swift` lines 2947-2952

Fix: check for `snap["error"]` and print an `ERROR:` prefixed line instead of `OK` when it is present.

### Important

**3. ✅ Confirmed — `selectedIndex > 0` silently skips re-selecting tab 0**

`WorkspaceLayoutExecutor.swift` line 601 uses `selectedIndex > 0` as a guard. This means when a plan captures a pane with `selectedIndex: 0` (first tab selected), the executor skips the `selectTab` call entirely.

In the normal round-trip this is harmless: when the executor materializes a pane, tab 0 is the default selection, so not calling `selectTab` leaves the correct tab active. However it is a semantic gap: the condition should be `selectedIndex >= 0` (or simply remove the lower-bound check and rely on the `< paneSpec.surfaceIds.count` upper-bound that already exists) to be self-documenting and handle future edge cases where bonsplit could end up with a different initial selection.

The existing `validate()` path already rejects negative `selectedIndex` values (line 401), so `selectedIndex >= 0` is guaranteed by the time the executor reaches this code. The correct guard is:
```swift
if selectAllowed,
   let selectedIndex = paneSpec.selectedIndex,
   selectedIndex < paneSpec.surfaceIds.count {
```

File: `Sources/WorkspaceLayoutExecutor.swift` line 601

**4. ✅ Confirmed — Stale path comment in `WorkspaceBlueprintFile.swift`**

The `Source.user` enum case comment at line 33 says `// ~/.c11-blueprints/` but the actual path used throughout is `~/.config/cmux/blueprints/` (confirmed in `WorkspaceBlueprintStore.swift` line 93, `TerminalController.swift` line 4525). This is wrong and will mislead operators and agents reading the type documentation.

File: `Sources/WorkspaceBlueprintFile.swift` line 33:
```swift
case user = "user"          // ~/.c11-blueprints/
```
Should be:
```swift
case user = "user"          // ~/.config/cmux/blueprints/
```

**5. ✅ Confirmed — `snapshot --all` text output field ordering differs from single-snapshot output**

The `--all` output (line 2952) prints: `OK snapshot=ID surfaces=N workspace=WSREF path=PATH`
The single-workspace output (line 2993) prints: `OK snapshot=ID surfaces=N path=PATH`

The single-workspace output omits `workspace=`. The socket response for the single case does include `workspace_ref` (line 4632), but the CLI does not extract or print it. For scripted consumers parsing both output modes, this creates an inconsistency. Either include `workspace=` in the single output or exclude it from `--all` (including is preferable).

Files: `CLI/c11.swift` lines 2952, 2993

### Potential

**6. ❓ Uncertain — `kimi --continue` and `opencode --continue` flags may not exist**

The PR context explicitly flags this. The registry comments say "Best-effort: same caveat as codex --last." The `codex --last` flag is documented Codex behavior; `opencode --continue` and `kimi --continue` appear to be inferred by analogy.

If these flags do not exist in the actual CLIs, the injected command will fail with a "Unknown flag" error in the terminal on restore -- visible to the operator, not silent. This is degraded but not catastrophic behavior, consistent with the "best-effort" framing. However, if either flag is wrong, the correct fallback (launch fresh session) is not attempted.

Recommendation: verify against current `opencode --help` and `kimi --help` before shipping, and add a comment citing the verified flag if confirmed. If unverifiable, consider falling back to bare `opencode\n` / `kimi\n` per the original plan spec.

**7. ❓ Uncertain — `.md` blueprint files produce misleading errors when hand-authored as real Markdown**

`WorkspaceBlueprintStore` accepts `.md` extension files in all discovery paths and surfaces them in the picker. When a user picks one, the CLI reads it and attempts `JSONSerialization.jsonObject(with: data)`. If the file is genuine Markdown (not JSON with a `.md` extension), this fails with `"not a valid blueprint file (missing 'plan' key)"` -- which is confusing since the user explicitly named the file `.md` expecting Markdown support.

The design intent (write via `WorkspaceBlueprintStore.write()` which always writes JSON) means `.md` files are JSON-in-disguise for "hand-authored, version-agnostic" presentation. This is documented internally but not surfaced to users. The error message could be improved to indicate the file must contain JSON.

File: `CLI/c11.swift` line 2845

**8. ⬇️ Lower priority — `WorkspacePlanCapture` silently drops tabs when panel lookup fails**

Lines 68-69 of `WorkspacePlanCapture.swift`:
```swift
guard let panelId = panelID(forTabIDString: tab.id),
      let panel = workspace.panels[panelId] else { continue }
```
When a bonsplit tab exists but its panel cannot be resolved, it is silently skipped with no warning added to the capture output. In practice this should not occur (the tree snapshot should only include live surfaces), but it means a partial capture produces no diagnostic. A `warnings` array in `WorkspaceApplyPlan` could surface this, but that is a larger schema change. Low priority for now; worth noting for future debuggability.

**9. ⬇️ Lower priority — Picker error messages are not localized**

The `workspaceBlueprintPicker` localizes only two strings: `picker.noBlueprints` and `picker.prompt`. The error messages thrown on cancel, invalid selection, missing URL, and file read failure are bare English `CLIError` strings. Given 7-locale coverage for the display strings, these gaps are inconsistent. Low priority since they are edge-case error paths, not normal UI.

File: `CLI/c11.swift` lines 2823-2845

**10. ⬇️ Lower priority — Missing test for snapshot `--all` error-entry handling**

There is no test covering the case where `writeToDefaultDirectory` fails for one workspace in a multi-workspace `--all` capture. The partial-failure shape (`{snapshot_id, error, workspace_ref}`) is only exercised by manual inspection. This gap would have caught finding #2. Consider a unit test with a mock store that fails on a specific workspace.

---

## CLAUDE.md Constraint Audit

| Constraint | Status |
|------------|--------|
| Localization: `String(localized:defaultValue:)` + xcstrings | Pass — 4 new keys, all 7 locales present |
| Socket threading: parse/validate off-main, AppKit in `v2MainSync` | Pass — `list_blueprints` off-main (store not MainActor), `export_blueprint` uses `v2MainSync` for capture |
| Typing-latency paths untouched | Pass — `GhosttyTerminalView.swift`, `ContentView.swift` not modified |
| Test quality: no AST/source-text assertions | Pass — all tests exercise runtime behavior |
| Test policy: CI only, no local runs | Pass — all test files have the required CI-only comment |
