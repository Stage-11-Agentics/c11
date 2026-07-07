# Plan Review: C11-159 — Socket dispatcher extraction

Reviewer: Claude (plan review pass). Claims were spot-verified against the working tree, not taken on faith.

## 1. Verdict

**PASS** — Plan is complete, feasible, and aligned. Implementation can proceed.

## 2. Summary

Reviewed the plan to relocate the socket command dispatch (~17k LOC of handlers plus four switches) out of `TerminalController.swift` into per-domain files under `Sources/SocketHandlers/`, with zero behavior change, against SPEC DX-1..DX-5. The plan is grounded in measured fact rather than assumption — I independently verified the load-bearing claims (file is 20,351 LOC; `processCommand` at 2388 with 112 cases; `processV2Command` at 2755 with 227 cases; the four `nonisolated` off-main entry points at 1980/2001/2030/2067; browser at 84 v2 cases / 106 `v2Browser*` methods; the class is `@MainActor` at line 120; `TerminalController.swift` is a member of the `c11` target only; no file-system-synchronized groups in the pbxproj; the DEBUG isolation probe exists at line 1984) and every one checked out. The only concerns are minor: a stale reference to a nonexistent `tests_v2/README`, imprecise grep invocations in the DX-3 oracle, and a DX-5 interpretation (the per-domain dispatch slices) that this review should settle now so code review doesn't relitigate it.

## 3. Issues

**[MINOR] §2 / §8 — The `grep -rc` invariant oracles don't measure what the plan says they measure**
`grep -rc "nonisolated" Sources/` and `grep -rc "DispatchQueue.main.sync" Sources/` print *per-file* counts, one line per file. A pure cut/paste conserves the *total* but redistributes the per-file counts, so a naive before/after diff of `-rc` output will always differ and the check either gets skipped or hand-waved. Since DX-3 positions these as hard conservation oracles, the invocation should produce a single conserved number.
**Recommendation:** Use total-occurrence forms, e.g. `grep -ro "nonisolated" Sources/ --include='*.swift' | wc -l` and the same for `DispatchQueue.main.sync`, recorded before and after. (Current baseline for reference: `nonisolated` appears 121 times in `TerminalController.swift` alone.)

**[MINOR] §7 — References `tests_v2/README`, which does not exist**
Step 3 says "invocation per `tests_v2/README`", but there is no README or other markdown in `tests_v2/`. The canonical guidance lives in the repo `CLAUDE.md` (Python socket tests section): run against a tagged build's socket via `C11_SOCKET=/tmp/c11-debug-<tag>.sock`. An implementer following the plan verbatim will hit a dead pointer at the exact moment they're establishing the DX-2 baseline.
**Recommendation:** Replace the pointer with the concrete invocation (pytest over `tests_v2/` with `C11_SOCKET=/tmp/c11-debug-dx-baseline.sock` exported), and pin the exact test selection (full `tests_v2/` vs. socket-focused subset) in the baseline note so the post-change run is guaranteed to be the same set. Note that tests_v2 has at least one documented known-flaky visual case (`test_visual_screenshots.py` D12, per `docs/agent-browser-port-spec.md`) — the parity assertion should compare normalized results with any known-nondeterministic cases identified up front, exactly as §7 already intends with the "normalized result summaries" language.

**[MINOR] §4 — The slice design is a defensible DX-5 reading, but record the ruling now**
The chosen design introduces new symbols (`v2Dispatch<Domain>`, per-domain v1 head sets) that did not exist before, and DX-5 says "no new abstractions beyond the handler seam itself." The plan pre-argues this correctly — a per-domain dispatch function *is* the handler seam DX-1 demands, the router (parse, auth-gate, policy, main-sync bridge) is untouched, and the wire surface is byte-identical — and it offers a wholesale-move fallback. This review accepts the slice design as within DX-5. The v1 variant deserves one extra care point: replacing a single 112-case switch with per-domain `Set<String>` membership checks tried in order is behavior-identical only if the union of the sets exactly equals the original case-label set (no omissions, no duplicates across sets) and the final fallthrough produces the identical unknown-command response.
**Recommendation:** Proceed with the slice design; do not fall back. Add one verification line to §8: assert the union of all v1 domain head-sets equals the original 112 case labels (script-extractable from the base commit), disjoint across sets, and diff the unknown-command/`method_not_found` responses for one probe per space against baseline. Cite this review in the PR body as the DX-5 ruling on slices.

**[MINOR] §5 — Access widening to `internal` is module-wide exposure; keep it inventoried**
Dropping `private` makes each widened symbol visible to the entire module, not just `SocketHandlers/`. That is the correct and only practical mechanism here (extensions in other files cannot see `private`/`fileprivate`, and stored properties cannot move to extensions), and the plan's compiler-driven, single-token-diff discipline is right. But across ~14 domains the widenings will accumulate, and DX-5 reviewers need the complete set to audit.
**Recommendation:** Maintain a running list (one line per symbol) of every `private` deletion in the PR description or a commit-message trailer per domain commit, so the code-review pass can confirm the widened set is exactly the referenced set and nothing widened speculatively.

## 4. Positive Observations

- **Measured, not assumed.** Every structural claim I checked — line numbers, case counts, isolation keywords, target membership, absence of fs-synced pbxproj groups, the theme domain's existing `ThemeSocketMethods` delegation, the 84-case/106-method browser topology — matched the working tree exactly. This is the standard plan-level diligence should meet.
- **DX-3 is treated as the sharpest gate and handled with real Swift semantics.** The plan correctly identifies the silent-tier-flip hazard (extension members of a `@MainActor` class inherit main-actor isolation unless `nonisolated` is carried over) and builds three independent checks around it: keyword conservation, the live DEBUG isolation probe (verified present at `TerminalController.swift:1984`), and co-locating the off-main workers with the dispatch for one-glance review.
- **The browser DX-4 landmine is found in planning, not implementation.** Spotting that a naive one-file-per-domain split puts browser (~4k LOC) over the 3k ceiling, and pre-planning the 4-way sub-split with a ≤2k buffer target, is exactly the class of issue plan review exists to catch — and the plan caught it itself.
- **Smallest-blast-radius ordering with per-domain commits** makes each step independently revertible and keeps the compiler as a per-step parity oracle rather than a big-bang gate.
- **pbxproj strategy matches the repo's documented convention** (gem normalization expected, verify by `xcodebuild -list` + membership counts + build/test, never line-by-line diff) and correctly scopes new files to the `c11` target only, consistent with the `BUNDLE_LOADER` arrangement.
- **Honest fallback.** Offering the wholesale-switch-move alternative and inviting the reviewer to rule on the DX-5 question, rather than burying the interpretation, is the right way to handle contract ambiguity.
