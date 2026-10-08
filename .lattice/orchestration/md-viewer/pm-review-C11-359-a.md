# C11-359 post-merge discovery review — Astra

Needs you: nothing. The Orchestrator and synthesis seat own reproduction and repair.

## Verdict: FAIL

One new blocking finding: **B1, evicted readers lose their content anchor when live reload inserts earlier lines**. No timing race or hostile local process is required. One non-blocking documentation correction follows.

- Reviewer: `agent:astra-md-pm-359`.
- Reviewed merge: `a95823705c3912d8def621e3b2b7ed3384f47a4c` (PR #621), detached in `/Users/atin/Projects/Stage11/code/c11-worktrees/md-pm-359-a`.
- Parent: `c37ced9d784b1a3b36ac7f5100af629a2004cad3`. Scope: `git show HEAD`, the merged native change, including its integration with the already-merged web bundle.
- The assigned review checkout was clean throughout. Builds, test probes and guard mutations ran through Atlas tag `pm-359-a` from a separate disposable worktree. No production edit, commit, push, release, or new ticket.
- Prior reviews, both synthesis verifications, the eviction ruling, design/bridge/threat contracts and `run-state.md` were read. Existing H1–H8 and later hardening additions are not new findings here.
- Reproduction source, exact patches and attributable Atlas logs/manifests: [pm-review-C11-359-a-evidence.zip](./pm-review-C11-359-a-evidence.zip).

## Invariants

1. **Document containment:** document text is data; only bundled scripts execute; images stay within the native directory capability and allowed raster types; one decode; arbitrary navigation/windows/network/files are refused. Click routing validates the original href independently. No new escape found.
2. **Compatibility and state:** open/get-content, live reload, drop, descriptions across panel types, pointer/focus/flash, zoom routing and session restore retain their behavior. Preference corruption falls back per field. **B1 breaks live-reload reading continuity after eviction.**
3. **Weight without reader disruption:** lazy creation, shared process resources, visible readers plus four hidden readers, query protection, and state restoration before display. Numeric position/mode/find restore passes for unchanged or appended content; it is insufficient for shifted source content (B1).
4. **Native policy:** no added typing hot-path work, blocking main-thread telemetry hop, agent-reachable modal or unguarded debug logging; new UI strings localized. No new policy violation found within the reviewed change.

## B1 — P2, BLOCKING: live reload while evicted restores an obsolete line number

**Locations:** `Sources/Panels/MarkdownRendererCache.swift:6` and `:14` capture only line/offset/mode/find; `Sources/Panels/MarkdownPanel.swift:114` saves that position, and `:276` replaces model content without relocating it; `Sources/Panels/MarkdownWebRenderer.swift:233` / `:237` blindly scroll the new document to the old line.

**Ordinary scenario:** the operator reads Section 40 of an agent-written document, visits enough other readers to evict it, and an agent inserts twelve earlier sections. Returning to the original panel shows Section 28. The document and its original Section 40 remain intact, but the reader has lost their place.

**Independent runtime reproduction:** Atlas `6577438fe9334ad58262057a6f912cf8`, exact merged production code with only two reviewer tests added to `MarkdownWebRendererTests.swift`. A real temporary file, file watcher, bundled WKWebView, native eviction event and non-visible AppKit window exercise the path. The probe waits for eviction and model reload before re-showing; it has no timing sleeps.

| Observation | Retained control | Evicted reader |
| --- | --- | --- |
| Before edit | Section 40, first source line 159 | Section 40, first source line 159 |
| Edit | Prepend 12 sections / 48 source lines | Identical edit |
| After edit / re-show | Section 40, first line 207 | **Section 28, first line 159** |
| Section 40 top before | 18.34375 px | 18.34375 px |
| Section 40 top after | 18.921875 px | **1665.921875 px**, outside viewport |
| Test | PASS (within 1 px) | RED: wrong heading and displaced content |

The failure is deterministic from state, not a race. `MarkdownReadingPosition` has no content identity or source revision; the model-only reload changes `content` while leaving the saved number unchanged. A retained renderer can match its original block/text anchor (`viewer.js` capture/restore); a recreated renderer receives only the obsolete number.

**Why it blocks:** design invariant 1 says text stays in place through live reload, and the ticket promises live reload with scroll held. Eviction is an invisible implementation detail. In the product's normal many-panel workflow, whether the reader returns to the same content currently depends on how many other panels were visited. Preserving the same numeric source line after lines were inserted does not preserve the line being read.

**Why shipped tests miss it:** `evictionRestoresReadingState` changes the evicted document only by appending text, so every earlier source line remains valid. The visible reload test expands prose without shifting the relevant source line count. Both pass while this combined path fails.

**Fix direction:** retain a relocatable content anchor or translate the stored line against old/new source on model-only reload. Preserve the offset, mode and query, keep reload lazy, and define fallback when the anchored content itself is removed. Add the paired retained/evicted regression tests; also cover deletion above the unchanged anchor. Do not fix this by keeping every renderer alive.

## Non-blocking

**N1 — P3, threat note omits the newly restored mailto exception.** `docs/security-threat-model.md:254–256` lists markdown and web links and then says other schemes are refused; `Sources/Panels/MarkdownWebRenderer.swift:320` now opens validated mailto links, intentionally restored in the pre-merge repair. Update the documented allowlist and name its validation. The behavior itself is authorized and covered by `testLinkPolicyAllowsOnlyValidatedMailtoURLs`.

## Demonstration and regression checks

All builds/tests ran on Atlas through `scripts/remote-build.sh --tag pm-359-a --mode test`. The initial exact-head run was clean (`dirty=false`). Mutations were confined to the scratch worktree and captured in the archive.

| Atlas invocation | Condition | Result |
| --- | --- | --- |
| `8d90bd51a15b4489af1c8b5d10f7b62e` | Clean merged head, eight selected classes | **98/98 PASS**, 69 logic + 29 host; `TEST SUCCEEDED` |
| `6577438fe9334ad58262057a6f912cf8` | Production unchanged; two inserted-lines reload probes | Retained control PASS; evicted probe RED with two assertions (B1) |
| `5163b70d691a4ab4a19927e513bdb7a4` | Mutant A: remove hidden viewport, autosave fingerprint, decoded-control rejection, innermost list selection and drag filtering | **Every mutation caught**: 43 tests, 15 assertion failures |
| `178aad37ef5742a3ab81691ee51b176f` | Mutant B: navigation always allowed; query pin + both in-flight checks removed, epoch retained; add actual workspace restore probe | Native query residency and navigation-policy witnesses RED; workspace restore probe PASS |
| `ec51d9b9685a431b918b94d4a31fc265` | Mutant C: remove capture-epoch recheck, zoom-key guard, and workspace preference restoration | All three witnesses RED: stale capture evicts; zoom key is claimed; populated/malformed workspace preferences are lost (3 tests, 7 failures) |
| `d969b7c191ff4412a92f58b345d246d1` | All production guards restored; original slices plus drag class and new workspace restore probe | **102/102 PASS**, 69 logic + 33 host; production is exact-head, only the reviewer snapshot test is overlaid; `TEST SUCCEEDED` |

The owner's key reds were independently reproduced: without viewport retention the captured line changes from **160 to 50** and re-show lands on **52**; all four preference changes fail to invalidate autosave without the fingerprint loop; removing decoded-control rejection admits `hidden%00.md`. Nested list witnesses and four drag-type assertions also go red under their specific mutations. The query mutant is caught by the residency assertion before its later expected-eviction timeout; that timeout is a consequence, not the primary proof.

The new workspace probe serializes a real `Workspace` snapshot, decodes populated, legacy scale-only, and malformed-theme variants, and calls the real `restoreSessionSnapshot`. It checks stable panel ID, bound path, file content, all preferences, and lazy WebKit creation.

Other reviewed seams: one expanded-description renderer is shared by panel types; collapsed/sheet/sidebar description paths were not replaced. The merged description tests and host height tests pass. Terminal web routing retains option/settings/host-whitelist/placement order; browser and markdown share the same blocked drag identifiers. Model `markdown.get_content` remains independent of WebKit. All **14 new localization keys** contain English plus ja, uk, ko, zh-Hans, zh-Hant and ru; no format tokens were introduced. Project membership, package removals, removed legacy renderers, scope notes and skill changes were inspected; the clean Atlas build verifies compilation/linkage.

## Limits and handoff

This is fresh actual-WebKit/native-test evidence, not a fresh packaged on-screen acceptance run. I did not repeat physical-memory measurements, sandbox clicks/drop gestures, a packaged app restart, screen capture, network egress tracing or the known CSP-header/frame-origin witness gaps. The prior packaged/footprint verification remains prior evidence, not a new claim. B1 is reproduced by unmodified production code, a real watcher/cache lifecycle and DOM geometry; no product fix was attempted.

Cleanup completed: all scratch overlays restored, disposable scratch worktree removed, Atlas tag `pm-359-a` and its per-tag caches freed after checking for live processes. The assigned detached worktree and both submodule pins remain clean and unchanged. No server or sandbox guest was started. Report/evidence are handed to the Orchestrator only; ticket status remains unchanged.
