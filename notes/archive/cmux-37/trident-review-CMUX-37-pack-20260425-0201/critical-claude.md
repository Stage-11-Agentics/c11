## Critical Code Review
- **Date:** 2026-04-25T02:00:00Z
- **Model:** Claude Sonnet 4.6 (claude-sonnet-4-6)
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8
- **Linear Story:** CMUX-37
- **Review Type:** Critical/Adversarial

---

## The Ugly Truth

This is a well-structured PR with clear phase separation and honest self-documentation of its plan divergences. The socket threading model is respected, the security surface for command injection on the `claude-code` row is properly defended in depth, and the refactor of `WorkspacePlanCapture` into a shared helper is the right call. Blueprint store tests exercise real FS I/O and cover the layered discovery semantics adequately.

That said, there are three issues worth flagging, one of which is a behavioral bug that will silently produce the wrong result for real users (selectedIndex=0 in the executor). There are also consistency gaps and unverified assumptions around Phase 5's CLI flags. The overall code quality is high but not incident-free out of the box.

---

## What Will Break

### 1. Tab-group selectedIndex=0 is silently ignored — users always see the wrong tab selected after a restore or blueprint apply

`WorkspaceLayoutExecutor.swift` line 601:

```swift
if selectAllowed,
   let selectedIndex = paneSpec.selectedIndex,
   selectedIndex > 0,
   selectedIndex < paneSpec.surfaceIds.count {
```

The guard `selectedIndex > 0` means that when the plan says index 0 is the selected tab, `selectTab` is never called. The comment above this block says "Apply selectedIndex" with no mention of an optimization or intentional skip at 0.

If a snapshot or Blueprint is captured when pane tab 0 is selected, `WorkspacePlanCapture.walkPane` records `selectedIndex = 0`. On restore, this 0 is passed to the executor, which skips the `selectTab` call. Index 0 is the default selection after surface creation, so in practice this is a silent no-op — the correct tab happens to already be selected. BUT: if bonsplit ever changes the default selection on panel creation (or if surfaces are added in a different order during complex splits), this assumption breaks silently without any warning in `ApplyResult`.

The validator on line 401 correctly accepts `idx >= 0`, so index 0 is a valid and documented plan value. The executor should honor it.

The intent may have been "skip `selectTab` because 0 is already selected by construction." If so, that logic is fragile and undocumented. Either:
- Change the guard to `selectedIndex >= 0` and accept the redundant no-op call, OR
- Add an explicit comment explaining the invariant ("index 0 is always selected at creation, so calling selectTab here is redundant")

As shipped, this is a subtle bug for any operator who snapshots a workspace with a non-first tab selected and then restores it: the captured selectedIndex will match what was captured, but the restore logic only acts on it if index > 0. This is probably harmless in practice since index 0 IS the default, but it will absolutely bite someone who serializes selectedIndex=0 expecting fidelity.

**Verdict: Confirmed real issue, lower severity than initially described — silent no-op rather than wrong selection in almost all cases, but still a correctness violation.** ⬇️ Real but lower priority than initially thought.

### 2. kimi and opencode CLI flags (`--continue`) are unverified and may not exist

`AgentRestartRegistry.swift` lines 130-136:

```swift
"opencode --continue\n"
...
"kimi --continue\n"
```

The code comments say "Best-effort: same caveat as codex --last." The context document explicitly flags: "The `kimi --continue` and `opencode --continue` flags may not actually exist."

When these commands are sent to a terminal on restore, one of three things happens:
1. The CLI accepts `--continue` and resumes correctly. 
2. The CLI doesn't recognize `--continue` and prints a usage error — the operator sees a confusing error in a terminal that was supposed to resume a session.
3. The CLI interprets `--continue` as something else entirely (e.g., kimi's `--continue` could mean something different than "resume last session").

Codex's `--last` is the only one that appeared in the original plan spec (though the plan spec for codex also said: with id → `codex --last`, without id → `codex`). The other two are invented guesses.

This is documented as "best-effort" in comments and the plan divergence notes, which earns partial credit. But "best-effort" shouldn't mean "we invented a flag and shipped it." The safety net here is that the worst outcome is a benign error message in the terminal, not data loss or security issue. Still: shipping unverified CLI flags with no fallback path (the old plan: no id → bare `kimi`) is worse than doing nothing and documenting why.

✅ Confirmed — the unverified flags will either work correctly, silently no-op, or display a usage error. The actual risk is UX degradation, not an incident.

### 3. `blueprintURLs(in:)` requests `isRegularFileKey` but never reads it — subdirectories with .json/.md names are included in the index

`WorkspaceBlueprintStore.swift` lines 189-200:

```swift
entries = try fileManager.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
)
...
return entries.filter {
    let ext = $0.pathExtension.lowercased()
    return ext == "json" || ext == "md"
}
```

`isRegularFileKey` is pre-fetched but never checked. A directory named `agent-room.json/` (possible if someone accidentally creates a directory with that name, or a package manager does something weird) passes the extension filter. `indexEntries` then calls `fileManager.attributesOfItem`, reads modifiedAt, and attempts to read the "file" as `Data(contentsOf: url)`. Reading a directory as Data on macOS returns `nil` data or throws. The `guard let file = try? read(url: url) else { continue }` on line 220 silently skips it.

Net result: silent skip, not a crash. But the pre-fetched key is wasted. This is a nit more than a bug.

✅ Confirmed — directories with .json/.md names silently skip. No user-visible impact.

---

## What's Missing

### Test coverage gaps

1. **No test for selectedIndex restoration.** The round-trip tests in `WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift` verify surface kinds but do not create a multi-tab pane and verify that `selectedIndex` round-trips (captured correctly, applied correctly). This is exactly the path with the `> 0` guard issue.

2. **No test for `workspace.export_blueprint` socket handler overwrite semantics.** If `~/.config/cmux/blueprints/my-bp.json` already exists and the operator exports again with the same name, `write(_ file:, to: url:)` uses `.atomic` which will silently overwrite. There's no test or error message confirming this is intentional. It is probably correct behavior, but it's undocumented and untested.

3. **No test for `c11 workspace new --blueprint` with a file that has a `plan` key but invalid plan JSON.** The CLI does `JSONSerialization.jsonObject(with: data) as? [String: Any]` and extracts `file["plan"]`, but it passes this raw `Any` directly to `workspace.apply` without re-validating. The server will validate it, but the client error message will be a generic socket error rather than a clear "plan validation failed" message. Not a blocker but missing coverage.

4. **No test for the `isRegularFile` filter bug** — no test creates a `.json` subdirectory and verifies it's excluded. The existing tests only cover real files.

5. **No test for `--all` when one workspace fails to write** — the partial failure path in `v2SnapshotCreate` appends an error entry but the CLI's `--all` handler on line 2947-2954 only reads `snapshot_id`, `path`, `surface_count`, and `workspace_ref`. If `path` is missing (error case), the CLI prints `path=?` without indicating that this workspace failed. A failing workspace should print a visible error line, not a silently degraded OK line.

### Error handling gaps

1. **`v2WorkspaceExportBlueprint` name sanitization produces silent collision on identical sanitized names.** If two different names sanitize to the same filename (e.g., `"my@bp"` and `"my#bp"` both become `"mybp.json"`), the second export silently overwrites the first. No warning is returned to the caller. This is deterministic behavior that could surprise operators.

2. **`workspaceBlueprintPicker` in `c11.swift` line 2838** — after the user selects a blueprint by number, the CLI re-reads the file from the path in the index. If the file was deleted between the listing and the selection (race), the error message is "could not read blueprint at '...'", which is fine. But if the file now contains invalid JSON, the error is the same generic "not a valid blueprint file." Consider distinguishing these cases.

---

## The Nits

1. **`WorkspaceBlueprintFile.Source` enum comment says `~/.c11-blueprints/`** (`WorkspaceBlueprintFile.swift` line 33) but the actual path is `~/.config/cmux/blueprints/`. The code is correct; the comment is stale. Someone will search for `~/.c11-blueprints/` and not find it.

2. **`v2WorkspaceListBlueprints` runs entirely off-main** including FS I/O — correct per socket threading policy. But `v2WorkspaceExportBlueprint` runs FS I/O (the `store.write` call on line 4530) after returning from `v2MainSync`. This is also correct since `WorkspaceBlueprintStore` is not `@MainActor`. Both paths are fine; just noting the asymmetry is intentional.

3. **`selectedIndex > 0` has no comment explaining the optimization.** If the author intended "index 0 is already selected by construction so we skip the call," that should be documented inline so the next reader doesn't file a bug about it.

4. **`parseFlag` helper is defined late in the file** (line 9606) but used early (line 2929). Swift has no problem with this but it's inconsistent with where `parseOption` lives. Minor style nit.

5. **`agent-room.json` Blueprint** has a browser surface (`s3`) with no URL. On apply, the browser panel will open to whatever the browser default is (blank, or the configured homepage). This is probably intentional as a "bring your own URL" slot, but a comment in the file would make the intent clear to users inspecting the blueprint.

6. **`workspaceBlueprintPicker` prints a dash `—` in the blueprint list line** (line 2812: `print("  \(label)  \(num)  \(name) — \(d)")`). This is an em-dash in the source. Per the project memory (`feedback_no_em_dashes.md`), em-dashes should be avoided. This is in CLI output, not code comments, but worth noting.

---

## Numbered List

### Blockers

None.

### Important

**1.** `WorkspaceLayoutExecutor.swift:601` — `selectedIndex > 0` skips `selectedIndex == 0`. When a Blueprint or snapshot has `selectedIndex: 0` in a pane spec, the selectTab call is skipped. In practice, index 0 is the construction-time default so no wrong tab is shown — but the spec contract promises fidelity and the validation layer accepts 0 as valid. Fix by changing to `selectedIndex >= 0` or adding an explicit comment that index 0 is intentionally skipped as a construction-time invariant. ⬇️

**2.** `AgentRestartRegistry.swift:130-136` — `kimi --continue` and `opencode --continue` are unverified flags shipped as production behavior. If either flag is rejected by the CLI, operators will see an error in a terminal that was supposed to resume silently. Lower-risk than the plan divergence description suggests (it's a UX problem, not data loss), but worth documenting clearly in the registry row comments or adding a fallback to bare `kimi`/`opencode` if `--continue` fails. ✅ Confirmed

### Potential

**3.** `WorkspaceBlueprintStore.swift:191` — `isRegularFileKey` fetched but never checked. Subdirectories with `.json`/`.md` names pass the filter and are silently skipped during decode. Fix: add `.isRegularFileKey` filtering in the extension filter lambda. ✅ Confirmed

**4.** Missing test for `selectedIndex` round-trip in multi-tab pane. The snapshot/blueprint round-trip tests only cover surface kinds, not tab selection state. A test with a multi-tab pane and non-zero selectedIndex would catch the `> 0` guard if it were changed.

**5.** `WorkspaceBlueprintFile.swift:33` — comment says `~/.c11-blueprints/` but real path is `~/.config/cmux/blueprints/`. Stale comment will confuse anyone trying to locate blueprints manually.

**6.** `v2SnapshotCreate` `--all` error path: CLI on line 2949 prints `OK snapshot=... path=?` for a workspace that failed to write. Should print a visible failure line for failed workspaces so operators can distinguish partial success from full success.

**7.** `v2WorkspaceExportBlueprint` silent overwrite when two names sanitize to the same filename. Should warn in the return payload or require an explicit `--overwrite` flag.

---

## Closing

This code is production-ready with one caveat: the `kimi --continue` and `opencode --continue` flags need verification before these rows silently send wrong commands to operator terminals on session restore. Everything else is either a genuine nit (stale comment, redundant pre-fetch) or a very low probability edge case.

The `selectedIndex > 0` guard is the most interesting correctness issue. It's not an incident-causing bug today because index 0 is the construction default, but it violates the stated contract and will confuse future developers. Fix it or document it.

Would I mass-deploy this to 100k users? Yes — with the understanding that `kimi --continue` and `opencode --continue` need to be verified flags before calling Phase 5 "done." The Blueprint machinery, snapshot `--all`, and the pre-flight executor fixes are all solid.
