# C11-203 build plan

Branch: `fix/C11-203-launch-agents-rework` (single branch, single PR).
Read the ticket first: `lattice show C11-203`. It carries the verified model/flag data.

## Decomposition

Three workstreams in two waves, split on file ownership so parallel work cannot collide.

| WS | Ticket parts | Owns these files | Wave |
|---|---|---|---|
| **WS-1 Launch path & popover** | A, B, G | `Workspace.swift`, `AgentPickerView.swift`, `AgentPickerModel.swift`, `AgentConfigLibraryStore.swift`, `AgentConfigEditorSheet.swift` (deletions only), `AppDelegate.swift` | 1 |
| **WS-2 Model catalog** | D | new `ModelCatalog*.swift` + tests + `scripts/`, `project.pbxproj` | 1 |
| **WS-3 Editor re-shape** | C, E, F | `AgentConfigEditorModel.swift`, `AgentConfigEditorSheet.swift` | 2 |

Wave 2 starts after wave 1 lands: WS-3 rewrites `AgentConfigEditorSheet.swift`, which WS-1
also edits, and it consumes the API WS-2 builds.

## The seam between WS-2 and WS-3

WS-2 builds this and WS-3 consumes it. Fixed contract so the waves can be written against
each other without negotiation.

```swift
/// One launchable model, as enumerated from a harness CLI.
struct CatalogModel: Equatable, Codable {
    let id: String                  // the value passed to the harness's model flag
    let displayName: String
    let provider: String            // canonical key: openai, anthropic, moonshot, xai, google, …
    let harness: String             // the harness that enumerated it
    let contextWindow: Int?
    let supportedEfforts: [String]  // empty = fall back to the harness's own effort values
    let isComingSoon: Bool          // dimmed, non-selectable (Astra)
}

protocol ModelCatalogProviding {
    /// Canonical provider keys, in display order.
    func providers() -> [String]
    /// Every model for a provider, across all harnesses, deduped by id.
    func models(forProvider provider: String) -> [CatalogModel]
    /// Harnesses that can launch this model, default (top-line) harness first.
    func harnesses(forModel model: CatalogModel) -> [String]
    /// Re-enumerate from the CLIs off-main; calls back on main when the cache changes.
    func refresh(completion: @escaping () -> Void)
}
```

`ModelCatalogStore.shared` is the concrete singleton. WS-3 codes against the protocol so its
tests inject a stub.

## Hard constraints for every workstream

1. **Do not run `xcodebuild`.** Not `build`, not `test`, not `build-for-testing`, not the
   "safe" `c11-logic` scheme. Standing operator instruction for this repo. CI's `build` job
   is the compile + logic-test gate; the orchestrator pushes and reads CI.
2. **Do not run the app**, do not `open` a DEV.app, do not touch the operator's running c11.
3. Every user-facing string goes through `String(localized:key, defaultValue:)`. English
   only; the translation pass is separate. Validate `Resources/Localizable.xcstrings` with
   `jq . <file> > /dev/null`, never `plutil`.
4. Tests verify **runtime behavior through executable seams**, never source text, signatures,
   or the presence of a key in a plist/pbxproj. If a behavior has no seam, add one or say so.
   New logic tests go in `c11Tests/` files that belong to the **`c11LogicTests`** target.
5. `dlog` calls must be `#if DEBUG`-gated or Release fails to compile.
6. Stay inside your owned files. If you need a change in someone else's file, write it in
   your report instead of making it.
7. Match the surrounding code: comment density, naming, the existing doc-comment style that
   cites design sections and ticket IDs.
8. Commit your own work on the branch with a clear message. Do not push, do not open a PR,
   do not merge.

## Orchestrator-owned

- All `git push`, PR creation, CI reading, merge.
- Repairing the operator's live `agent-configs.json` (a corrupt specimen is preserved at
  `scratchpad/agent-configs-corrupt-specimen.json` for use as a test fixture).
- Adjudicating cross-workstream requests.

## Acceptance

The ticket's ten acceptance criteria are the contract. Criterion 10 (real-artifact smoke on a
tagged build) is an operator-assisted step after CI is green, not a workstream deliverable.
