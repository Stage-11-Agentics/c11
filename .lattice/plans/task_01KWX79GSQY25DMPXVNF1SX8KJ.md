# C11-159 — Socket dispatcher extraction (Wave 1 keystone)

**Mode:** inline-full · **Delegator:** agent:ts-dx-delegator · **Branch:** `ts/dx-dispatcher-extraction`
**Contract:** `docs/cycles/2026-07-truth-and-stability/` (SPEC §DX, EVALUATION DX-1..5, BUILDPLAN row 1)
**Mandate:** move the socket command dispatch out of `Sources/TerminalController.swift` into per-domain
handler units under a dedicated directory. **Zero behavior change. Mechanical relocation only.**

---

## 1. What "the dispatch" actually is (measured, not assumed)

`TerminalController.swift` is **20,351 LOC**. The socket surface inside it is four switches plus
~295 handler methods plus shared helpers. The measured topology:

| # | Function | Line | Isolation | Cases | Role |
|---|----------|------|-----------|-------|------|
| A | `processCommand(_:)` | 2388 | `@MainActor` (implicit) | **112** | v1 legacy space-separated dispatch (`switch cmd`, 2404→2748) |
| B | `processV2Command(_:)` | 2755 | `@MainActor` (implicit) | **227** | v2 JSON-RPC dispatch (`switch method`, 2806→3335) |
| C | `socketWorkerV2Response(_:)` | 1980 | **`nonisolated`** | 4 | off-main fast path for `surface.send_text/send_key/read_text/clear_history` |
| D | `socketWorkerV1Response(head:args:)` | 2067 | **`nonisolated`** | 6 | off-main telemetry workers (`report_pwd`, `report_shell_state`, `report_git_branch`, `clear_git_branch`, `ports_kick`, `agent_kick`) |
| — | `processCommandUsingSocketExecutionPolicy` | 2001 | `nonisolated` | — | the routing entry that tries C → D → asyncAck → main-sync(A/B) |
| — | `asyncAckResponseIfNeeded` | 2030 | `nonisolated` | — | off-main ack for `asyncAckV1Commands`, mutation via `main.async` |

**v2 domain distribution (227 cases):** browser 84, debug 35, workspace 25, surface 21, pane 13,
theme 10, conversation 6, window 5, system 5, snapshot 5, notification 5, app 3, markdown 2,
feedback 2, tab 1, sidebar 1, settings 1, session 1, mailbox 1, auth 1.

**Handler bodies:** ~295 `v2*` methods span lines ~3337→20351 (~17k LOC). Not all domains have
inline methods — **theme** already delegates to a separate `ThemeSocketMethods` type (its 10 cases are
one-liners), so theme extraction is trivial. **browser** is the opposite extreme: 106 `v2Browser*`
methods spanning ~10923→14771 (~4k LOC) — this single domain **exceeds the DX-4 3k-LOC ceiling** and
must be split into sub-files.

**Shared, cross-domain infrastructure** (used by many domains, currently `private`):
- Encode/parse helpers (`private nonisolated`): `v2Ok`, `v2Error`, `v2Result`, `v2Encode`, `v2OrNull`,
  `v2String`, `v2Int`, `v2Bool` (lines 4056–4375).
- Ref-map machinery (`private`): `v2RefreshKnownRefs` (4256) + the v2 handle state
  (`v2RefByUUID`, `v2UUIDByRef`, `v2NextHandleOrdinal`, browser element/frame/dialog/network state, …).
- Class state handlers touch: `tabManager`, `accessMode`, `withSocketCommandPolicy`,
  `executionPolicy`, the `socketWorkerV1Commands` / `asyncAckV1Commands` allowlists.
- **34 `private` stored properties** on the class; many are read/written by handlers.

---

## 2. Threading-tier table (DX-3 — preserve verbatim)

DX-3 is the sharpest correctness gate: **no handler may change threading tier.** The seam is bimodal.

| Tier | Members | Rule when moved |
|------|---------|-----------------|
| **off-main / `nonisolated`** | C (`socketWorkerV2Response`), D (`socketWorkerV1Response`), `asyncAckResponseIfNeeded`, `processCommandUsingSocketExecutionPolicy`, the pure parser helpers (`tokenizeArgsStatic`, `parseOptions*`), the worker variants (`reportPwdWorker`, `reportShellStateWorker`, `reportGitBranchWorker`, `clearGitBranchWorker`, `portsKickWorker`, `agentKickWorker`), and the `nonisolated` encode helpers (`v2Ok`/`v2Error`/`v2Result`/`v2Encode`/`v2OrNull`/`v2String`/`v2Int`/`v2Bool`) | **Keep the `nonisolated` keyword literally.** An extension method on a `@MainActor` class is `@MainActor` unless it says `nonisolated`; dropping the keyword silently makes it main-actor. Every moved off-main member keeps `nonisolated` in its signature. |
| **main-actor** | A (`processCommand`), B (`processV2Command`), and effectively all `v2*` handler methods reached through them (they execute under `MainActor.assumeIsolated`) | **Do not add `nonisolated`.** Leave the signature's isolation exactly as-is. Handlers stay implicitly `@MainActor` via the class annotation, inherited by the extension. |

**Invariants that must hold before == after (audited by diff, DX-3):**
- `grep -rc "DispatchQueue.main.sync" Sources/` unchanged (no telemetry path gains a main-sync;
  none loses one either).
- `Self.socketWorkerV1Commands`, `Self.asyncAckV1Commands`, and `executionPolicy(forV2Method:)`
  contents byte-identical (these allowlists decide who runs off-main; changing membership = behavior change).
- No `nonisolated` added or removed anywhere. Verify: `grep -rc "nonisolated" Sources/` before == after
  (count is conserved because we cut/paste, never author).
- The DEBUG isolation probe in `socketWorkerV2Response` (`dlog("v2.\(method) isMain=…")`) stays intact and
  `#if DEBUG`-gated — it is our live post-move oracle that off-main methods still run off-main.

---

## 3. Target layout — `Sources/SocketHandlers/` (DX-1, DX-4)

Dedicated directory, one file per domain; browser sub-split. Estimated LOC (handlers + slice), all
under the 3k ceiling:

```
Sources/SocketHandlers/
  SocketDispatch.swift            # A + B top-level dispatch (thin), moved out of TerminalController — ~250 LOC
  SocketV2Support.swift           # shared nonisolated encode/parse + ref-map helpers, widened to internal — ~500 LOC
  WindowHandlers.swift            # window.* (5) + v1 window cmds + slice — ~250
  WorkspaceHandlers.swift         # workspace.* (25) + v1 workspace cmds + slice — ~1.2k
  SurfaceHandlers.swift           # surface.* (21) + v1 surface cmds + slice (NOTE: worker path C stays w/ dispatch) — ~1.5k
  PaneHandlers.swift              # pane.* (13) + slice — ~1k
  ThemeHandlers.swift             # theme.* (10) slice only (logic already in ThemeSocketMethods) — ~120
  ConversationHandlers.swift      # conversation.* (6) + slice — ~400
  NotificationHandlers.swift      # notification.* (5) + v1 notify cmds + slice — ~400
  SnapshotHandlers.swift          # snapshot.* (5) + slice — ~400
  SystemHandlers.swift            # system.* (5) + auth.* (1) + app.* (3) + slice — ~400
  MetadataHandlers.swift          # v1 telemetry (set_status/report_meta/…) + mailbox.* + settings.* + sidebar.* + session.* + tab.* + slice — ~1.5k
  MarkdownFeedbackHandlers.swift  # markdown.* (2) + feedback.* (2) + slice — ~300
  DebugHandlers.swift             # debug.* (35) + slice — ~1.5k
  BrowserCoreHandlers.swift       # browser lifecycle/nav/panel resolution + slice router — ~1.5k
  BrowserDOMHandlers.swift        # browser DOM/query/eval — ~1.5k
  BrowserInputHandlers.swift      # browser input/click/type/touch — ~1.2k
  BrowserDialogNetworkHandlers.swift # browser dialogs/downloads/network capture — ~1.5k
```

Exact browser sub-split boundaries are chosen at implement time by walking the 106 `v2Browser*`
methods and cutting on natural clusters so each file lands ≤~2k LOC (buffer under the 3k ceiling).
The off-main workers C/D live **with the dispatch** in `SocketDispatch.swift` (they are dispatch, not
domain handlers) so their `nonisolated` context is obvious and reviewable in one place.

**DX-4 arithmetic:** relocating ~17k LOC of handlers + ~600 LOC of switch bodies drops
`TerminalController.swift` from 20,351 to **~3–4k LOC** — well below the ~10k target. No new file exceeds ~2k.

---

## 4. Dispatch decomposition — per-domain slice delegation (DX-1, DX-5)

**Chosen design (recommended):** each domain file owns a **dispatch slice** plus its handlers; the
top-level dispatch delegates by prefix. This most defensibly satisfies DX-1 ("command handling is
organized into per-domain handler units") while staying inside DX-5 ("no new abstractions beyond the
handler seam itself" — a per-domain slice *is* the handler seam; the router — parse, auth-gate, policy,
main-sync bridge — is unchanged).

v2 shape (in `SocketDispatch.swift`, still `@MainActor`, still inside `withSocketCommandPolicy`):
```swift
switch v2Domain(of: method) {          // v2Domain = String(method.prefix(upTo: "."))
case "window":       return v2DispatchWindow(method, id: id, params: params)
case "workspace":    return v2DispatchWorkspace(method, id: id, params: params)
case "browser":      return v2DispatchBrowser(method, id: id, params: params)
...
default:             return v2Error(id: id, code: "method_not_found", message: "Unknown method")
}
```
Each `v2Dispatch<Domain>(_:id:params:) -> String` in its domain file contains **verbatim the original
`case` block** for that domain (same `v2Result(id: id, self.v2Xxx(...))` bodies), ending in the same
`method_not_found` error for an unknown method in that prefix. **Zero wire change:** same method
strings, same response envelopes, same error codes.

v1 shape: identical pattern with `v1Dispatch<Domain>(cmd:args:) -> String?` returning `nil` to fall
through (v1 has no dotted prefix, so v1 slices are matched by a per-domain `Set<String>` of command
heads, and `processCommand` tries them in order, preserving the original first-match semantics —
there are no duplicate `case` labels today so order is immaterial to behavior).

**Fallback design (if plan-review prefers minimal transformation):** move `processCommand` /
`processV2Command` **wholesale and unmodified** into `SocketDispatch.swift`, keeping each as one giant
switch, and move only the handler *methods* to domain files. This satisfies DX-1's literal text
("switch no longer lives in TerminalController.swift") with the least transformation, at the cost of a
single 500-line switch file. I recommend the slice design but will accept this if review calls the
slices a "new abstraction."

---

## 5. The mechanical move recipe

Executed per domain, smallest-blast-radius first (theme → window → notification → snapshot → system →
markdown/feedback → conversation → pane → surface → workspace → metadata/v1 → debug → browser×4 → the
dispatch itself last). One commit per domain (or per browser sub-file) so each is independently
reviewable and revertible.

**Per-domain steps:**
1. Create `Sources/SocketHandlers/<Domain>Handlers.swift` with `import` lines matching
   `TerminalController.swift`'s (Foundation, AppKit, GhosttyKit as needed) and `extension TerminalController { }`.
2. **Cut** the domain's `case` block from switch A/B and paste it into the new `v2Dispatch<Domain>` /
   `v1Dispatch<Domain>` function body inside the extension — **bodies unmodified**.
3. **Cut** the domain's handler methods (`v2<Domain>*`) from the class body into the same extension —
   **bodies unmodified, isolation keywords preserved verbatim** (§2).
4. In `SocketDispatch.swift` (or, until it exists, still in `TerminalController.swift`), add the one
   delegation line for this domain.
5. Widen access **only as forced by the compiler**: any symbol the moved code references that is
   currently `private`/`fileprivate` and now lives in a different file becomes `internal` (drop the
   `private` keyword; never add `public`). Keep `nonisolated` and `@MainActor` untouched on those
   decls. Each such widening is a single-token diff.
6. Add the new file to the `c11` target (§6).
7. Build `c11-logic` (with lock) — the compiler is the parity oracle for "did I break a
   reference." Green → commit → next domain.

**Access-widening discipline (the main risk surface, DX-5):** the *only* edits permitted to a moved
line are (a) the cut/paste itself and (b) deleting a leading `private ` on a declaration that must be
seen cross-file. A reviewer must be able to confirm every non-move hunk is exactly a `private`
deletion. Shared infra (`v2Ok`/`v2Error`/`v2Result`/`v2Encode`/`v2OrNull`/`v2String`/`v2Int`/`v2Bool`,
`v2RefreshKnownRefs`, the v2 ref-map state, `tabManager`, `accessMode`, `withSocketCommandPolicy`,
`executionPolicy`, allowlist statics) will need widening; prefer relocating the truly shared,
`nonisolated` encode/parse helpers into `SocketV2Support.swift` as `internal nonisolated` and leaving
`@MainActor` class state in `TerminalController.swift` widened in place. **No renames** (DX-5): the
methods keep their exact names; only file location and access qualifier change.

**Localization / skill / doc impact:** none. This ticket adds no user-facing strings, renames no CLI
surface, changes no wire response — so no `Localizable.xcstrings` pass and no `skills/c11/` edit are
owed (boot §4). If, and only if, an unavoidable rename surfaces, the PR gains the matching skill edit +
`scripts/sync-installed-skills.sh` run — but the plan is to avoid it entirely.

---

## 6. pbxproj strategy

No file-system-synchronized groups exist, so each new file needs explicit project entries.
`TerminalController.swift` is a member of a **single target** (`c11`; one `PBXBuildFile` ref) — the
c11-logic/c11Tests targets load `c11.debug.dylib` via `BUNDLE_LOADER`, so new handler files are added
to the **`c11` target only**.

- Add files with the `xcodeproj` Ruby gem (create a `SocketHandlers` `PBXGroup`, add each file ref +
  `PBXBuildFile` to the `c11` Sources phase). The gem **normalizes the whole pbxproj on save**
  (indentation, `PBXBuildFile` ordering, some reissued object IDs) — a multi-thousand-line diff is
  **expected and not reviewed line-by-line** (documented in the PR body).
- **Do not** hand-restore whitespace to fight the gem — that compounds churn on the next save.
- **Verification** replaces eyeballing: `xcodebuild -list` shows all schemes intact; per-file
  membership confirmed by `grep -c "<File>.swift" project.pbxproj` == expected; `xcodebuild
  -showBuildSettings` spot-check unchanged; and the real gate — the `c11` + `c11-logic` builds compile
  and the `c11-logic` **test** action stays green.

---

## 7. Baseline & post-change parity procedure (DX-2)

**Baseline (before the first code change, at base commit):**
1. Acquire the xcodebuild resource lock (boot §3), heartbeat every ~10 min.
2. `./scripts/reload.sh --tag dx-baseline` from this worktree at base HEAD; note the short SHA.
3. Run the tests_v2 socket suites against it with `C11_SOCKET=/tmp/c11-debug-dx-baseline.sock`
   (invocation per `tests_v2/README`). Capture **full** stdout+stderr to
   `.lattice/artifacts/C11-159/tests_v2-baseline-<sha>.log` (absolute parent path) and a one-line
   pass/fail/skip summary.
4. `lattice attach C11-159 --type note --role validation --inline "tests_v2 parity BASELINE @ <sha>:
   <summary + log path>"`. Commit the log file under the worktree.
5. Release the lock.

**Post-change (identical procedure, after implement + code-review fixes):**
- `./scripts/reload.sh --tag dx-post`; same suite against `/tmp/c11-debug-dx-post.sock`; save
  `tests_v2-post-<sha>.log`.
- **Assert identical results** — same suite pass/fail/skip counts and same set of passing test ids.
  A diff of the normalized result summaries must be empty. Attach the comparison `--role validation`
  with the delta (expected: none).
- Full `c11-logic` test action green (DX-2). CI green is **necessary, never sufficient** (boot §1, §5).

---

## 8. Verification matrix (each EVALUATION row → its check)

| Row | Check | How |
|-----|-------|-----|
| DX-1 | dispatch switch absent from TerminalController.swift; per-domain handlers present | `grep -n "switch method\|switch cmd" Sources/TerminalController.swift` → none; `ls Sources/SocketHandlers/` shows per-domain files |
| DX-2 | behavior parity | baseline == post tests_v2 (§7); full `c11-logic` green; CI green |
| DX-3 | threading/focus preserved | diff audit: `nonisolated` count conserved; `DispatchQueue.main.sync` count conserved; allowlists byte-identical; DEBUG isolation probe still fires off-main |
| DX-4 | LOC targets | `wc -l Sources/TerminalController.swift` < ~10k (target ~3–4k); `wc -l Sources/SocketHandlers/*.swift` each < 3k |
| DX-5 | mechanical only | diff audit: no method renames (`git diff` shows moves, not renames of symbols), no changed response strings/codes, no new types beyond the per-domain extensions + `SocketV2Support` |

Focus policy (SPEC hard constraint): the extraction touches no focus logic; non-focus socket commands
still don't activate the app. Confirmed by the move being pure relocation.

---

## 9. Risks & mitigations

- **R1 — access widening cascades.** Moving a handler exposes a chain of `private` deps. *Mitigation:*
  compiler-driven, smallest-blast-radius-first ordering; each widening is a reviewable single-token
  diff; keep shared state in `TerminalController.swift`, only relocate the `nonisolated` stateless
  encode/parse helpers. If widening balloons past a domain, keep that domain's handlers + slice in the
  **same file** so intra-domain `private` calls stay legal (only slice entry points + genuinely shared
  infra widen).
- **R2 — silent tier flip (DX-3).** An extension method loses `nonisolated` and becomes main-actor.
  *Mitigation:* conserved `nonisolated` grep count + the live DEBUG isolation probe + off-main workers
  co-located in `SocketDispatch.swift` for one-glance review.
- **R3 — pbxproj churn masks a membership error.** *Mitigation:* verify by membership `grep -c` +
  `xcodebuild -list` + the `c11-logic` test action, never by reading the diff.
- **R4 — browser file exceeds 3k (DX-4).** *Mitigation:* pre-planned 4-way browser split; measure each
  sub-file with `wc -l` before committing; re-cut if any lands >~2.5k.
- **R5 — a case block has a subtle fallthrough / shared local.** Swift has no implicit fallthrough and
  each case returns; the switches are already flat `case X: return handler(...)`. *Mitigation:* verified
  flat structure; the compiler catches any missed local capture.

---

## 10. Phase exit criteria for this plan

Move to `planned` once this plan is written. Then plan-review (boot §5.2). Baseline (§7) runs at the
top of Implement, before the first cut. Stop at `pr_open`; the Orchestrator merges.

---

## 11. Plan-Review Cycle 1 Resolutions (AUTHORITATIVE — overrides earlier text on conflict)

Plan-review verdict: **PASS** (artifact `art_01KWXPEBWP6B1ZG5DM9C36MNCZ`), 4 MINOR issues. All accepted
and resolved below. No blocking findings; implementation proceeds under these amendments.

**R-1 (fixes §2/§8 grep oracle) — use total-occurrence counts, not per-file `-rc`.**
`grep -rc` prints one count per file; a cut/paste conserves the *total* but redistributes per-file, so
`-rc` before/after always differs and the DX-3 oracle is meaningless. Use conserved single numbers:
- `grep -rho "nonisolated" Sources/ --include='*.swift' | wc -l` (baseline: `nonisolated` appears 121×
  in `TerminalController.swift` alone — record the whole-`Sources/` total at base HEAD before the first cut).
- `grep -rho "DispatchQueue.main.sync" Sources/ --include='*.swift' | wc -l`.
Record both at base HEAD and assert equal at PR HEAD. These supersede the §2/§8 grep forms.

**R-2 (fixes §7 dead pointer) — concrete tests_v2 invocation; no `tests_v2/README` exists.**
Replace "invocation per `tests_v2/README`" with: run `pytest tests_v2/` (full suite, pinned selection
recorded in the baseline note) with `C11_SOCKET=/tmp/c11-debug-dx-baseline.sock` exported against the
tagged build's socket (repo `CLAUDE.md`, Python-socket-tests section, is the canonical guidance).
Pin the **exact** test selection in the baseline note so the post run is the identical set. Identify
known-nondeterministic cases up front (at minimum `test_visual_screenshots.py` D12, per
`docs/agent-browser-port-spec.md`) and exclude them from the strict parity assertion (compare
normalized summaries, as §7 already intends). The full baseline log still captures everything; parity is
asserted on the deterministic subset.

**R-3 (settles §4 DX-5 ruling) — slice design ACCEPTED; do not fall back. Add v1 union check.**
The per-domain `v2Dispatch<Domain>` slices and v1 per-domain head-sets *are* the handler seam DX-1
demands (router untouched, wire byte-identical); review rules them within DX-5. Proceed with the slice
design; the §4 "wholesale-move fallback" is **withdrawn**. One added verification (folded into §8, DX-5):
- Extract the original 112 v1 case labels from base HEAD; assert the **union** of all v1 domain
  head-sets equals that set exactly, **disjoint** across domains (no omission, no cross-set duplicate).
- Diff the unknown-command / `method_not_found` response for one probe per protocol (v1 + v2) against
  baseline — must be byte-identical.
Cite this review (`art_01KWXPEBWP6B1ZG5DM9C36MNCZ`) in the PR body as the DX-5 ruling on slices.

**R-4 (hardens §5 access-widening audit) — inventory every `private` deletion.**
Maintain a running list, one line per widened symbol, in each domain commit's message (trailer
`Widened:`) and consolidated in the PR body. Code review confirms the widened set equals exactly the
cross-file-referenced set — nothing widened speculatively, nothing left `public`. This makes the DX-5
"mechanical only" audit a checklist rather than a hunt.

These four amendments are binding for Implement, Code-review, and Validate.
