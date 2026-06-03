# C11-27 Plan — Split `c11Tests` target into pure-logic vs host-required

Ticket: [C11-27 — Split c11Tests target into pure-logic vs host-required](https://lattice.local/tasks/task_01KRQD33HPPS66DHVKANVA8KWJ).
Worktree: `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-27-test-split`, branch `feat/c11-27-test-split`, rebased onto `origin/main@7e0e0b282` (PR #164 merged).

This plan turns the ticket's five-step approach into a deterministic sequence the implementer can execute without re-deriving any decisions.

**Naming locked for this plan and all downstream work** (per plan-review §3, MINOR #4):
- Target name: **`c11LogicTests`** (no dash, matches existing `c11Tests` / `c11UITests`).
- Scheme name: **`c11-logic`** (dashed, matches existing `c11-unit` / `c11-ci`).
- Bundle ID: `com.stage11.c11.logictests`.

**Preconditions (satisfied — not gating)**
PR #164 merged into `origin/main@7e0e0b282` on 2026-05-15. Worktree is rebased. No further wait on #164.

**Problem framing correction (per plan-review §3, MINOR #8)**
Current `CLAUDE.md:128–135` claims `xcodebuild -scheme c11-unit` is "safe (no app launch), but prefer CI." In practice, on 2026-05-15, the operator force-quit the DEV.app twice while validating PR #164. The "safe" framing is the bug C11-27 fixes alongside the target split.

**Acceptance-bar reframe (per round-4 plan-review): the win is the absence of the frozen DEV.app, not raw seconds.**
The ticket's "<5 seconds" is a proxy for "doesn't beachball." The actual operator-visible win is *no `c11(.app| DEV.app)` process launches during a local `c11-logic test` run*. This plan therefore treats the **primary acceptance gate as the no-app-launch invariant** (verified by the monitored pgrep loop in §2.2 and reflected in §8). Timing is a secondary, measured target — a soft criterion to be reported, not a hard pass/fail. The single timing number that appears in every section: **test phase ~5–10 s, total wall time ~30 s, hard regression budget = noise floor**. The deviation from the ticket's "<5 seconds" is flagged in the PR description for Atin to confirm at review time (see §8).

**Plan-review gotcha — always pass `--headless` (per round-4 delegator interrupt)**

`lattice plan-review C11-27 --actor agent:c11-27-plan-reviewer` (no `--headless`) spawns a `plan-review-...` workspace **and** a `merge-...` workspace in c11. Running plan-review multiple times during iteration accumulated 10 stray workspaces on 2026-05-16 before the operator flagged it. **Every** `lattice plan-review` invocation in this ticket's lifecycle must include `--headless`:

```bash
(cd /Users/atin/Projects/Stage11/code/c11 && \
  lattice plan-review C11-27 --headless --actor agent:c11-27-plan-reviewer)
```

This applies to the implementer's iteration too — any time CI changes need re-review against the plan, `--headless` is mandatory. The flag is documented in `lattice plan-review --help` ("Force the headless spawn backend (subprocess.run; no panes/windows)").

---

**Local-test exception for C11-27 (one-time, narrow)**
The repo's standing policy "never run tests locally" exists because hosted schemes (`c11-unit`, `c11-ci`) launch DEV.app and freeze it. The whole point of C11-27 is to validate `c11-logic` does NOT launch the app. The spike (§2.2) and acceptance gate (§8) therefore require running `xcodebuild test -scheme c11-logic` locally, exactly once per spike attempt, under the monitored pgrep harness in §2.2.

**Authorized scope of this exception:**
- ✅ `xcodebuild test -scheme c11-logic ...` under the §2.2 monitored harness, **only on a clean build** (`xcodebuild clean` first), **only with the §2.2 pgrep preflight passing**.
- ❌ Local `xcodebuild test -scheme c11-unit` — still forbidden.
- ❌ Local `xcodebuild test -scheme c11-ci` — still forbidden.
- ❌ Running `c11-logic test` from inside Xcode's UI — uses different code paths than CLI; not in scope.

CLAUDE.md update (§5) and this exception land in the **same commit** as the scheme creation so the policy and the implementation can't drift.

---

## 1. Per-file PURE/HOST verdict (grep audit)

Audit classifier counts grep hits for:
`^import (AppKit|SwiftUI|WebKit) | NSWindow | NSView | NSApp | MTLCreateSystemDefaultDevice | MTKView | WKWebView | CALayer | NSResponder | NSEvent`.

Re-audited each HOST file with ≤2 hits via direct read of the body. The first review pass treated bare `import AppKit` as cosmetic; closer inspection found that **six of the seven original "PROMOTE candidates" actually use NSColor APIs that the grep missed** (chained calls like `color.usingColorSpace(.sRGB).redComponent`, NSColor return types from `snapshot.resolveColor`, NSColor extensions like `.hexString(includeAlpha:)`, and NSColor literals like `.red` via leading-dot syntax on an inferred NSColor parameter). Only **`TerminalControllerSocketSecurityTests`** survives as a genuine VERIFY-PROMOTE candidate.

**The compiler is the audit.** Grep is fast triage; compile success under the chosen linkage strategy is authoritative. See §1.5 for the methodology and §6 for the risk-register entry on classification errors.

**Verdict legend:**
- `PURE` → bulk-move to `c11LogicTests`.
- `HOST` → keep in `c11Tests`.
- `VERIFY-PROMOTE` → implementer drops `import AppKit`, attempts compile under the chosen strategy, keeps PURE if it compiles, demotes to HOST if it fails. There is exactly one of these.

| File | grep hits | Symbols hit | Verdict | Notes |
|---|---:|---|---|---|
| AgentRestartRegistryTests.swift | 0 | — | PURE | clean |
| AppDelegateShortcutRoutingTests.swift | 61 | NSApp, NSEvent, NSWindow, NSResponder, AppKit, SwiftUI | HOST | drives shortcut routing through AppKit |
| BrowserChromeSnapshotTests.swift | 0 | — | PURE | clean |
| BrowserConfigTests.swift | 94 | AppKit, SwiftUI, WebKit, WKWebView | HOST | WebKit config |
| BrowserFindJavaScriptTests.swift | 0 | — | PURE | clean |
| BrowserImportMappingTests.swift | 0 | — | PURE | clean |
| BrowserPanelTests.swift | 163 | AppKit, SwiftUI, WebKit, WKWebView, NSView | HOST | heaviest host file |
| C11ThemeLoaderTests.swift | 0 | — | PURE | clean |
| ChromeScaleObserverTests.swift | 0 | — | PURE | clean |
| ChromeScaleSettingsTests.swift | 0 | — | PURE | clean |
| ChromeScaleTokensTests.swift | 0 | — | PURE | clean |
| CJKIMEInputTests.swift | 86 | AppKit, NSEvent, NSResponder, NSView | HOST | IME event routing |
| CLIAdvisoryConnectivityTests.swift | 0 | — | PURE | clean |
| CLIHealthRuntimeTests.swift | 0 | — | PURE | clean |
| CLIResolutionSnapshotTests.swift | 0 | — | PURE | clean |
| CommandPaletteSearchEngineTests.swift | 0 | — | PURE | clean |
| DefaultGridSettingsTests.swift | 0 | — | PURE | clean |
| DescriptionSanitizerTests.swift | 0 | — | PURE | clean |
| FlashColorParsingTests.swift | 1 | `import AppKit`; body calls `color.usingColorSpace(.sRGB).redComponent / greenComponent / blueComponent / alphaComponent` and `FlashAppearance.parseHex(...)` returns `NSColor?` | HOST | grep was misleading. NSColor APIs used throughout (lines 16–68). |
| GhosttyConfigTests.swift | 15 | NSView, NSWindow, AppKit | HOST | exercises ghostty view config |
| GhosttyEnsureFocusWindowActivationTests.swift | 6 | NSWindow ×5, AppKit | HOST | instantiates NSWindow |
| HealthFlagsTests.swift | 0 | — | PURE | clean |
| HealthIPSParserTests.swift | 0 | — | PURE | clean |
| HealthMetricKitParserTests.swift | 0 | — | PURE | clean |
| HealthSentinelParserTests.swift | 0 | — | PURE | clean |
| HealthSentryParserTests.swift | 0 | — | PURE | clean |
| LegacyPrefsMigrationGateTests.swift | 0 | — | PURE | clean |
| MailboxDispatcherGCTests.swift | 0 | — | PURE | clean |
| MailboxDispatcherTests.swift | 0 | — | PURE | clean |
| MailboxDispatchLogTests.swift | 0 | — | PURE | clean |
| MailboxEnvelopeValidationTests.swift | 0 | — | PURE | clean |
| MailboxIOTests.swift | 0 | — | PURE | clean |
| MailboxLayoutTests.swift | 0 | — | PURE | clean |
| MailboxOutboxWatcherTests.swift | 0 | — | PURE | clean |
| MailboxSurfaceResolverTests.swift | 0 | — | PURE | clean |
| MailboxULIDTests.swift | 0 | — | PURE | clean |
| MetadataPersistencePrecedenceTests.swift | 0 | — | PURE | clean |
| MetadataPersistenceRoundTripTests.swift | 0 | — | PURE | clean |
| MetadataPersistenceUncoercibleTests.swift | 0 | — | PURE | clean |
| MetadataStoreRevisionCounterTests.swift | 0 | — | PURE | clean |
| NotificationAndMenuBarTests.swift | 7 | AppKit, SwiftUI, NSApp, NSWindow | HOST | NSApp activation paths |
| OmnibarAndToolsTests.swift | 3 | AppKit, SwiftUI, WebKit | HOST | imports trio |
| PaneInteractionRuntimeTests.swift | 0 | — | PURE | clean |
| PanelIdentityRestoreTests.swift | 0 | — | PURE | clean |
| PaneMetadataPersistenceTests.swift | 0 | — | PURE | clean |
| PaneMetadataStoreTests.swift | 0 | — | PURE | clean |
| ResolverCacheKeyTests.swift | 1 | `import AppKit`; body calls `snapshot.resolveColor(...)` which returns `NSColor?` and uses `===` identity on the resulting NSColors | HOST | NSColor return type bleeds through `@testable import c11` and the call site needs AppKit in scope. |
| SessionEndShutdownPolicyTests.swift | 0 | — | PURE | clean |
| SessionPersistenceTests.swift | 0 | — | PURE | clean |
| ShortcutAndCommandPaletteTests.swift | 3 | AppKit, SwiftUI, WebKit | HOST | imports trio |
| SidebarOrderingTests.swift | 3 | AppKit, SwiftUI, WebKit | HOST | imports trio |
| SidebarSnapshotTests.swift | 1 | `import AppKit`; body uses `base.withAlphaComponent(...)` (NSColor API) and `snapshot.resolveColor(...)` returning NSColor (lines 65–89) | HOST | NSColor mutators used directly. |
| SidebarWidthPolicyTests.swift | 0 | — | PURE | clean |
| SocketControlPasswordStoreTests.swift | 0 | — | PURE | clean |
| StatusBarButtonDisplayTests.swift | 0 | — | PURE | clean |
| StatusEntryPersistenceTests.swift | 0 | — | PURE | clean |
| StdinHandlerFormattingTests.swift | 0 | — | PURE | clean |
| SurfaceLifecycleTests.swift | 4 | WebKit, WKWebView (string + comment), `import WebKit` | HOST | actually mocks WKWebView load semantics. |
| SurfaceMetadataStoreValidationTests.swift | 0 | — | PURE | clean |
| SurfaceTitleBarRenderTests.swift | 3 | AppKit, SwiftUI, `NSView.noIntrinsicMetric` | HOST | uses NSView API |
| TabManagerSessionSnapshotTests.swift | 0 | — | PURE | clean |
| TabManagerUnitTests.swift | 3 | AppKit, SwiftUI, WebKit | HOST | imports trio |
| TCCPrimerTests.swift | 0 | — | PURE | clean |
| TerminalAndGhosttyTests.swift | 103 | AppKit, SwiftUI, NSView, NSWindow | HOST | terminal view machinery |
| TerminalControllerSocketSecurityTests.swift | 1 | `import AppKit`; body uses `XCTNSPredicateExpectation` (XCTest) + `NSPredicate` (Foundation) — neither requires AppKit | **VERIFY-PROMOTE** | the only candidate left after re-audit. Drop `import AppKit`, attempt compile under the chosen strategy; demote to HOST if it fails. |
| TerminalControllerTelemetryWorkerTests.swift | 0 | — | PURE | clean |
| TextBoxInputTests.swift | 15 | AppKit, NSEvent, NSView, NSResponder | HOST | text-input event routing |
| ThemeCycleAndInvalidValueTests.swift | 0 | — | PURE | clean |
| ThemedValueEvaluatorTests.swift | 1 | `import AppKit`; **body uses `NSColor` extensively** | HOST | real AppKit dependency despite single-hit grep. |
| ThemedValueParserTests.swift | 0 | — | PURE | clean |
| ThemeManagerLifecycleTests.swift | 1 | `import AppKit`; body resolves to `NSColor?` | HOST | real AppKit dependency. |
| ThemeRegistryTests.swift | 0 | — | PURE | clean |
| ThemeResolvedSnapshotArtifactTests.swift | 1 | `import AppKit`; body uses `color.alphaComponent` and `color.hexString(includeAlpha: ...)` (NSColor extension on the c11 module) — line 23 | HOST | NSColor property + extension. |
| ThemeResolverBenchmarks.swift | 1 | `import AppKit`; body calls `snapshot.resolveColor(...)` 200,000+ times — the discarded NSColor? return type still requires AppKit at the call site | HOST | NSColor in return type signature. |
| TitlebarSnapshotTests.swift | 0 | — | PURE | clean |
| TomlSubsetParserFuzzTests.swift | 0 | — | PURE | clean |
| TomlSubsetParserTests.swift | 0 | — | PURE | clean |
| UpdatePillReleaseVisibilityTests.swift | 3 | AppKit, `NSSize` constructors throughout | HOST | NSSize is AppKit on macOS. |
| WindowAndDragTests.swift | 81 | NSWindow, AppKit, NSEvent | HOST | window drag machinery |
| WorkspaceApplyChromeScaleTests.swift | 0 | — | PURE | clean |
| WorkspaceApplyPlanCodableTests.swift | 0 | — | PURE | clean |
| WorkspaceBlueprintFileCodableTests.swift | 0 | — | PURE | clean |
| WorkspaceBlueprintMarkdownTests.swift | 0 | — | PURE | clean |
| WorkspaceBlueprintStoreTests.swift | 0 | — | PURE | clean |
| WorkspaceContentViewVisibilityTests.swift | 0 | — | PURE | clean |
| WorkspaceFlashTests.swift | 2 | `import AppKit`; body constructs `FlashAppearance(color: .red, ...)` where `.red` is `NSColor.red` (FlashAppearance.color is typed `NSColor`) | HOST | NSColor literal usage at the call site. |
| WorkspaceIdentityRestoreTests.swift | 0 | — | PURE | clean |
| WorkspaceLayoutExecutorAcceptanceTests.swift | 0 | — | PURE | clean |
| WorkspaceManualUnreadTests.swift | 3 | AppKit, `makeWindow() -> NSWindow` helper | HOST | real NSWindow construction. |
| WorkspaceMetadataValidatorTests.swift | 0 | — | PURE | clean |
| WorkspacePullRequestSidebarTests.swift | 0 | — | PURE | clean |
| WorkspaceRemoteConnectionTests.swift | 0 | — | PURE | clean |
| WorkspaceRestartCommandsTests.swift | 0 | — | PURE | clean |
| WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift | 0 | — | PURE | clean |
| WorkspaceSnapshotCaptureTests.swift | 0 | — | PURE | clean |
| WorkspaceSnapshotConverterTests.swift | 0 | — | PURE | clean |
| WorkspaceSnapshotRoundTripAcceptanceTests.swift | 0 | — | PURE | clean |
| WorkspaceSnapshotSetCodableTests.swift | 0 | — | PURE | clean |
| WorkspaceSnapshotStoreSecurityTests.swift | 0 | — | PURE | clean |
| WorkspaceStressProfileTests.swift | 0 | — | PURE | clean |
| WorkspaceUnitTests.swift | 12 | AppKit, NSWindow, NSView | HOST | window/view fixtures |

**Tally:** 73 PURE + 1 VERIFY-PROMOTE + 27 HOST = 101 files.

**Expected size of `c11LogicTests`:** 73 outright + 1 if VERIFY-PROMOTE passes = **73 or 74 files**. The remaining 27 stay in `c11Tests`.

---

## 1.5. Second-stage transitive-dependency audit (REQUIRED before pbxproj surgery)

Per plan-review §3 MAJOR #4: **grep classification is insufficient to prove a test is hostless.** A test with zero direct AppKit hits can still call into c11 source files that themselves import AppKit, depend on `@MainActor`, or touch app singletons. Strategy A (dual-compile) requires those source files to land in `c11LogicTests`; if they pull AppKit transitively, the new target won't link.

**Methodology** — the implementer commits two scripts to the PR so the audit is reproducible and reviewers can re-run:

1. **`scripts/c11-27-audit.sh`** — regenerates `/tmp/c11-27-audit.txt` (the §1 classifier output). Committed so the §1 table and `c11-27-audit.txt` cannot drift:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   for f in c11Tests/*.swift; do
     impacts=$(grep -cE "^import (AppKit|SwiftUI|WebKit)|NSWindow\b|NSView\b|NSApp\b|MTLCreateSystemDefaultDevice|MTKView|WKWebView|CALayer|NSResponder\b|NSEvent\b" "$f" 2>/dev/null)
     if [ "$impacts" -gt 0 ]; then echo "HOST $impacts $f"; else echo "PURE 0 $f"; fi
   done | sort > /tmp/c11-27-audit.txt
   wc -l /tmp/c11-27-audit.txt
   ```

2. **`scripts/c11-27-deps.sh`** — runs the type-reference audit. Reads `/tmp/c11-27-audit.txt` from script 1; writes `/tmp/c11-27-deps.txt`. Committed:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   : > /tmp/c11-27-deps.txt
   # Audit only files that have a chance of going to c11LogicTests: PURE (0 hits) + the single VERIFY-PROMOTE.
   while read -r verdict _ path; do
     [ "$verdict" = "PURE" ] || [ "$path" = "c11Tests/TerminalControllerSocketSecurityTests.swift" ] || continue
     base=$(basename "$path" .swift)
     # PascalCase identifiers in the test body (rough type-reference proxy).
     # Strip XCT/NS/Self/Test/primitive/Foundation built-ins; what remains is the c11 type surface.
     grep -hoE '\b[A-Z][A-Za-z0-9_]+\b' "$path" | sort -u \
       | grep -vE '^(XCT|NS[A-Z]|Self|Test|Bool|Int|Double|UInt|Float|String|Data|Date|UUID|URL|Array|Dictionary|Set|Result|Optional|Error|Range|Comparable|Hashable|Equatable|Codable|Sendable|Decodable|Encodable|Any|Void|Never|Character|Substring|Foundation|Swift|Combine|Dispatch|OS|Logger)' \
       | while read -r t; do
         decl=$(grep -lE "^(public |internal |fileprivate |private )?(final )?(class|struct|enum|actor|protocol|typealias) +$t\b" Sources/**/*.swift 2>/dev/null | head -1)
         [ -n "$decl" ] && echo "$base  $t  $decl" >> /tmp/c11-27-deps.txt
       done
   done < /tmp/c11-27-audit.txt
   sort -u -o /tmp/c11-27-deps.txt /tmp/c11-27-deps.txt
   wc -l /tmp/c11-27-deps.txt
   ```

Output is a `(test_file, type, sources_file)` triple per row. The implementer then:

1. **Builds the union set of `sources_file` values.** That's the candidate dual-compile inclusion list for `c11LogicTests` under Strategy A.
2. **Greps each source file for `^import (AppKit|SwiftUI|WebKit)` or AppKit symbols.** Source files that import any of these are **not logic-eligible**.
3. **Source files that import AppKit transitively become decision points:**
   - **Try protocol-extract:** if the AppKit dependency is a single capability (e.g., `NSColor` for color blending), see whether the implementer can split the file: the pure logic moves to `XColor.swift` (no AppKit), the AppKit-binding stays in `XColor+AppKit.swift`. This is a real production refactor and may be out of scope for C11-27; if so, see (4).
   - **If protocol-extract is invasive:** demote the dependent test(s) from PURE/PROMOTE to HOST. They stay in `c11Tests`. The pure target loses coverage of those types — that's the cost of staying in scope.
4. **Never add `import AppKit` to a pure test to make it compile.** That defeats the purpose of the split.

**Pinning the artifacts — two files (disambiguated):**

- `.lattice/plans/c11-27-deps.txt` — raw audit triples in `test_file  type  sources_file` form, sorted. **Reviewer evidence** only; the Ruby script does NOT read this directly.
- `.lattice/plans/c11-27-sources.txt` — de-duplicated list of Sources/ paths to compile into `c11LogicTests` under Strategy A, one path per line. **Script input.** Derived from the triples file:

  ```bash
  awk '{print $3}' .lattice/plans/c11-27-deps.txt | sort -u > .lattice/plans/c11-27-sources.txt
  ```

Both files committed to the PR. The two-file split prevents the silent parse-mismatch trap of reusing one filename for two different shapes.

**Strategy B (Fallback) does not need this audit** — when `@testable import c11` is used, the c11 module is built once for the c11 app and the test target imports its swiftmodule; transitive dependencies stay quarantined inside c11.app. The audit is only mandatory under Strategy A.

---

## 2. New target shape + linkage strategy

**Type:** `com.apple.product-type.bundle.unit-test`.

**Host application:** none. Schema: no `TEST_HOST` key set.

### 2.1 Linkage strategy — three-tier decision tree

The plan-review's central finding: the linkage approach was unresolved. It is resolved here.

**Strategy A — Primary (recommended): dual-compile.**
- `c11LogicTests` compiles its own copy of the production Sources/ files identified by the §1.5 audit.
- Test files have their existing `@testable import c11` / `@testable import c11_DEV` line **removed** (the production types are now in the same module as the tests).
- Build settings: `TEST_HOST` unset, `BUNDLE_LOADER` unset. The bundle is fully self-contained.
- No dependency on the `c11` app target needed at link time (compile-order dependency is also unnecessary).
- Pros: cleanest, most portable, doesn't depend on Xcode quirks; bundle runs in pure `xctest` with zero AppKit.
- Cons: requires the §1.5 audit; PR diff includes editing `@testable import` lines in ~80 test files; coverage of types whose Sources files transitively import AppKit is sacrificed (those tests demoted to HOST).

**Strategy B — Fallback: `BUNDLE_LOADER` without `TEST_HOST`.**
- `c11LogicTests` keeps existing `@testable import c11` / `@testable import c11_DEV` in test files unchanged.
- Build settings: `TEST_HOST` unset, `BUNDLE_LOADER = "$(BUILT_PRODUCTS_DIR)/c11.app/Contents/MacOS/c11"`.
- Dependency: `c11` target (so the app builds first; xctest dlopens its binary at runtime for symbol resolution).
- Module-import shape: `@testable import c11` resolves at compile time via c11's swiftmodule (`ENABLE_TESTABILITY = YES` inherited project-wide).
- Pros: zero edits to existing test files; production code unchanged.
- Cons: Xcode-version-dependent — needs verification that xctest does **not** launch `c11.app` just because `BUNDLE_LOADER` points at it. This is the explicit spike target in §2.2.

**Strategy C — Escalation, out of scope for C11-27: extract `c11Core`.**
- Refactor the c11 module: split into `c11Core` (a SwiftPM library) and `c11` (the app target depending on `c11Core`).
- Both `c11Tests` and `c11LogicTests` `@testable import c11Core`.
- Defer to a follow-up ticket per the original C11-27 "Out of scope" section. Trigger this only if A and B both fail.

### 2.2 Spike protocol (run before bulk pbxproj surgery)

**Goal:** prove the chosen Strategy works on two representative tests before touching the other ~78.

**Spike candidates** — chosen to exercise both the easy path and the *actual* failure mode (transitive AppKit pressure on Theme/Workspace code paths):

- `MailboxIOTests.swift` — file I/O, no AppKit deps. Easy path.
- `StdinHandlerFormattingTests.swift` — CLI runtime, no AppKit deps. Easy path, and in the `mailbox-parity.yml` `-only-testing` set.
- `ThemeRegistryTests.swift` — exercises `ThemeRole` / `ColorExpression`. Theme cluster touches NSColor transitively in production sources; if Strategy B's `BUNDLE_LOADER` resolves these symbols and Strategy A's dual-compile pulls in AppKit-importing Sources, the spike surfaces the problem here, not at bulk-move time.
- `WorkspaceSnapshotConverterTests.swift` — Workspace snapshot converter. Heavier subsystem, no direct AppKit in the test but `Workspace.swift` itself imports AppKit transitively.

A green spike across all four means Strategy B (or A) actually handles transitive AppKit, not just AppKit-free subsystems.

**Spike order:**

1. **Try Strategy B first** (cheaper: no production edits, no `@testable` removal).
   - Create `c11LogicTests` target with the build settings in §2.3 Strategy-B column (per-config BUNDLE_LOADER: `c11 DEV.app` for Debug, `c11.app` for Release).
   - Create `c11-logic.xcscheme` at the same time (see §3 step 7 spec) so the spike can use `-scheme c11-logic`. Under Strategy B the scheme's BuildAction includes both `c11` and `c11LogicTests` so the host binary exists for `BUNDLE_LOADER` to point at.
   - Move all four spike files' membership.
   - Build: `xcodebuild clean build -scheme c11-logic -configuration Debug -destination "platform=macOS"`. The clean is required so the acceptance gate (`pgrep`) is authoritative — no stale `c11 DEV.app` from a prior build.
   - **Spike acceptance gate** — monitor during the test phase, not before. The operator runs `c11` daily from `/Applications/c11.app/...` and frequently has tagged debug builds open in parallel; the pgrep pattern must match **only test-spawned hosts** under DerivedData and exclude every legitimate c11 process on the workstation. Scoping the pattern to the DerivedData Build/Products path satisfies both conditions:

     ```bash
     # PID-snapshot approach: durable against any future operator-run process paths we didn't anticipate.
     # Snapshot every c11* process PID at preflight; treat any NEW PID matching c11 during the test phase as failure.
     #
     # Pattern scoped to DerivedData/.../Build/Products/(Debug|Release)/... so the operator's
     # daily-driver /Applications/c11.app and any tagged Resources/Debug/c11 builds are excluded.
     SPIKE_PATTERN='DerivedData/[^ ]+/Build/Products/(Debug|Release)/c11( DEV)?\.app/Contents/MacOS/c11'

     # Preflight: snapshot what's already running (operator's daily-driver, tagged builds, etc.).
     pgrep -fl "$SPIKE_PATTERN" 2>/dev/null | awk '{print $1}' | sort -u > /tmp/c11-27-spike-preflight-pids.txt
     echo "preflight test-host PIDs (should be empty unless a stale test run): $(wc -l < /tmp/c11-27-spike-preflight-pids.txt)"
     [ ! -s /tmp/c11-27-spike-preflight-pids.txt ] || { echo 'FAIL: preexisting test-host process under DerivedData; xcodebuild clean and retry'; exit 1; }

     # Background the test run; sample pgrep on a tight loop during the run.
     # Pattern uses ERE (Darwin `pgrep -f` defaults to ERE); covers both `c11 DEV.app` (Debug) and `c11.app` (Release).
     # Log uses append (>>) with timestamps so late launches aren't clobbered.
     : > /tmp/c11-27-spike-launches.log  # truncate once at start
     xcodebuild test -scheme c11-logic -configuration Debug -destination "platform=macOS" \
       -only-testing:c11LogicTests/MailboxIOTests \
       -only-testing:c11LogicTests/StdinHandlerFormattingTests \
       -only-testing:c11LogicTests/ThemeRegistryTests \
       -only-testing:c11LogicTests/WorkspaceSnapshotConverterTests \
       > /tmp/c11-27-spike-b.log 2>&1 &
     XB_PID=$!
     while kill -0 "$XB_PID" 2>/dev/null; do
       hits=$(pgrep -fl "$SPIKE_PATTERN" 2>/dev/null) || true
       if [ -n "$hits" ]; then
         printf '%s %s\n' "$(date -Iseconds)" "$hits" >> /tmp/c11-27-spike-launches.log
         echo 'FAIL: c11 test-host process launched in DerivedData during c11-logic test phase'
         kill "$XB_PID"; exit 1
       fi
       sleep 0.25
     done
     wait "$XB_PID"
     ```
     **Sanity-check the regex before locking in:** run `pgrep -fl "$SPIKE_PATTERN"` once on the operator's live workstation; it should return **empty** even with the daily-driver c11 running and any number of tagged debug builds open. If it matches anything, refine the pattern until it doesn't.

     Both conditions must hold: no test-spawned `c11*` process during the run AND all four tests pass (exit 0).
   - If pass: lock in Strategy B for the bulk move. Skip Strategy A.
   - If fail (the app launches OR symbols don't resolve): proceed to step 2.

2. **Strategy A spike + scope check.**
   - Run the §1.5 dependency audit limited to the four spike files. Inclusion list spans Mailbox / CLIRuntime / Theme / Workspace subsystems.
   - Greb each candidate Sources/ file for `^import (AppKit|SwiftUI|WebKit)`. **Expect the Theme and Workspace clusters to fail this check** (NSColor lives in Theme; Workspace.swift imports AppKit per Sources/Workspace.swift line 1).
   - For each AppKit-importing source file: try the protocol-extract split per §1.5; if invasive, demote the dependent test to HOST. Track running count.
   - **Strategy A floor: ~50 tests** (derived: the ticket's 73 PURE × ~70 % survival rate after a typical Theme/Workspace transitive-AppKit demotion pass). If after demotions the c11LogicTests file count is below ~50, the production refactor cost exceeds the local-loop benefit; pause and surface to Atin via a Lattice comment on C11-27 before escalating to Strategy C (re-open ticket, expand scope to extract a `c11Core` SwiftPM library). The floor is an inflection-point trigger for human judgment, not a hard cutoff — but **do not silently lower it without escalation**.
   - Recreate `c11LogicTests` with Strategy-A build settings (no `BUNDLE_LOADER`, no `TEST_HOST`).
   - Edit the spike test files: remove `@testable import c11` / `@testable import c11_DEV` lines.
   - Add the source files to the test target's Sources phase.
   - Build + run + monitor `pgrep` as in step 1.
   - **Acceptance gate:** same as step 1, all four spike tests pass, no `c11(.app| DEV.app)` process during the run.
   - If pass and floor ≥ 50: lock in Strategy A for bulk.
   - If fail: escalate to Strategy C (out of scope; re-open ticket).

3. **Commit the spike as a separate first commit** so the PR review can read it independently of the bulk move.

### 2.3 Build settings — final spec

| Key | Strategy A value | Strategy B value | Notes |
|---|---|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.stage11.c11.logictests` | same | distinct from `com.stage11.c11.apptests` |
| `PRODUCT_NAME` | `$(TARGET_NAME)` | same | |
| `MACOSX_DEPLOYMENT_TARGET` | `14.0` | same | matches c11Tests |
| `SWIFT_VERSION` | `5.0` | same | |
| `CURRENT_PROJECT_VERSION` | `101` | same | matches c11 |
| `MARKETING_VERSION` | `0.47.1` | same | matches c11 |
| `GENERATE_INFOPLIST_FILE` | `YES` | same | |
| `CODE_SIGN_STYLE` | `Automatic` | same | |
| `ONLY_ACTIVE_ARCH` (Debug) | `YES` | same | |
| `ONLY_ACTIVE_ARCH` (Release) | `NO` | same | |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (Debug) | `"DEBUG $(inherited)"` | same | |
| `TEST_HOST` | **unset / empty** | **unset / empty** | the load-bearing difference vs. c11Tests |
| `BUNDLE_LOADER` (Debug) | **empty** (`= ''`, not `$(TEST_HOST)`) | `"$(BUILT_PRODUCTS_DIR)/c11 DEV.app/Contents/MacOS/c11"` | Debug builds produce `c11 DEV.app` (`PRODUCT_NAME = "c11 DEV"`). |
| `BUNDLE_LOADER` (Release) | **empty** (`= ''`) | `"$(BUILT_PRODUCTS_DIR)/c11.app/Contents/MacOS/c11"` | Release path. |

**Convention divergence note (round-4 plan-review):** the existing `c11Tests` target uses the indirect form `BUNDLE_LOADER = "$(TEST_HOST)"`. With `TEST_HOST = ''` by design in the new target, the indirect form would resolve to empty — which is what Strategy A wants, but Strategy B needs the explicit absolute path so the linker has a real binary to two-level-namespace against. So the new target uses the explicit form in both strategies (empty literal under A, absolute path under B). Existing `c11Tests` lines 1716/1734 of `project.pbxproj` are the reference for the per-config paths.
| `TEST_TARGET_NAME` | **unset** | **unset** | omit in both |
| Target dependency | (none) | `c11` | Strategy A is fully standalone |

### 2.4 Source membership policy: MOVE, don't duplicate

For PURE / PROMOTE test files: target membership **moves** from `c11Tests` to `c11LogicTests` (one home per file).

- Single source of truth for which target owns a file.
- Avoids divergent behavior if a test mutates global state and would run twice in `c11-unit`.
- The `c11-unit` and `c11-ci` schemes keep running both targets sequentially, so coverage from a single CLI invocation is preserved.

For the **one** VERIFY-PROMOTE file (`TerminalControllerSocketSecurityTests.swift`): drop the `import AppKit` line **before** moving membership. Verify with `xcodebuild build -scheme c11-unit` — if it fails to compile after the import drop, revert the edit and leave the file in `c11Tests`. The §3 script gates inclusion on `INCLUDE_VERIFY_PROMOTE=1`, set only when the compile verification passed.

---

## 3. pbxproj surgery — Ruby `xcodeproj` gem (no alternatives)

**Tool committed:** Ruby [`xcodeproj` gem](https://github.com/CocoaPods/Xcodeproj). Already installed on this workstation (`gem list -i xcodeproj` → `true`). System Ruby `/usr/bin/ruby 2.6.10p210`, gem `3.0.3.1`.

**Caveat (round-4 plan-review):** macOS-shipped Ruby 2.6.10 has been EOL since March 2022 and Apple may drop it on a future macOS release. The script pins gem version `~> 1.27` to insulate against future major bumps:

```ruby
gem 'xcodeproj', '~> 1.27'
require 'xcodeproj'
```

If the workstation lacks Ruby (macOS 26+ may), the implementer installs Ruby via `brew install ruby` and prepends `/opt/homebrew/opt/ruby/bin` to PATH before running the script. **Not urgent enough to block C11-27**, but a re-do candidate when macOS drops system Ruby — track in a follow-up.

Clean machine install (current macOS): `gem install --user-install 'xcodeproj:~>1.27'`.

**Never hand-edit `GhosttyTabs.xcodeproj/project.pbxproj`. Never `sed`. Both are prohibited by the ticket.**

**Script location:** `scripts/c11-27-split-tests.rb`, checked into the PR so the operation is reversible and re-runnable.

**Script flow** — selectable via `STRATEGY=A` or `STRATEGY=B` env var (default `B`, the spike result decides):

```ruby
#!/usr/bin/env ruby
gem 'xcodeproj', '~> 1.27'
require 'xcodeproj'

STRATEGY = ENV.fetch('STRATEGY', 'B')
abort "STRATEGY must be A or B" unless %w[A B].include?(STRATEGY)

PROJECT_PATH = File.expand_path('../GhosttyTabs.xcodeproj', __dir__)
project = Xcodeproj::Project.open(PROJECT_PATH)

c11_app        = project.targets.find { |t| t.name == 'c11' }      or abort 'c11 not found'
existing_tests = project.targets.find { |t| t.name == 'c11Tests' } or abort 'c11Tests not found'
tests_group    = project.main_group.find_subpath('c11Tests', false) or abort 'c11Tests group not found'

# PURE files (zero grep hits in §1).
PURE_FILES = %w[
  AgentRestartRegistryTests.swift BrowserChromeSnapshotTests.swift
  BrowserFindJavaScriptTests.swift BrowserImportMappingTests.swift
  C11ThemeLoaderTests.swift ChromeScaleObserverTests.swift
  ChromeScaleSettingsTests.swift ChromeScaleTokensTests.swift
  CLIAdvisoryConnectivityTests.swift CLIHealthRuntimeTests.swift
  CLIResolutionSnapshotTests.swift CommandPaletteSearchEngineTests.swift
  DefaultGridSettingsTests.swift DescriptionSanitizerTests.swift
  HealthFlagsTests.swift HealthIPSParserTests.swift
  HealthMetricKitParserTests.swift HealthSentinelParserTests.swift
  HealthSentryParserTests.swift LegacyPrefsMigrationGateTests.swift
  MailboxDispatcherGCTests.swift MailboxDispatcherTests.swift
  MailboxDispatchLogTests.swift MailboxEnvelopeValidationTests.swift
  MailboxIOTests.swift MailboxLayoutTests.swift
  MailboxOutboxWatcherTests.swift MailboxSurfaceResolverTests.swift
  MailboxULIDTests.swift MetadataPersistencePrecedenceTests.swift
  MetadataPersistenceRoundTripTests.swift MetadataPersistenceUncoercibleTests.swift
  MetadataStoreRevisionCounterTests.swift PaneInteractionRuntimeTests.swift
  PanelIdentityRestoreTests.swift PaneMetadataPersistenceTests.swift
  PaneMetadataStoreTests.swift SessionEndShutdownPolicyTests.swift
  SessionPersistenceTests.swift SidebarWidthPolicyTests.swift
  SocketControlPasswordStoreTests.swift StatusBarButtonDisplayTests.swift
  StatusEntryPersistenceTests.swift StdinHandlerFormattingTests.swift
  SurfaceMetadataStoreValidationTests.swift TabManagerSessionSnapshotTests.swift
  TCCPrimerTests.swift TerminalControllerTelemetryWorkerTests.swift
  ThemeCycleAndInvalidValueTests.swift ThemedValueParserTests.swift
  ThemeRegistryTests.swift TitlebarSnapshotTests.swift
  TomlSubsetParserFuzzTests.swift TomlSubsetParserTests.swift
  WorkspaceApplyChromeScaleTests.swift WorkspaceApplyPlanCodableTests.swift
  WorkspaceBlueprintFileCodableTests.swift WorkspaceBlueprintMarkdownTests.swift
  WorkspaceBlueprintStoreTests.swift WorkspaceContentViewVisibilityTests.swift
  WorkspaceIdentityRestoreTests.swift WorkspaceLayoutExecutorAcceptanceTests.swift
  WorkspaceMetadataValidatorTests.swift WorkspacePullRequestSidebarTests.swift
  WorkspaceRemoteConnectionTests.swift WorkspaceRestartCommandsTests.swift
  WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift
  WorkspaceSnapshotCaptureTests.swift WorkspaceSnapshotConverterTests.swift
  WorkspaceSnapshotRoundTripAcceptanceTests.swift WorkspaceSnapshotSetCodableTests.swift
  WorkspaceSnapshotStoreSecurityTests.swift WorkspaceStressProfileTests.swift
].freeze

# VERIFY-PROMOTE: drop `import AppKit` first (separate commit), then move with PURE *if* compile passes.
# Six original PROMOTEs demoted to HOST after closer reading (see §1 table) — only one candidate remains.
VERIFY_PROMOTE_FILES = %w[
  TerminalControllerSocketSecurityTests.swift
].freeze

# Strategy A only: Sources/ files to dual-compile into c11LogicTests.
# Source of truth: `.lattice/plans/c11-27-sources.txt` — derived from c11-27-deps.txt per §1.5.
# The script REFUSES to run under STRATEGY=A without that file — no stale-stub trap.
STRATEGY_A_SOURCES =
  if STRATEGY == 'A'
    sources_path = File.expand_path('../.lattice/plans/c11-27-sources.txt', __dir__)
    abort "STRATEGY=A requires #{sources_path} (run §1.5 audit then derive: awk '{print $3}' c11-27-deps.txt | sort -u > c11-27-sources.txt)" unless File.exist?(sources_path)
    lines = File.readlines(sources_path).map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
    abort "STRATEGY=A: #{sources_path} is empty" if lines.empty?
    # One Sources/ path per line, project-root-relative.
    lines.freeze
  else
    [].freeze
  end

# Idempotent: spike commit creates the target; bulk commit re-runs and finds it.
new_target = project.targets.find { |t| t.name == 'c11LogicTests' } ||
             project.new_target(:unit_test_bundle, 'c11LogicTests', :osx, '14.0', nil)

# add_dependency is a no-op if already present.
new_target.add_dependency(c11_app) if STRATEGY == 'B' && new_target.dependencies.none? { |d| d.target == c11_app }

%w[Debug Release].each do |config_name|
  bc = new_target.build_configurations.find { |c| c.name == config_name }
  bc.build_settings.merge!(
    'GENERATE_INFOPLIST_FILE'    => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER'  => 'com.stage11.c11.logictests',
    'PRODUCT_NAME'               => '$(TARGET_NAME)',
    'CURRENT_PROJECT_VERSION'    => '101',
    'MARKETING_VERSION'          => '0.47.1',
    'MACOSX_DEPLOYMENT_TARGET'   => '14.0',
    'SWIFT_VERSION'              => '5.0',
    'CODE_SIGN_STYLE'            => 'Automatic',
  )
  bc.build_settings['ONLY_ACTIVE_ARCH'] = (config_name == 'Debug' ? 'YES' : 'NO')
  bc.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)' if config_name == 'Debug'
  # Defensive: explicitly clear, in case a future xcconfig adds these at the project level.
  bc.build_settings['TEST_HOST'] = ''
  bc.build_settings.delete('TEST_TARGET_NAME')
  if STRATEGY == 'B'
    # Debug produces `c11 DEV.app`; Release produces `c11.app`. Mirrors the existing c11Tests target.
    app_dir = (config_name == 'Debug' ? 'c11 DEV.app' : 'c11.app')
    bc.build_settings['BUNDLE_LOADER'] = "$(BUILT_PRODUCTS_DIR)/#{app_dir}/Contents/MacOS/c11"
  else
    bc.build_settings['BUNDLE_LOADER'] = ''
  end
end

# Move test files c11Tests → c11LogicTests. Idempotent: skips files already in the new target.
verify_promote_kept = (ENV['INCLUDE_VERIFY_PROMOTE'] == '1') ? VERIFY_PROMOTE_FILES : []
moved_count = 0
(PURE_FILES + verify_promote_kept).each do |filename|
  ref = tests_group.files.find { |f| f.path == filename } or abort "missing ref: #{filename}"
  # Skip if already moved (idempotency for the spike-then-bulk workflow).
  if new_target.source_build_phase.files.any? { |bf| bf.file_ref == ref }
    next
  end
  build_file = existing_tests.source_build_phase.files.find { |bf| bf.file_ref == ref }
  existing_tests.source_build_phase.remove_build_file(build_file) if build_file
  new_target.source_build_phase.add_file_reference(ref)
  moved_count += 1
end

# Strategy A only: dual-compile Sources/ files AND strip `@testable import c11` blocks from moved tests.
if STRATEGY == 'A'
  STRATEGY_A_SOURCES.each do |path|
    # Resolve by full project-relative path, not basename — duplicate leaf names elsewhere under Sources/
    # would silently match the wrong file.
    expected = path.sub(/^\.?\//, '')
    ref = project.files.find { |f| f.real_path.to_s.end_with?('/' + expected) || f.path == expected }
    abort "Strategy A: source not in project: #{path}" if ref.nil?
    next if new_target.source_build_phase.files.any? { |bf| bf.file_ref == ref }
    new_target.source_build_phase.add_file_reference(ref)
  end

  # Bulk-rewrite `@testable import c11` / `@testable import c11_DEV` blocks in moved test files.
  # Under Strategy A the production types are now in-module; the @testable import becomes wrong.
  worktree_root = File.expand_path('..', __dir__)
  (PURE_FILES + verify_promote_kept).each do |filename|
    path = File.join(worktree_root, 'c11Tests', filename)
    next unless File.exist?(path)
    content = File.read(path)
    # Match common patterns (3 forms used in this codebase):
    #   "@testable import c11"
    #   "@testable import c11_DEV"
    #   #if canImport(c11_DEV)
    #   @testable import c11_DEV
    #   #elseif canImport(c11)
    #   @testable import c11
    #   #endif
    new_content = content
      .gsub(/^@testable import c11(_DEV)?\b.*\n/, '')
      .gsub(/^#if canImport\(c11_DEV\)\n@testable import c11_DEV\n#elseif canImport\(c11\)\n@testable import c11\n#endif\n/, '')
    if new_content != content
      File.write(path, new_content)
    end
  end

  # Validation gate 1: no PURE test still references `@testable import c11`.
  remaining_testable = (PURE_FILES + verify_promote_kept).select do |filename|
    path = File.join(worktree_root, 'c11Tests', filename)
    File.exist?(path) && File.read(path).match?(/@testable import c11(_DEV)?\b/)
  end
  abort "Strategy A: failed to strip @testable import from: #{remaining_testable.join(', ')}" unless remaining_testable.empty?

  # Validation gate 2: no orphan `#if canImport(c11...)` blocks left behind (would be a compile error).
  remaining_canimport = (PURE_FILES + verify_promote_kept).select do |filename|
    path = File.join(worktree_root, 'c11Tests', filename)
    File.exist?(path) && File.read(path).match?(/^#if canImport\(c11(_DEV)?\)/)
  end
  abort "Strategy A: orphan #if canImport(c11...) blocks in: #{remaining_canimport.join(', ')}" unless remaining_canimport.empty?

  # Validation gate 3: belt-and-suspenders — parse each rewritten file with swiftc.
  # Catches syntactic damage the regex didn't anticipate (e.g., a malformed comment around the import block).
  swiftc = `xcrun -find swiftc 2>/dev/null`.strip
  if !swiftc.empty?
    bad = (PURE_FILES + verify_promote_kept).select do |filename|
      path = File.join(worktree_root, 'c11Tests', filename)
      File.exist?(path) && !system("#{swiftc} -parse -sdk $(xcrun --sdk macosx --show-sdk-path) #{path} > /dev/null 2>&1")
    end
    abort "Strategy A: swiftc -parse failed for: #{bad.join(', ')}" unless bad.empty?
  end

  # CAVEAT: dual-compiled Sources/ files may pull SwiftPM packages (Sparkle, sentry-cocoa, posthog-ios, swift-markdown-ui)
  # or framework dependencies. The script does NOT mirror those into c11LogicTests automatically.
  # If `xcodebuild build -scheme c11-logic` fails on missing module imports, this is the cause.
  # Resolution: either (a) add the required package products to c11LogicTests' Frameworks build phase
  # using project.targets.find('c11LogicTests').add_dependency / add the PBXBuildFile manually, or (b)
  # demote the dependent tests to HOST (no dual-compile needed). Strategy A's spike (§2.2 step 2) should
  # surface this before bulk move; if it does, STOP and re-plan rather than blindly mirroring deps.
end

project.save
puts "wrote target c11LogicTests under Strategy #{STRATEGY}; moved #{moved_count} new file(s)"
```

**Implementer workflow (with spike-first; commits are separable):**

1. **Pin the baseline + clarify CI gate semantics.** The ticket says "47 pre-existing main test failures won't be fixed by this move" — confirming main's `c11-unit test` is currently red. Raw `xcodebuild ... test` exits nonzero on any failure, so C11-27's PR cannot require a fully green `c11-unit` CI step without either (a) fixing the baseline (out of scope per the ticket) or (b) comparing against a recorded baseline.

   **Decision: option (b).** The PR's CI gate is **"no new test failures in c11LogicTests beyond the baseline subset that lives there"**, not "all tests pass." The implementer pins the baseline AND wires a comparison check into `ci.yml`.

   Capture recipe (CI-only — never run `xcodebuild test` locally):
   ```bash
   # Pin to the exact commit, not just "latest main run" — guards against another run completing in parallel.
   gh workflow run ci.yml --ref main  # or wait for the run that fired on 7e0e0b282
   RUN_ID=$(gh run list --workflow ci.yml --branch main --limit 25 --json databaseId,headSha \
              --jq '[.[] | select(.headSha == "7e0e0b282")][0].databaseId')
   [ -n "$RUN_ID" ] || { echo "no ci.yml run for 7e0e0b282 yet — re-trigger and retry"; exit 1; }
   gh run view "$RUN_ID" --log | grep -E '^Test Case .* failed' \
     | sed -E 's/^Test Case .-\[(.*)\].*failed.*$/\1/' \
     | sort -u > .lattice/plans/c11-27-baseline-failures.txt
   ```
   Format: one `TestClass testMethod` per line. Commit.

   **Optional comparison harness in `ci.yml`** — wrap the `xcodebuild ... test` step in a script that:
   - Runs the test command, captures the `Test Case .*failed` lines into `/tmp/c11-27-pr-failures.txt`.
   - `diff -u .lattice/plans/c11-27-baseline-failures.txt /tmp/c11-27-pr-failures.txt`.
   - Exit 0 if the PR's failure set is a **subset** of the baseline (no new failures and any baseline failures already-known are tolerated).
   - Exit 1 if any failure appears in the PR set that's not in the baseline.

   **If the comparison harness is out of scope for C11-27**, the alternative is to document plainly that `c11-unit` CI stays red until the 47 are fixed/isolated, and acceptance shifts to: "(1) `c11-logic` CI is green; (2) `c11-unit` CI is red with the same baseline as `origin/main@7e0e0b282`." The reviewer at PR time validates the failure set by hand against the committed baseline. Both options are listed; the implementer picks one in the §3 step 7 commit and documents the choice in the PR description.
2. **Spike commit (Strategy B):** create `c11LogicTests` target + `c11-logic.xcscheme` together (scheme creation here, not at step 7, so the spike commands at §2.2 can use `-scheme c11-logic`). Move only the four spike files. No CI changes yet. Per §2.2 step 1, run the build + monitored test invocation. If it passes (no `c11(.app| DEV.app)` process during the run AND all four tests green), commit as `feat(C11-27): spike c11LogicTests target under Strategy B`. If it fails, `git restore` the worktree and try Strategy A per §2.2 step 2 (separate spike commit).
3. **Verify-promote check.** Drop `import AppKit` from `TerminalControllerSocketSecurityTests.swift`. Run `xcodebuild build -scheme c11-logic -configuration Debug`. If it builds, set `INCLUDE_VERIFY_PROMOTE=1` for step 4 and stage the edit. If it fails, revert the edit and leave the file in `c11Tests`.
4. **Bulk move commit.** Run `STRATEGY=<A|B> [INCLUDE_VERIFY_PROMOTE=1] ruby scripts/c11-27-split-tests.rb`. Inspect `git diff GhosttyTabs.xcodeproj/project.pbxproj`. **Gate criteria (not a line-by-line checksum):**
   - `xcodebuild -list -project GhosttyTabs.xcodeproj` shows `c11LogicTests` in the Targets list.
   - The diff contains no removed `PBXNativeTarget` entries for existing targets.
   - `xcodebuild build -scheme c11-unit -configuration Debug -destination "platform=macOS"` succeeds.
   - Under Strategy A only: `grep -rn '@testable import c11' c11Tests/$(echo PURE_FILES | tr ' ' '|')` returns empty for the moved files (validation gate baked into the script).
   What to expect when reviewing the diff: one new PBXNativeTarget block + one XCConfigurationList + 2 XCBuildConfiguration entries + 73–74 PBXBuildFile reassignments + (Strategy A only) PBXBuildFile additions for dual-compiled Sources. Use this as orientation, not a checksum.
   Commit as `feat(C11-27): move PURE tests to c11LogicTests target`.
5. **Scheme updates commit.** Update `c11-unit.xcscheme` (add `c11LogicTests` as second TestableReference) and `c11-ci.xcscheme` (add `c11LogicTests` as third TestableReference alongside c11Tests + c11UITests). Visual parse-check in Xcode (don't build/run from Xcode — would trigger DEV.app). Commit as `feat(C11-27): wire c11LogicTests into c11-unit + c11-ci schemes`.
6. **Compile validation.** `xcodebuild build -scheme c11-logic -configuration Debug` and `xcodebuild build -scheme c11-unit -configuration Debug` — both must compile locally. **No `xcodebuild test` locally; CI is the gate.**
7. **CI + docs commit.** Update `.github/workflows/ci.yml` per §4.1, `mailbox-parity.yml` per §4.2, `CLAUDE.md` Testing policy per §5. Commit as `feat(C11-27): point CI + docs at c11-logic`.
8. **Push and PR.** PR's CI run validates `c11-unit` scheme green (which covers both targets via the §4.6 wiring) within the wall-time bar. Mailbox-parity workflow runs `c11-logic` and validates the selector update.

**Fallback if the Ruby script corrupts the project:** `git restore GhosttyTabs.xcodeproj`, fix script, re-run. If script can't be fixed, do the surgery interactively in Xcode (File → New → Target → macOS Unit Testing Bundle; set build settings per §2.3; drag the 80 files into target membership; create the scheme via Product → Scheme → Manage Schemes). Validation gate either way: project opens, all three schemes appear in the picker, both `c11-logic` and `c11-unit` compile.

---

## 4. CI / docs / schemes — explicit per-file update list

Per plan-review §3 MAJOR #3, every file that needs touching:

### 4.1 `.github/workflows/ci.yml` (line 186–208)

**Decision: single `c11-unit test` step, both TestableReferences inside.** Avoids the double-run that v2 introduced (running `c11-logic test` then `c11-unit test` re-ran the 80 logic tests in xctest a second time). The `c11-unit` scheme's TestAction is updated in §4.6 to include both `c11Tests` and `c11LogicTests` as TestableReferences, so one invocation covers both. This preserves the ticket's "no worse than today" wall-time acceptance exactly — no relaxation.

Rewrite the step (keep the surrounding comment context that explains why this step exists at all — the compile-rot lesson from 2026-05-07 — and add a note that the scheme now covers both targets):

```yaml
      - name: Test c11-unit scheme (covers c11LogicTests + c11Tests after C11-27)
        # Catches both the compile-rot failure mode discovered 2026-05-07
        # (production-code refactors silently breaking c11Tests compilation —
        # `@MainActor` inheritance, missing struct fields, signature drift) and
        # runtime regressions. After C11-27, the `c11-unit` scheme runs both
        # `c11Tests` (host-required, ~22 s with DEV.app) and `c11LogicTests`
        # (pure logic, ~5–10 s xctest-only) sequentially via two TestableReferences.
        # Without this step, neither `Build app` above nor any other CI workflow
        # exercises both targets at all.
        run: |
          set -euo pipefail
          SOURCE_PACKAGES_DIR="$PWD/.ci-source-packages"
          xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-unit -configuration Debug \
            -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
            -disableAutomaticPackageResolution \
            -destination "platform=macOS" \
            COMPILER_INDEX_STORE_ENABLE=NO \
            test
```

**Why not a separate `c11-logic` step?** Two reasons: (a) `c11-unit` already runs the logic suite via its second TestableReference, so a dedicated step would duplicate work and pad CI wall time; (b) fast local feedback is the operator's loop, not CI's — CI runs ~once per push and is already ~30 s, so saving 5 s on a step that costs 10 s isn't worth the double-execution mess. If wall-time later regresses for a different reason, a follow-up can introduce a `c11-host` scheme that includes only `c11Tests`, with `c11-logic` run separately.

### 4.2 `.github/workflows/mailbox-parity.yml` (lines 136–162)

All ten `-only-testing` selectors target tests now in `c11LogicTests`. Without the selector update, CI silently goes green over zero tests.

Replace `-scheme c11-unit` with `-scheme c11-logic`, and replace each `-only-testing:c11Tests/X` with `-only-testing:c11LogicTests/X`:

```yaml
      - name: Run mailbox unit tests
        run: |
          set -euo pipefail
          SOURCE_PACKAGES_DIR="$PWD/.ci-source-packages"
          xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic -configuration Debug \
            -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
            -disableAutomaticPackageResolution \
            -destination "platform=macOS" \
            -only-testing:c11LogicTests/MailboxEnvelopeValidationTests \
            -only-testing:c11LogicTests/MailboxDispatcherTests \
            -only-testing:c11LogicTests/MailboxDispatcherGCTests \
            -only-testing:c11LogicTests/MailboxOutboxWatcherTests \
            -only-testing:c11LogicTests/MailboxDispatchLogTests \
            -only-testing:c11LogicTests/MailboxIOTests \
            -only-testing:c11LogicTests/MailboxLayoutTests \
            -only-testing:c11LogicTests/MailboxSurfaceResolverTests \
            -only-testing:c11LogicTests/MailboxULIDTests \
            -only-testing:c11LogicTests/StdinHandlerFormattingTests \
            COMPILER_INDEX_STORE_ENABLE=NO \
            test
```

Update the comment at line 141: "CLAUDE.md notes `xcodebuild -scheme c11-logic` is safe (no app launch)" — match new scheme name.

Resolve-packages step (line 136) can stay on `c11-unit` (resolution is identical and cached; minimizes blast radius), or move to `c11-logic` — either is fine; recommend leaving on `c11-unit`.

### 4.3 `.github/workflows/ci-macos-compat.yml` (line 127)

Verified — `grep -nE 'c11-(ci|unit|logic)|c11Tests|c11LogicTests' .github/workflows/ci-macos-compat.yml` returns one hit at line 127, inside a `-resolvePackageDependencies` step. Not a test invocation. **Leave unchanged** — no regression.

### 4.4 `.github/workflows/test-e2e.yml` (line 190)

Verified — `grep -nE 'c11-(ci|unit|logic)|c11Tests|c11LogicTests' .github/workflows/test-e2e.yml` returns one hit at line 190, also `-resolvePackageDependencies`. **Leave unchanged.**

Confirmed neither workflow references `c11-ci` elsewhere, so the §4.5 addition of `c11LogicTests` to `c11-ci.xcscheme` doesn't introduce a new run-surface here.

### 4.5 `GhosttyTabs.xcodeproj/xcshareddata/xcschemes/c11-ci.xcscheme`

Add `c11LogicTests` so coverage doesn't regress. **Two XML additions are required** — both the BuildActionEntry (so `xcodebuild build` compiles the bundle) AND the TestableReference (so `xcodebuild test` runs it). The existing schemes carry both for `c11Tests`; mirror that.

**Inside `<BuildAction>` / `<BuildActionEntries>`, add a third entry** (alongside the existing `c11` and `c11Tests` entries) — preserving the existing buildForTesting / buildForRunning attribute pattern used by `c11Tests`:

```xml
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
        <BuildableReference BuildableIdentifier="primary"
          BlueprintIdentifier="<c11LogicTests UUID — xcodeproj writes it; read from project.pbxproj after first save>"
          BuildableName="c11LogicTests.xctest"
          BlueprintName="c11LogicTests"
          ReferencedContainer="container:GhosttyTabs.xcodeproj"/>
      </BuildActionEntry>
```

**Inside `<TestAction>` / `<Testables>`, add a third TestableReference** (order: `c11Tests` → `c11LogicTests` → `c11UITests`):

```xml
      <TestableReference skipped="NO">
        <BuildableReference BuildableIdentifier="primary"
          BlueprintIdentifier="<c11LogicTests UUID>"
          BuildableName="c11LogicTests.xctest"
          BlueprintName="c11LogicTests"
          ReferencedContainer="container:GhosttyTabs.xcodeproj"/>
      </TestableReference>
```

The `<c11LogicTests UUID>` value is the same in both blocks — read it from the `PBXNativeTarget` entry the Ruby script writes into `project.pbxproj` (look for `c11LogicTests` immediately preceding `= {`).

### 4.6 `GhosttyTabs.xcodeproj/xcshareddata/xcschemes/c11-unit.xcscheme`

Same pattern as §4.5: add `c11LogicTests` as a second BuildActionEntry AND a second TestableReference, next to `c11Tests`. After the change, `c11-unit test` runs all 100–101 tests (73–74 in c11LogicTests + 27–28 in c11Tests) in one invocation. **Both XML additions are required** — TestableReference alone produces silent build-but-no-compile behavior on some Xcode versions.

### 4.6.1 `GhosttyTabs.xcodeproj/xcshareddata/xcschemes/c11-logic.xcscheme` (new file)

Created during the spike commit (§3 step 2). Template based on `c11-unit.xcscheme`. **BuildAction** entries include the `c11` app (Strategy B only — required so the host binary exists for `BUNDLE_LOADER` to point at) and `c11LogicTests`. **TestAction** runs only `c11LogicTests`. **LaunchAction / ProfileAction** target `c11.app` so the scheme is selectable for run/debug, but the `TEST_HOST = ''` build setting (see §2.3) prevents tests from launching the app.

```xml
<Scheme LastUpgradeVersion="1500" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <!-- Strategy B only; omit under Strategy A. -->
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary"
          BlueprintIdentifier="A5001050" BuildableName="c11.app"
          BlueprintName="c11" ReferencedContainer="container:GhosttyTabs.xcodeproj"/>
      </BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
        <BuildableReference BuildableIdentifier="primary"
          BlueprintIdentifier="<c11LogicTests UUID>" BuildableName="c11LogicTests.xctest"
          BlueprintName="c11LogicTests" ReferencedContainer="container:GhosttyTabs.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" ...>
    <Testables>
      <TestableReference skipped="NO">
        <BuildableReference BuildableIdentifier="primary"
          BlueprintIdentifier="<c11LogicTests UUID>" BuildableName="c11LogicTests.xctest"
          BlueprintName="c11LogicTests" ReferencedContainer="container:GhosttyTabs.xcodeproj"/>
      </TestableReference>
    </Testables>
    <MacroExpansion>
      <!-- Strategy B: MacroExpansion → c11.app (the BUNDLE_LOADER target).
           Strategy A: MacroExpansion → c11LogicTests.xctest itself.
           Either way `$(SRCROOT)` resolves to the project root; only `$(BUILT_PRODUCTS_DIR)` resolution differs.
           Today's PURE tests don't reference path macros, but pointing MacroExpansion at the test bundle
           under Strategy A keeps the scheme valid for run/debug without requiring c11.app to be built.
           If a test later relies on `$(BUILT_PRODUCTS_DIR)` resolving to a specific product, that's a
           separate spike-time discovery. -->
      <BuildableReference BuildableIdentifier="primary"
        BlueprintIdentifier="A5001050" BuildableName="c11.app"
        BlueprintName="c11" ReferencedContainer="container:GhosttyTabs.xcodeproj"/>
    </MacroExpansion>
  </TestAction>
  <LaunchAction .../>
  <ProfileAction .../>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Debug" revealArchiveInOrganizer="YES"/>
</Scheme>
```

### 4.7 `CLAUDE.md` Testing policy

Section rewrite in §5 below.

### 4.8 `AGENTS.md`

Relative symlink to `CLAUDE.md`. Verify: `readlink AGENTS.md` → `CLAUDE.md`. No edit needed; auto-syncs.

### 4.9 `docs/DEVELOPMENT.md` (does not currently exist)

`ls docs/` shows no such file. If a future doc surface materializes, this section gets added; nothing to update right now.

### 4.10 Out of scope

- **`c11UITests`** — separate target, always needs a host app, stays untouched.
- **`~/.claude/CLAUDE.md`** (user's global instructions) — operator-managed, not a project file.
- **`code/Lattice/...`** project — unrelated to c11.

### Wall-time sanity check

Before: `c11-unit test` runs c11Tests serially in c11 DEV.app host, ~22 s test time + ~10 s app launch ≈ 35 s.

After:
- `c11-logic test`: ~5–10 s (80 fast tests, no host).
- `c11-unit test`: ~25–35 s (re-runs the 80 logic tests in xctest + 21 host tests in DEV.app).
- Total: ~35–45 s — within the "no worse than today" acceptance bar.

If wall-time regresses materially post-merge, follow-up ticket introduces `c11-host` scheme (host tests only). Out of scope here.

---

## 5. CLAUDE.md Testing policy rewrite (verbatim)

Replace the existing `## Testing policy` section (lines 128–135) with this **verbatim**:

```markdown
## Testing policy

c11 has two unit-test targets. The split is the whole point of C11-27.

- **`c11LogicTests` (scheme: `c11-logic`)** — logic-only. No Host Application, no DEV.app launch. **Safe to run locally** for fast iteration:

  ```
  xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic -configuration Debug \
    -destination "platform=macOS" test
  ```

  Expected wall time on a warm cache: around 30 seconds, dominated by `xcodebuild`'s ~10–15 s of inherent overhead rather than test execution (the test phase itself is ~5–10 s for 73 tests). Compare to the host scheme's ~35 s, where most of the gap is the DEV.app launch. **First invocation after a clean checkout pays the c11 app build cost** (multi-minute) under Strategy B because `c11-logic` depends on the `c11` target; subsequent warm-build runs are ~30 s. Under Strategy A, the cold build only compiles the dual-included sources + test bundle (~15–30 s cold). Use this for any iteration on Mailbox, Theme, Workspace snapshot, Health parser, CLI runtime, persistence, and parser code.

- **`c11Tests` (scheme: `c11-unit`)** — host-required. Spawns a `c11 DEV.app` XCTest host whose main thread is monopolized for ~22 s and whose window beachballs until the run completes (per the 2026-05-15 PR #164 incident — confirmed not to affect the operator's main c11 process, only the freshly-spawned test host). **Do not run locally.** Send to CI via GitHub Actions. The `c11-unit` scheme builds both targets but its TestAction runs both `c11Tests` and `c11LogicTests` sequentially in one invocation.

  Schemes that build c11-unit (or `c11-ci`) without the `test` action are safe — they only compile.

- **Python socket tests (`tests_v2/`)** — connect to a running c11 instance's socket. Never launch an untagged `c11 DEV.app` to run them. If you must test locally, use a tagged build's socket (`/tmp/c11-debug-<tag>.sock`) with `C11_SOCKET=/tmp/c11-debug-<tag>.sock` (or `CMUX_SOCKET=…` as compat).

- **E2E / UI tests** — trigger via `gh workflow run test-e2e.yml`. Never run locally.

- **Never `open` an untagged `c11 DEV.app`** from DerivedData. It conflicts with the user's running debug instance.

**Rule of thumb:** if you're touching parsers, snapshots, persistence, or any pure model code, `c11-logic` is your local loop. If you're touching window/view/event/IME code, your iteration loop is `xcodebuild build` + a tagged reload (`./scripts/reload.sh --tag <tag>`), and tests go to CI.
```

Notes for the implementer:
- The existing line "`xcodebuild -scheme c11-unit` is safe (no app launch)" is **wrong** for the `test` action and gets removed.
- Preserve "Never `open` an untagged `c11 DEV.app`" verbatim — load-bearing for the operator's c11 process.
- The `## Test quality policy` section above (lines 119–126) is unchanged.

---

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation | Fallback |
|---|---|---|---|---|
| **pbxproj corruption from scripted edits** | Medium | High | `xcodeproj` gem only; never sed; inspect `git diff` before staging; `xcodebuild build` on both schemes before commit. | `git restore GhosttyTabs.xcodeproj`; fix script or do surgery interactively in Xcode. Gate either way: project opens, all 3 schemes appear, both schemes compile. |
| **`@testable import c11` fails under Strategy B (BUNDLE_LOADER without TEST_HOST)** | Medium | High | Strategy B is explicitly spike-tested before bulk rollout (§2.2 step 1) with per-config `BUNDLE_LOADER` paths (Debug → `c11 DEV.app`, Release → `c11.app`) so the link doesn't fail for the *wrong* reason. Spike output decides whether to proceed with B or fall back to A. | Strategy A: dual-compile. Production-source dependency audit (§1.5) gates inclusion; if post-demotion count drops below 50, escalate to Strategy C (out of scope; reopen ticket). |
| **Spike acceptance gate is sampled at the wrong time and lets the app slip through** | Was-high, now mitigated | High | §2.2 step 1 spec uses a monitored `pgrep` loop *during* the test phase (sampled every 0.25 s while `xcodebuild` is running) plus a preflight check that nothing is already running. Pattern broadened to `/c11( DEV)?\.app/Contents/MacOS/c11` so both Debug and Release app names are caught. | If `pgrep` somehow misses a launch (unlikely at 0.25 s cadence over a 5–10 s test phase), the spike falsely passes and bulk-move surfaces it. Detection: any CI run that takes meaningfully longer than expected on `c11-logic`. |
| **A PURE-classified file pulls AppKit transitively** | High under Strategy A, Low under Strategy B | Medium | §1.5 audit produces `.lattice/plans/c11-27-deps.txt` listing every Sources/ file that has to dual-compile. AppKit-importing source files become decision points (protocol-extract or demote test). | Under Strategy A: demote the affected test(s) to HOST. Never add `import AppKit` to a pure test. Under Strategy B: not applicable. |
| **Symbol visibility: `internal` types not visible to new target** | Low | Medium | Existing test files already use `@testable import c11` / `@testable import c11_DEV` (verified §1 sampling). New target inherits `ENABLE_TESTABILITY = YES`. Under Strategy A, types are in-module so visibility is moot. | Escalate the offending `internal` to `public` (one-keyword diff); note in PR description. |
| **Grep-only classification false positives** | **Confirmed 6/7 on PROMOTE re-audit** | Medium | Compiler is the audit. Implementer runs `xcodebuild build -scheme c11-logic` after each batch; files that fail to compile are demoted to HOST in the same commit. §1.5 second-stage audit is mandatory under Strategy A; produces a checked-in artifacts (`c11-27-deps.txt` raw triples + `c11-27-sources.txt` de-duped path list) reviewers can verify against. | Demote false-positive PURE tests to HOST. PR description names them. Resist adding `import AppKit` to a "pure" test to make it compile — that defeats the split. |
| **Verify-promote candidate doesn't compile after `import AppKit` drop** | Medium (1/7 survived re-audit; the 1 may still fail) | Low | §3 step 3 verifies via `xcodebuild build` before the bulk-move script runs. The script gates inclusion on `INCLUDE_VERIFY_PROMOTE=1`. | Revert the import edit; the file stays in `c11Tests`. `c11LogicTests` size drops by 1 (73 instead of 74). No other impact. |
| **47 pre-existing main test failures muddy the new scheme's signal** | High | Low | Baseline pinned: run `c11-unit test` against `origin/main@7e0e0b282` in CI; capture failing-test list as `.lattice/plans/c11-27-baseline-failures.txt`. PR diffs against the baseline. | Any test failing in c11LogicTests that was also failing in c11Tests pre-split = pre-existing, not a regression. C11-27 does not fix these (PR #152 covers 3; rest tracked separately). |
| **`mailbox-parity.yml` `-only-testing` selectors break silently** | Was-high, now mitigated | High | §4.2 specifies the exact replacement (10 selectors, all moved to `c11LogicTests/...` with `c11-logic` scheme). PR diff visibly changes both. | None needed; the silent-pass mode is what the explicit change prevents. |
| **`c11-ci.xcscheme` coverage regression** | Was-medium, now mitigated | Medium | §4.5 explicitly adds `c11LogicTests` as a third TestableReference. | None; the explicit edit prevents the regression. |
| **CI matrix change breaks an un-grepped downstream workflow** | Low | Medium | §4 audit covers all four `.github/workflows/*.yml` files that reference `c11-unit` / `c11-ci` / `c11Tests`. PR's own CI run is the gate. | Fix in the PR before merge. |
| **PROMOTE candidate fails after dropping `import AppKit`** | Low | Low | `xcodebuild build` after the PROMOTE-edits commit (step 3 in §3 workflow) catches any failure locally. | Restore the import for that file; demote PROMOTE → HOST in the script. Other 79 files unaffected. |
| **Spike falsely passes Strategy B because the c11.app got built first elsewhere** | Low | Medium | Spike runs after `xcodebuild clean` to ensure the only thing on disk is what the test invocation produces. `pgrep -fl 'c11 DEV.app'` during the run is the authoritative "did the app launch" check. | Re-spike with explicit clean; if persistent, escalate to Strategy A. |

---

## 7. Precondition (satisfied — not gating)

PR #164 (`Drop c11mux from active code paths: state-dir migration, theme rename, test fixes`) merged into `origin/main@7e0e0b282` on 2026-05-15. Worktree is rebased onto that commit (verified via `git log -1 --oneline` showing `7e0e0b282`). **Implementation is unblocked. No further gating on #164.**

---

## 8. Acceptance criteria (mechanical, per plan-review §3 MINOR #6)

Each criterion is testable by a concrete command or check. Replaces the ticket's looser "<5 seconds" and "no frozen DEV.app window" criteria with measurable equivalents.

- [ ] **TEST_HOST is empty for `c11-logic`** — `xcodebuild -showBuildSettings -project GhosttyTabs.xcodeproj -scheme c11-logic -configuration Debug -destination "platform=macOS" | awk '/^[[:space:]]*TEST_HOST[[:space:]]*=/{print $0; exit}'` returns either no match or `TEST_HOST = ` followed by empty. Repeat for `-configuration Release`.
- [ ] **BUNDLE_LOADER matches the chosen Strategy and per-config product name.**
  - Under Strategy A: `-showBuildSettings` for both configurations returns either no `BUNDLE_LOADER` match or empty.
  - Under Strategy B: Debug returns `BUNDLE_LOADER = <abs>/c11 DEV.app/Contents/MacOS/c11`; Release returns `BUNDLE_LOADER = <abs>/c11.app/Contents/MacOS/c11`. Mirrors the existing `c11Tests` per-config split.
- [ ] **No `c11(.app| DEV.app)` process launches during a `c11-logic` test run** — operator runs the §2.2 step 1 monitored block locally on a clean build. Both gates hold: `pgrep -fl '/c11( DEV)?\.app/Contents/MacOS/c11'` empty throughout the test phase AND `xcodebuild ... test` exits 0. The broader pattern catches both Debug and Release app binaries.
- [ ] **`xcodebuild -scheme c11-logic ... test` exits with status 0** modulo pre-existing failures listed in `.lattice/plans/c11-27-baseline-failures.txt` filtered to the c11LogicTests subset. PR description names the intersect explicitly. Any non-baseline failure blocks merge.
- [ ] **Test phase under 12 s on warm build** — `xcodebuild ... test` output line `Test Suite 'All tests' passed at ... -- (... seconds)`. The `(... seconds)` ≤ 12.0. **Deviation from ticket noted:** the ticket said "<5 seconds" without specifying test-phase vs total wall time. With 73 tests including Mailbox file-I/O fixtures and Workspace persistence, 5 s is optimistic for the test phase alone; 12 s is the conservative cap. Atin to confirm acceptance of this deviation at PR review (one bullet in PR description). If "<5 s" must hold, the implementer tightens via test parallelism (`-parallel-testing-enabled YES`) or measures the actual delta and renegotiates.
- [ ] **CI wall-time matches "no worse than today"** — the PR's `ci.yml` `Test c11-unit scheme` step completes within 5 % of pre-C11-27 wall time on the same runner. Because `c11-unit` covers both targets in one invocation (§4.6), there is no double-execution to budget for. Hard regression budget: 0 s; soft tolerance: noise floor (±5 %).
- [ ] **`c11-unit test` covers all 101 test files** — one invocation runs both bundles. Verify by counting **test-file membership** in the project file (not XCTest method count, which is much larger):
  ```bash
  ruby -r xcodeproj -e 'p=Xcodeproj::Project.open("GhosttyTabs.xcodeproj"); \
    %w[c11Tests c11LogicTests].each { |n| t=p.targets.find{|x|x.name==n}; \
    puts "#{n}: #{t.source_build_phase.files.count}" }'
  ```
  Expect: `c11LogicTests: 73` or `74`; `c11Tests: 28` or `27`; sum = 101.
- [ ] **`c11-ci test` covers all 101 test files + UI tests** — c11LogicTests + c11Tests + c11UITests via three TestableReferences AND three BuildActionEntries (§4.5).
- [ ] **CLAUDE.md `## Testing policy` reflects §5 verbatim.**
- [ ] **PR diff of `GhosttyTabs.xcodeproj/project.pbxproj` is additive** — one new PBXNativeTarget block, one new XCConfigurationList + 2 XCBuildConfiguration entries, 73–74 PBXBuildFile reassignments, plus (Strategy A only) PBXBuildFile additions for dual-compiled Sources. No reorderings of existing entries, no formatting churn.
- [ ] **Spike commit, bulk commit, scheme commit, CI commit are separable** — `git log feat/c11-27-test-split ^origin/main` shows the §3 workflow's 5+ logical commits. Reviewer can read each independently.
- [ ] **`.lattice/plans/c11-27-deps.txt` AND `c11-27-sources.txt` are checked into the PR** (Strategy A only) — `deps.txt` is the audit-evidence file (triples), `sources.txt` is the de-duped path list the Ruby script consumes. The script refuses to run under `STRATEGY=A` without `sources.txt`.
- [ ] **`.lattice/plans/c11-27-memory-note.md` checked into the PR** — captures the exact change to Atin's `feedback_no_local_xcodebuild_test.md` memory ("never run `xcodebuild test` on c11 locally" → "never run host-bearing schemes (`c11-unit`, `c11-ci`) locally; `c11-logic` is safe") so the request is reviewable. The actual memory file lives outside the repo (`~/.claude/projects/.../memory/`) and Atin updates it post-merge — that ask goes in the PR description as a bullet, not in this mechanical-acceptance list.

End of plan.
