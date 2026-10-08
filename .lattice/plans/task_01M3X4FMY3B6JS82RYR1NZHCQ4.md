# C11-279: Reject misspelled routing keys

## Incident
A top-level socket param whose spelling is a routing id, but not an exact legal spelling, is ignored. `v2ResolveWorkspace` (`Sources/TerminalController.swift:3044-3052`) then falls back to `selectedWorkspaceId`, so `tab.send_text` with `surfaceId` hits the focused tab. Observed on origin/main `0ff8887e5e`. `v2String` (`:2654-2658`) returns nil for an absent key. `v2RejectUnresolvedTargetRefs` (`:2717-2748`) rejects only empty or dead refs on destructive verbs.

## What is already true (citations corrected)
`LegacyWireAliases` is on origin/main. C11-248 is still `in_progress`, but this table is the one to build against. Do not edit the tables.

- `canonicalParams` (`LegacyWireAliases.swift:175-185`) copies a listed source onto the handler key only when that key is absent. It does not remove unknown keys and does not reject typos.
- Handler keys are still the old names. `paramSources` (`:148-159`) targets `surface_id`, `pane_id`, `target_pane_id`, and the other `*_surface_id` / `*_pane_id` keys. Public canonical names are the `new` side of `legacyKeyPairs` (`:94-143`): `tab_id`, `area_id`, `tab_ref`, and the prefixed forms.
- `window_id` and `workspace_id` are not in either table. They are still selectors: `v2RejectUnresolvedTargetRefs` reads them, and a `workspaceId` typo takes the same focused-workspace fallback.
- `parseV2SocketRequest` (`SocketDispatch.swift:25-42`) and `processV2Command` (`:948-950`) both call `canonicalParams`. `tab.send_text` is socket-worker (`:64-65`) and never reaches `processV2Command` (`invalid_dispatch` at `:957-969`). A check only in `processV2Command` misses the send incident.
- `v2Error` is `nonisolated` (`TerminalController.swift:2464`).

## Change
Add `LegacyWireAliases.unsupportedRoutingKey(_ params:) -> RoutingKeyRejection?`.

`RoutingKeyRejection` holds `key` (the caller's exact spelling) and `canonical`. `code` is `invalid_params`. `message` is `String(localized: "socket.error.unsupported_routing_key", defaultValue: "Unsupported parameter '%1$@'; use '%2$@'.")` formatted with the two strings. Both seams use this value. No second message string.

Allow-set (exact, case-sensitive):

- Every `new`, `old`, and `extraOld` in `legacyKeyPairs` whose name is an id or ref (`*_id`, `*_ids`, `*_ref`, `*_refs`, plus the camelCase result keys `tabRefs`, `surfaceRefs`, `areaRefs`, `paneRefs`).
- Every `target` and `source` in `paramSources`, including bare `pane` and `area`.
- `window_id` and `workspace_id`.

Not selectors, so a typo is left alone: `tab_title`, `tab_type`, `tab_index`, `tab_pinned`, `terminal_tabs`, and the other non-id pairs. `title`, `text`, and anything inside `opaqueKeys` are not inspected. The function walks top-level keys only.

Normalize by deleting `_` and lowercasing, same as cmux #13214. If the normalized form equals a selector's normalized form and the exact key is not in the allow-set, reject. Canonical name is the `new` spelling of the matched `KeyPair` when the match is in that pair (`surfaceId` → `surface_id` pair → `tab_id`; `tabRef` → `tab_ref`; `panelId` → `tab_id`; `paneId` → `area_id`). For `window_id` / `workspace_id`, the canonical name is that key. For bare `pane` / `area`, the canonical name is `area`. First offending key in iteration order wins. `surfce_id` normalizes to `surfceid`, matches nothing, returns nil.

Call the function on the params `canonicalParams` just returned:

- `socketWorkerV2ResponseIfNeeded` (`SocketDispatch.swift:45-53`): if non-nil, return `v2Error` and do not call `socketWorkerV2Response`.
- `processV2Command` (`:950`): if non-nil, return `v2Error` before the execution-policy guard.

Do not change `canonicalParams` copy behavior. Listed aliases keep working, including when the canonical key is also present.

## Files
- `Sources/SocketHandlers/LegacyWireAliases.swift` — pure function and rejection type. Do not edit `legacyKeyPairs` or `paramSources`.
- `Sources/SocketHandlers/SocketDispatch.swift` — two call sites above.
- `c11Tests/LegacyWireRoutingKeyTests.swift` — new, member of the `c11LogicTests` target only (same four pbxproj entries as `SocketTabRefValidatorTests.swift`, sources phase `37DDE3B0A6A70E75A7B2BEDF`). Hand-edit those entries. Do not run the xcodeproj gem.
- `skills/c11/references/api.md` — one sentence next to tab targeting: a key that does not normalize to a routing selector (`surfce_id`) is still ignored; this is not a general unknown-key filter. Listed aliases (`surface_id`, `pane_id`, `panel_id`, `*_ref`) still work.
- `tests_v2/test_routing_key_typo.py` — live socket case, modeled on `tests_v2/test_send_submits_to_background_workspace.py`.

No `CLI/c11.swift` edit. The CLI already sends snake_case keys.

## Acceptance → incident → test → proof
1. Pure function. Incident: `surfaceId` and `tabRef` are ignored today. `c11LogicTests/LegacyWireRoutingKeyTests` feeds those dictionaries and asserts `code == invalid_params` and canonical `tab_id` / `tab_ref`. The same test accepts `tab_id`, `surface_id`, `pane_id`, `panel_id`, `area_id`, `workspace_id`, `window_id`. remote build host: `c11-logic` `-only-testing:c11LogicTests/LegacyWireRoutingKeyTests`.
2. Live send. Incident: focused-tab delivery. `tests_v2/test_routing_key_typo.py` on an remote build host tagged build: `tab.send_text` with `surfaceId` returns `invalid_params` naming `tab_id`, and `tab.read_text` of the focused tab does not contain the sentinel. The same call with `surface_id` set to that tab delivers the sentinel.
3. Nested and non-selector keys. Incident boundary, not a new filter. Unit test: `{metadata: {surfaceId: "x"}, title: "t", text: "hi"}` and `{surfce_id: "tab:1"}` return nil. A key `surfaceTitle` returns nil.
4. Skill limit. The one sentence in `api.md` is the fixture for AC4. No source-grep test.

Tagged-build proof is the tests_v2 script (criteria 2). Not visual. No computer-use pass. No soak. The check is one pass over the top-level keys of a socket request, off `hitTest` and `forceRefresh`.

## Hot path, strings, persistence
Socket parse only, before handler dispatch. Worker seam is already off main. `processV2Command` is main-actor; the check is the same dictionary walk, before UI work. No new main hop. No persistence, no migration.

New key: `socket.error.unsupported_routing_key`, English only. Tokens `%1$@` and `%2$@` must survive C11-291. No other user-facing string.

## Cut line
No per-method unknown-key registry. No edit to the alias tables. No removal of C11-248 aliases. No nested scan. No CLI flag parser. C11-284 merges first. Enable its `routing.canonical_keys` entry and have the two rejection-dispatch seams use that typed feature in this PR. Add `Sources/CapabilityFeatures.swift` to the files changed. Do not create a second registry or substitute a PR note. Tagged capabilities must include this flag and the live typo/alias scenarios must pass on that same artifact (audit finding 8).

## Dependencies and conflicts
- C11-248 may still edit `LegacyWireAliases.swift`. This PR only adds a function. Use an ordinary merge if the tables move; preserve pushed history.
- C11-282 adds a `tab.read_selection` case near `SocketDispatch.swift:68`. This PR touches `:45-53` and `:950`. Same file, different regions. Expect a small conflict.
- C11-283, C11-281, C11-284, C11-280 own `CLI/c11.swift`. This PR stays out of it.
- Skill: one sentence in `skills/c11/references/api.md`. Other CLI tickets edit that file. Keep the hunk to that sentence.
- C11-291 translates the new key. C11-292 sign-off depends on this ticket. Implementation starts after C11-284 merges; this is the capabilities foundation barrier.

## Decisions
None for operator. Selector set is the id/ref forms in the existing tables plus `window_id` and `workspace_id`. Non-id alias keys are out, because a title typo does not retarget.

## Build-mode notes
Branch `c11-1.0/C11-279-routing-keys` from current origin/main after predecessor merges (this worktree currently holds the intake-base branch). One PR. Tests on remote build host only. Attribute any implementation commit to its actual author/model, not the previous planning owner. Only the Merge Captain syncs installed skills from merged main after landing; this owner never syncs or edits installed skills. Do not merge.

## Codex takeover verification
Owner: agent:codex-cli. Verified ticket, stored plan and cited code on intake origin/main 0ff8887e5e965400b01645ef40b85fd0b2605cf2. All behavioral checks above are planned, unperformed. Planning hold remains: no builds, tests, product-code commits or pushes until explicit BUILD MODE. Branch from current origin/main when this ticket starts, retaining predecessor merges and previous local commits.


## Build-mode authority and foundation sequencing (2026-10-01)
The Orchestrator sent NEXT C11-279 while C11-284 remains in independent review, explicitly requiring a new branch from origin/main and prioritizing any C11-284 repairs. Origin/main refreshed to 72cd3882df1fad2a3e2d74a817a18eb1d980b76f; C11-257 has landed, but CapabilityFeatures is not yet on main. Preserve the original intake branch (no useful commits) and use new branch c11-1.0/C11-279-canonical-routing-keys.

Implement and commit the pure selector detector and its logic tests first; open a draft PR for CI. This is useful independent work while the C11-284 foundation is reviewed. Dispatch activation and the routing.canonical_keys entry still require C11-284 to land; do not duplicate its registry or introduce a fallback. Then incorporate origin/main with an ordinary merge, preserving all local commits (no resets, stashes, cleans or force pushes), wire both seams and enable the typed feature in the same commit. Leave the alias tables unchanged. Prefer snake-case public names for normalized plural-selector collisions with the exact accepted camelCase result keys. If C11-284 findings arrive, stop C11-279 at a clean commit and repair C11-284 first. No local Swift builds/tests or DEV launches; GitHub CI until ATLAS BUILDS LIVE. The Orchestrator permits a handoff with CI pending so independent review runs in parallel; the captain still requires green CI before landing.


## Resumption after foundation landing (2026-10-02)
C11-284 landed as 2d2440ac65. The Orchestrator authorized 279 after handoff of 281; 281 is now handed off in draft PR519. Merged fetched origin/main b6f239bd07 into the parked 279 branch, retaining all history; merge head 3bb6729f5b778ae22a4bb62fc6dc89cd14999a43. Resolved only two additive project-file conflicts by retaining both entry sets. C11-294's inherited Ghostty pointer is 5830d1976eecca0d7dee202aef8fb2338d99ed6d; no submodule edits.

Enable only CapabilityFeatures.ID.canonicalRoutingKeys and wire the bounded rejection in both planned dispatch seams, using that same typed policy. Validate LegacyWireRoutingKeyTests and CapabilityFeaturesTests with the actual remote build host test action, then build the same clean committed source as a tagged Debug artifact on remote build host. The live script now requires deliberate C11_279_SOCKET so an inherited operator socket cannot be selected accidentally. Capture capabilities, worker/main errors, absence of rejected input and listed-alias delivery. This checks socket admission before fallback, not typing performance. No local machine build/launch, no computer use, no installed-skill sync. Keep the existing PR508 draft and push only at handoff. Targeted checks passing permits HANDOFF with CI pending; Captain requires exact-head green CI for landing.


## Final implementation and validation source
Foundation is merged and both worker/main-actor seams now reject before handler target resolution through CapabilityFeatures.ID.canonicalRoutingKeys. No CLI parser or alias-table changes. Resumed from parked f28885d135, merged fetched main 7edd59b882 with additive project entries retained; merged head 0ecf575109. Added the planned source-skill sentence explaining exact spellings, accepted wire aliases and the surfce_id limit; final clean head 603a4d91e4d7f2ef7c9d89abfde6b56c52c1e7a4. No installed-skill sync: Captain only after merge.

Actual remote test action aa8a7b500c6f41d2a4bfd8162619e442 passed all six LegacyWireRoutingKeyTests/CapabilityFeaturesTests at that clean head. Tagged Debug 3fed8507b64a47f88704110706343c44 compiled the same source. Run the existing tests_v2/test_routing_key_typo.py with deliberate C11_279_SOCKET at that tag; archive nullable build identities as returned plus the clean source manifest and retained executable/dylib/CLI hashes. No computer use, human-keystroke work or numerical performance-pass claim. Draft PR508 is updated/pushed only at handoff, with CI pending for Captain's exact-head landing gate. User queue is now 279 then 282; other seats own 280/283, and native prerequisite 294 is on main.


## Resumption after C11-281 FRESH handoff
281 merged main and handed off clean 945d90eaac for FRESH review after all 14 requested tests and both live CLI paths. Resume 279 from preserved 603a4d91e4; ordinary merge of fetched main 2496017a28e1066a93edb3ad933aa32fe7f62ff6 gives eb80662004cc3ed10db3013374598511074931d0. The only conflict was the typed registry: retain this ticket's routing.canonical_keys and main's create.initial_input, both version 1. send.raw remains disabled until the implementing 281 merge is included. No CLI edits or alias-table changes. Repeat the six targeted tests plus tagged worker/main/alias runtime proof at this clean merged head. Existing draft PR508 updates/pushes only at handoff. CI pending is allowed for parallel review; Captain requires exact-head green CI. Do not sync installed skills. Preserve private original artifact locally, stop owned tag and delete its remote caches after the run. Then C11-282, not 280/283.
