# C11-18 Review

## Verdict
APPROVE-WITH-MINOR-FIXES

The PR ships exactly the diagnostics-only artifact the plan called for, no
more no less: an env-var-gated `portalLog` helper modeled on `logBackground`,
seven call sites covering every lifecycle point the plan enumerated, a
standalone repro harness with `--help` and operator-warning ergonomics, and a
4-line CLAUDE.md entry pointing future agents at the env var, log path, and
script. Hot-path safety is preserved — no `portalLog` lands in `hitTest()`,
`forceRefresh()`, or `TabItemView` body. The four plan-flagged rework risks
(log volume, env name collision, async ordering, accidental `#if DEBUG`) are
all addressed correctly. The few minor issues below are absorbable by the
delegator without re-review and do not block the diagnostic value of the PR.

## Plan compliance

| Plan item | Status | Notes |
|-----------|:------:|-------|
| Commit 1 adds the helper but no call sites | ✅ | `2fa3156cb` is +91/-0 in `TerminalWindowPortal.swift`, all of it the `C11PortalDebug` enum + `portalLog` + token/frame formatters. No call sites until commit 2. |
| Commit 2 adds call sites at the six lifecycle locations the plan listed | ✅ | All six present: `bind` (before+after), `detachHostedView`, `hideEntry`, `synchronizeHostedView` (both orphan-skip branches + the result branch), `synchronizeAllEntriesFromExternalGeometryChange` (`geom.external`), `hideOrphanEntriesIfNeeded` (`orphan.hide`). |
| Commit 3 is the standalone repro harness, executable, with `--help` | ✅ | `4c6acc2f7` adds `scripts/repro-c11-18.sh`, mode `+x` (verified), `--help` extracts the script's own header. |
| Commit 4 is the CLAUDE.md doc entry, kept lean | ✅ | 4 lines under a new `## Diagnostics` section. Names env var, compat alias, log path, override env var, repro script. No prose bloat. |
| Out of scope: no portal-sync behavior changes | ✅ | `synchronizeAllHostedViews` is unchanged. No new call to `hideOrphanEntriesIfNeeded` from the regular sync path. |
| Out of scope: no submodule pointer change | ✅ | `git diff origin/main..HEAD --stat` shows three files only — no `ghostty` or `vendor/bonsplit` movement. |
| Out of scope: no double-replacement fix | ✅ | `Sources/Workspace.swift` not touched. |
| Out of scope: no new user-facing strings | ✅ | All output is operator-facing log text in English; no `String(localized:)` additions. |
| Out of scope: no `#if DEBUG` around the gate | ✅ | `portalLog` is shipped unconditionally; only `C11PortalDebug.isEnabled` (env-resolved) gates emission. The pre-existing `#if DEBUG dlog` paths are preserved, not replaced. |
| Both `C11_PORTAL_DEBUG` and `CMUX_PORTAL_DEBUG` honored; internal name is `c11PortalDebug` | ✅ | `C11PortalDebug.isEnabled` returns `truthy(env["C11_PORTAL_DEBUG"]) || truthy(env["CMUX_PORTAL_DEBUG"])`. Falsy values (`0`, `false`, `no`, `off`, empty) all rejected. Type/enum named `C11PortalDebug`. |
| Truncate-on-first-call after cold start | ✅ | `hasTruncated` flag inside the lock; `try? Data().write(to: url)` overwrites on first call, append on subsequent. |
| No async dispatch around `portalLog` | ✅ | Single `NSLock` + synchronous `FileHandle` writes. Ordering preserved — matches the `logBackground` contract. |
| Pattern fidelity vs `logBackground` (`Sources/GhosttyTerminalView.swift:2470-2492`) | ✅ | `NSLock` + monotonic `UInt64` sequence + ISO-8601 timestamp + `t+ms` uptime + thread label + open / `seekToEnd` / write / close. The portal helper drops the `frame60`/`frame120` fields (correctly — portal events aren't per-frame) but otherwise mirrors. |

## Findings

### Blockers
None.

### Major (escalate to Delegator)
None. Every reviewable concern is minor.

### Minor (delegator can absorb without re-review)

- `Sources/TerminalWindowPortal.swift:1065-1068` — `geom.external` is missing the `trigger` field the plan event table called for (`windowId, trigger, entryCount`). As shipped, the operator sees `windowNumber=… entryCount=…` but cannot tell from the log alone whether the event came from `NSWindow.didResize`, splitView resize, or `hostView.frame/boundsDidChange`. **Suggested fix:** thread a `trigger: String` argument into `synchronizeAllEntriesFromExternalGeometryChange()` and have each call site pass a literal (`"windowResize"`, `"splitViewResize"`, `"frameDidChange"`, `"boundsDidChange"`). If you want to land this without touching call signatures, an alternative is to log the event from each notification handler with its own trigger string before calling the function.

- `Sources/TerminalWindowPortal.swift:112-115` — `portalLogToken(_ id: ObjectIdentifier?)` returns `"0x" + hex(id.hashValue)`, while `portalLogToken(_ view: NSView?)` (lines 105-110) returns the real opaque pointer via `Unmanaged.passUnretained(view).toOpaque()`. Within a single ObjectIdentifier-namespace correlation (e.g., comparing `hostedId` across `bind.before` / `bind.after` / `sync.result`) this is fine and stable. But cross-namespace fields like `prevHostedIdForAnchor` (ObjectIdentifier hash) vs. `prevEntryHostedView` (NSView pointer) cannot be directly compared even when they refer to the same underlying hostedView. **Suggested fix:** make the two overloads produce comparable strings — easiest path is to render the `ObjectIdentifier` overload from the underlying object when the caller has access to it (i.e., resolve `ObjectIdentifier(view)` in callers instead of from raw `ObjectIdentifier`), or accept that `hostedId` and `*HostedView` will always be different formats and rename one of them to make the distinction explicit (e.g., `prevEntryHostedViewPtr=…`).

- `Sources/TerminalWindowPortal.swift:104` — doc comment on `portalLogToken(_ view:)` calls it a "Compact pointer token". The NSView overload is a pointer; the ObjectIdentifier overload (line 112) is a hash. The shared comment is technically attached to the NSView overload but reads as if it covers both. **Suggested fix:** add a one-line note on the ObjectIdentifier overload clarifying it returns a hashed handle, not the pointer.

### Nits / cosmetic

- The `bind.before` precompute block (`Sources/TerminalWindowPortal.swift:1507-1524`) wraps in `if C11PortalDebug.isEnabled { … }` to scope the temp `let`s. This is correct and clear. The other call sites rely on `portalLog`'s `@autoclosure` for the same zero-work guarantee. The asymmetry is justified (the temp `let`s need a block) but worth noting for future maintainers reading the file top-to-bottom.

- `Sources/TerminalWindowPortal.swift:1434, 1131` — the `let hadSuperview = …` and `let anchorWindowDesc = …` were moved out of `#if DEBUG` so `portalLog` can use them. Both are now computed unconditionally even in Release-with-gate-off. The cost is negligible (a couple of pointer comparisons in non-hot lifecycle paths), and the alternative (duplicating the computation under both `#if DEBUG` and `if C11PortalDebug.isEnabled`) would be uglier. Acceptable as-is.

- `scripts/repro-c11-18.sh:51` — `ITERATIONS="${1:-50}"` accepts the arg verbatim. A non-numeric arg makes the `for ((…))` arithmetic syntax fail with a confusing message. Trivial to harden with a regex check, but not worth a re-review.

- `scripts/repro-c11-18.sh:90-101` — picks the first workspace and first pane found. If the operator runs this against their primary workspace, they end up with `iterations × spawns-per-iter` extra terminals to clean up manually. The plan accepts this as the intended stress-test shape; a future iteration could add `--workspace` / `--pane` flags.

## Hot-path safety

Confirmed safe.

- `WindowTerminalHostView.hitTest()` at `Sources/TerminalWindowPortal.swift:244-310` and the other `hitTest` overrides at `:720` and `:2156` are unchanged. No `portalLog` call lands inside any `hitTest` body — verified by cross-referencing the `hitTest` line numbers against the eight `portalLog` emit sites (1065, 1148, 1443, 1468, 1514, 1626, 1724, 1754, 2024). No overlap.
- `Sources/GhosttyTerminalView.swift` is not touched; `TerminalSurface.forceRefresh()` is unchanged.
- `Sources/ContentView.swift` is not touched; `TabItemView` body and its `Equatable`/`.equatable()` contract are unchanged.

The `portalLog` helper itself is `@inline(__always)` with a single boolean check on the disabled path, and its `fields` parameter is `@autoclosure` so the per-call-site string formation, `portalLogToken` calls, and `portalLogFrame` calls are all skipped when the gate is off.

## Tests

The diagnostics-only no-tests stance is defensible per CLAUDE.md test policy.
The policy explicitly says: "If a behavior cannot be exercised end-to-end
yet, add a small runtime seam or harness first, then test through that seam.
If no meaningful behavioral or artifact-level test is practical, skip the
fake regression test and state that explicitly." This PR is exactly that
seam-and-harness step — `portalLog` is the seam, `repro-c11-18.sh` is the
harness — and the plan stated explicitly that "no behavioral test of the fix
is practical, since the diagnostics PR does not include a fix." Adding a
unit test that, e.g., asserts log lines are written when the env var is set
would only verify the logger itself, not the bug behavior, and would be the
kind of low-value mechanical test the policy discourages.

## Strengths

- **Plan compliance is precise.** Every lifecycle point the plan named has a
  call site; nothing extra was inserted. The Impl resisted the temptation to
  also instrument `synchronizeAllHostedViews` (the regular sync path), which
  would have been on-theme but out of scope.
- **`@autoclosure` on `fields` is the right call.** It guarantees that
  string formation, token rendering, and frame formatting are all skipped on
  the disabled path — not just the file write. The disabled-path cost is
  truly one boolean load.
- **Truncate-on-first-call is implemented exactly as the plan asked.** One
  repro run per `/tmp/c11-portal.log`, no unbounded growth across iterations.
- **Compat alias honored.** `CMUX_PORTAL_DEBUG` works alongside
  `C11_PORTAL_DEBUG`, matching the cmux→c11 naming feedback memory and the
  `CMUX_DEBUG_*` precedent.
- **Pattern fidelity to `logBackground`.** Same lock + sequence + ISO-8601 +
  uptime + thread + open/seek/write/close shape; no reinvention.
- **The repro script's `--help` is auto-extracted from its own header
  comments.** Won't drift from the docs that describe the script's
  behavior.
- **Operator-experience polish in the script.** Detects when
  `C11_PORTAL_DEBUG` isn't set in the launching shell and warns explicitly
  that the c11 process must be launched with the env var (since child
  commands cannot inject env vars into a running parent process). Plus a
  signal trap on SIGINT that reports the iteration index. Small touches that
  matter under stress.
- **CLAUDE.md entry is exactly 4 lines.** Per the project's lean-edit
  policy. Names what an operator needs (env var, compat alias, log path,
  override, repro script, attach-to-ticket guidance) without prose padding.
- **Existing `#if DEBUG dlog` paths preserved.** The two logging mechanisms
  coexist; `portalLog` complements rather than replaces, exactly as the
  commit message states.
