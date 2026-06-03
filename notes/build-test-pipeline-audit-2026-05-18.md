# c11 build + test pipeline audit — 2026-05-18

**Scope.** End-to-end audit of the c11 build, test, release, signing, distribution, and auto-update pipeline following the v0.48.0 admin-merge ship (the `build` job in `ci.yml` was red on the release PR and on every preceding main commit for 50+ runs).

**Author.** Claude (Opus 4.7), driven by Atin.

**Bottom line.** The release-builder path (`release.yml`) is genuinely healthy — v0.48.0 was signed, notarized, stapled, appcasted, and pushed to Homebrew cleanly. The CI test path (`ci.yml`'s `build` job → `Test c11-unit scheme`) is structurally broken in a way that's been red since 2026-05-16 and is now both (a) misdiagnosed as a hang and (b) hard to iterate on locally because the test host stomps the operator's running c11. The combination is masking 32 real test failures. There are also two unrelated bit-rots in `nightly.yml` (one-line fix) and `test-e2e.yml`/`claude.yml` (stale scheme + missing secret).

---

## 1. The "hang" is not a hang

Pulled full logs for both runs cited in the prompt (`gh run view --log --job 76604384102` for run 26056033436; `gh run view --log --job 76598532322` for run 26054336139). The framing in the prompt ("the build job hung twice in a row at the 'Test c11-unit scheme' step until the 15-minute job timeout") is close to right but not quite. What's actually happening:

| Run | Wall time on test step | Outcome | Cause |
|---|---|---|---|
| 26054336139 (earlier) | 10:54 (cancelled by `timeout-minutes: 15`) | GitHub-cancelled mid-suite | c11Tests was still running when wall clock hit the 15-min ceiling on the whole job |
| 26056033436 (release PR) | 10:19 (xcodebuild exited code 65) | xcodebuild completed the suite, reported 32 failures, exit 65 | Same suite, slightly faster runner, just barely under the timeout |

So in one case xcodebuild was cancelled mid-test; in the other it finished. **Same root cause, different cutoff against the same 15-min wall.**

### What's actually slow

`c11Tests` runs 1,841 cases in 462s (mean 0.251s). Single outlier:

```
2026-05-18T19:49:27.99Z Test Case '-[c11Tests.AppDelegateShortcutRoutingTests
  testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView]' passed (104.741 seconds).
```

Earlier run: the same test took 123.168s. 22% of total wall time on one method. Next slowest test is 10.5s; everything else is well-behaved. Definition at `c11Tests/AppDelegateShortcutRoutingTests.swift:878-912` — it builds a real main window inside the XCTest-hosted `c11 DEV.app` via `appDelegate.createMainWindow()` (defined `Sources/AppDelegate.swift:6269`) and pumps the run loop. The 50ms `RunLoop.main.run(until:)` is intentional; the other 104 seconds is `createMainWindow` + its matched teardown.

### What's actually failing

Eight distinct `Asynchronous wait failed: Exceeded timeout of 1 seconds` errors visible in the log, expanding into 32 failures in the suite footer. All clustered in host-bound classes:

- `AppDelegateShortcutRoutingTests` (`c11Tests/AppDelegateShortcutRoutingTests.swift:2323`, multiple)
- `GhosttyConfigTests` (`c11Tests/GhosttyConfigTests.swift:1576, 1696`)
- `NotificationBurstCoalescerTests`
- `TabManagerReopenClosedBrowserFocusTests` (`c11Tests/TabManagerUnitTests.swift:974`)
- `TerminalNotificationDirectInteractionTests`
- `BrowserDeveloperToolsVisibilityPersistenceTests`
- `BrowserPanelHostContainerViewTests`

The same names recur across all four post-#164 main builds. These are **flaky-by-budget, not flaky-by-chance** — every `XCTestExpectation` with a 1-second timeout is losing the race on a busy `macos-15-xlarge` shared-tenant runner.

### c11LogicTests is fine

The scheme's `TestAction` runs c11Tests then c11LogicTests sequentially. In the latest run: c11Tests 19:44:22 → 19:53:23 (9:01, 32 failures), c11LogicTests 19:53:30 → 19:54:15 (46 seconds, 0 unexpected failures). The logic suite is not the problem.

### Sparkle is not the test-host hang culprit

The release-chain audit raised a plausible interaction with PR #169 (`132559c90`, "observability: instrument App Hang triggers around Sparkle probe + persistent flash"). I cross-checked: `AppDelegate.swift:2512-2517` — `updateController.startUpdaterIfNeeded()` is in the `if !isRunningUnderXCTest` branch. Sparkle does **not** run during XCTest. That eliminates the most photogenic candidate.

What *does* run unconditionally on the XCTest launch path (`Sources/AppDelegate.swift:2378-2600`, ungated): `LaunchSentinel.recordLaunchAndArchivePrevious`, `SurfaceMetricsSampler.shared.start`, `ThemeManager.shared.startWatchingUserThemes` (FSEvents), `CrashDiagnostics.shared.install` (MetricKit), the full responder-swizzle/GhosttyConfig observer chain (`AppDelegate.swift:2509-2526`), and — explicitly under the `if isRunningUnderXCTest` branch — `TerminalController.shared.start(socketPath: SocketControlSettings.socketPath())` at `:2903-2916`. Section 2 covers why the last item is load-bearing for local-runnability.

### Run-to-run consistency

Same root cause both times. The only difference is whether the test happened to finish 4 seconds before or 4 minutes after the 15-minute ceiling. Variance ~1-3 minutes against a 1-minute margin.

### Files implicated

- `.github/workflows/ci.yml:92` — `timeout-minutes: 15` on `build`
- `.github/workflows/ci.yml:186-203` — test invocation
- `c11Tests/AppDelegateShortcutRoutingTests.swift:878-912` — the 104-second test
- `Sources/AppDelegate.swift:6269` — `createMainWindow(...)` definition
- `Sources/AppDelegate.swift:2378-2600` — launch chain executed under XCTest

---

## 2. Why local `xcodebuild test` kills the operator's c11

This is a separate problem from the CI failures, and one the CLAUDE.md "no local xcodebuild test" rule has been working around since PR #164 (`7e0e0b282`, 2026-05-15). The fix surface is small and worth implementing alongside whatever stabilization happens to c11Tests.

### Socket path resolution

`SocketControlSettings.socketPath(...)` at `Sources/SocketControlSettings.swift:424-463` resolves in priority order:

1. `taggedDebugSocketPath(bundleIdentifier:environment:)` (`:537-566`) — requires either bundle id of the form `com.stage11.c11.debug.<suffix>` *or* bundle id `com.stage11.c11.debug` + `CMUX_TAG` env var.
2. `CMUX_SOCKET_PATH` (`:517-529`) — gated by `CMUX_ALLOW_SOCKET_OVERRIDE` for stable/nightly; auto-allowed for debug bundle ids.
3. `defaultSocketPath` (`:465-487`) — `/tmp/c11-debug.sock` for any debug-like bundle id; `~/Library/Application Support/c11/c11-<uid>.sock` for stable; etc.

### Why the test host hits `/tmp/c11-debug.sock`

`xcodebuild test -scheme c11-unit` launches the XCTest host as the **untagged** `c11 DEV.app` (bundle id `com.stage11.c11.debug`, per `scripts/reload.sh:349-405` which only mutates the bundle id for *tagged* copies). The test process inherits a vanilla `xcodebuild` environment with no `CMUX_TAG` and no `CMUX_SOCKET_PATH`. So:

- `taggedDebugSocketPath` → nil
- `CMUX_SOCKET_PATH` → unset
- `defaultSocketPath` → **`/tmp/c11-debug.sock`**

Then `AppDelegate.applicationDidFinishLaunching` reaches the XCTest-gated branch at `Sources/AppDelegate.swift:2903-2916` and calls `TerminalController.shared.start(socketPath: SocketControlSettings.socketPath(), ...)`. The test host now owns `/tmp/c11-debug.sock`.

If the operator is running an untagged `c11 DEV.app` (the default development workflow), that socket is theirs. The test host either fights for the path or evicts the listener; on test-host teardown the socket file is `unlink()`'d, killing the operator's c11 socket even if the process survives.

### Why the *production* c11 is safe

I verified the operator's current socket landscape:

```
/Users/atin/Library/Application Support/c11mux/c11.sock   ← /Applications/c11.app (production, bundle id com.stage11.c11)
/tmp/c11-debug.sock                                       ← any untagged DEV.app
/tmp/c11-debug-help-about.sock                            ← tagged debug build
```

The production-signed `/Applications/c11.app` (bundle id `com.stage11.c11`) uses the `~/Library/Application Support/c11/` path. The test host's untagged debug bundle resolves to a different path and never touches it. So if the operator is running the released `c11.app` while iterating on tests, there is no collision. The CLAUDE.md rule and the PR #164 incident are about the (common) case where the operator is also running `c11 DEV.app` — which is most development setups.

### Fix surface

Ranked by leverage:

**A. Runtime guard in `socketPath()` (recommended).** In `Sources/SocketControlSettings.swift:438-462`, when about to return `/tmp/c11-debug.sock` and `XCTestConfigurationFilePath` is in the environment, fall back to a per-PID path (e.g. `/tmp/c11-test-\(getpid()).sock`). One file, ~6 lines, testable in `c11LogicTests`. Makes "don't break the operator's c11 under any xctest invocation" a property of the binary, not something each scheme has to remember.

**B. Scheme `EnvironmentVariables` on the `c11-unit` TestAction.** Edit `GhosttyTabs.xcodeproj/xcshareddata/xcschemes/c11-unit.xcscheme` to inject `CMUX_TAG=local-xctest` (or `CMUX_SOCKET_PATH=/tmp/c11-test-$(USER).sock` + `CMUX_ALLOW_SOCKET_OVERRIDE=1`) into the test host. The scheme already has `shouldUseLaunchSchemeArgsEnv="YES"`. Useful belt-and-braces alongside A.

**C. Sibling scheme `c11-unit-local`.** Clone `c11-unit.xcscheme`, add the env-var block, leave the CI scheme untouched. Lets `make test-local` drive a safe local run while CI keeps the no-env scheme. Useful if you don't want to alter the scheme CI uses.

**D. Wrapper script `scripts/test-unit-local.sh`.** Export `CMUX_TAG="$(whoami)-xctest-$$"` and invoke xcodebuild. Lighter than a new scheme; pairs well with A.

A + B is the minimal robust combo. A defends against forgetting the scheme; B keeps the scheme self-documenting.

### `-only-testing` does not help

The 22-second-plus launch cost is paid in `applicationDidFinishLaunching` regardless of how many test methods are selected. Even `-only-testing:c11Tests/AgentRestartRegistryTests/testFoo` still spawns the full untagged DEV.app, still binds `/tmp/c11-debug.sock`, still clobbers the operator. Logic-only subsets already live in `c11LogicTests` (scheme `c11-logic`); that's the existing answer for local iteration on parsers / snapshots / persistence / mailbox / theme code.

---

## 3. Workflow inventory and health

Nine workflows in `.github/workflows/`. Status as of 2026-05-18:

| Workflow | Runs on | Trigger | Last 5 health | Notes |
|---|---|---|---|---|
| `ci.yml` | macos-15-xlarge (build) + ubuntu (sidecars) | push/PR | **Red** (50+ consecutive) | The c11Tests failure above. Sidecar jobs (`workflow-guard-tests`, `web-typecheck`, `remote-daemon-tests`) all green. |
| `release.yml` | macos-15-xlarge | tag `v*`, `workflow_dispatch` | **Green** (v0.48.0, v0.47.1, v0.47.0, v0.46.0) | The healthy path. Section 4 covers it. |
| `build-ghosttykit.yml` | macos-15 | push/PR (paths-ignore docs) | **Green** | Skips on existing release. Pushes a checksum-pinning commit back. Correctly uses `ref: ${{ github.head_ref || github.ref_name }}` on checkout. |
| `nightly.yml` | macos-15-xlarge | `schedule: 0 10 * * *` + dispatch | **Red 15+ days** (since 2026-05-04) | One-line fix — see P0 #2 below. |
| `update-homebrew.yml` | ubuntu-latest | `workflow_run` on Release | **Green** (post-v0.48.0 ran 26056759441) | Uses `workflow_run` not `release: published` to dodge asset-upload race. No `timeout-minutes` cap (falls back to 6h). |
| `ci-macos-compat.yml` | macos-15 (matrix; macos-26 row commented out) | push/PR | **Green** | Single-row matrix today. |
| `mailbox-parity.yml` | ubuntu (python) + macos-15-xlarge | push/PR scoped to mailbox paths | **Green** | Runs 10 `-only-testing:c11LogicTests/Mailbox*` slices against the host-free logic scheme. Good model for what host-bound CI could look like once stabilized. |
| `test-e2e.yml` | macos-15 (or 14) | `workflow_dispatch` only | **Red** (last 3 attempts, April 2026) | Still hardcodes `cmuxUITests` scheme (`test-e2e.yml:212` — `-only-testing:cmuxUITests/...`). Bit-rotting. |
| `claude.yml` | (unspecified) | issue/PR comment containing `@claude` | Never invoked | References missing `CLAUDE_CODE_OAUTH_TOKEN` secret. Only workflow with floating-tag action pins (`actions/checkout@v6`, `anthropics/claude-code-action@v1`). |

### DAG

```
push main / PR (paths-ignore: docs/md/xcstrings)
  ├─ ci.yml (build + tests)                  [red 50+ runs]
  ├─ build-ghosttykit.yml (cond.)            [green; may push checksum commit]
  ├─ ci-macos-compat.yml (smoke)             [green]
  └─ mailbox-parity.yml (if mailbox paths)   [green]

schedule 10:00 UTC
  └─ nightly.yml                             [red 15 consecutive; no publish since 2026-05-04]

push tag v*
  └─ release.yml                             [green; v0.48.0 shipped clean]
       └─ workflow_run completed
            └─ update-homebrew.yml           [green]

ghostty submodule SHA change
  └─ build-ghosttykit.yml                    [run 1 red guards by design; run 2 green]

@claude in issue/PR
  └─ claude.yml                              [will hard-fail: missing token]

workflow_dispatch
  └─ test-e2e.yml                            [bit-rotted]
```

### Cross-cutting

- **Floating action tags only in `claude.yml`** (`@v6`, `@v1`). Every other workflow is SHA-pinned and `workflow-guard-tests` validates the surfaces that gate releases (`ci.yml:30-46`). Claude.yml isn't covered.
- **`GHOSTTY_RELEASE_TOKEN` references — none in `.github/`.** Clean (CLAUDE.md warning is being honored).
- **Push-back checkout `ref` discipline — good.** `build-ghosttykit.yml:35` uses `${{ github.head_ref || github.ref_name }}` for its checksum-pin push. `update-homebrew.yml` pushes to a different repo. `nightly.yml`'s force-tag push uses `needs.decide.outputs.head_sha`.
- **Fork-safety guards in place** on every paid-runner workflow firing on PRs (`ci.yml:90`, `build-ghosttykit.yml:25`, `mailbox-parity.yml:66`, `ci-macos-compat.yml:26`).
- **Cache slot integrity.** When CI's build job hits the test-step timeout, the post-`actions/cache` steps are marked `skipped`. `actions/cache` only saves on job success, so caches don't refresh during a red streak — but they don't leak slots either. Symptom is degrading hit rate over a long red period, not catastrophic.

---

## 4. Release / signing / Sparkle / Homebrew

The chain that shipped v0.48.0 cleanly:

```
git push v0.48.0
  ↓
release.yml on macos-15-xlarge (timeout-minutes: 60)
  ├─ release_asset_guard.js (skip-all / partial-fail / clear)
  ├─ Select Xcode, install zig 0.15.2 + create-dmg 8.0
  ├─ download-prebuilt-ghosttykit.sh (pinned to scripts/ghosttykit-checksums.txt)
  ├─ Derive Sparkle public key from SPARKLE_PRIVATE_KEY
  ├─ xcodebuild scheme=c11 Release CODE_SIGNING_ALLOWED=NO
  ├─ build_remote_daemon_release_assets.sh + inject Info.plist manifest
  ├─ CLI version-memory guard regression
  ├─ Inject SUPublicEDKey + SUFeedURL into Info.plist
  ├─ Import APPLE_CERTIFICATE_BASE64 into ephemeral keychain
  ├─ codesign CLI + ghostty helper + deep app, --verify
  ├─ notarytool submit app.zip --wait → staple → spctl
  ├─ create-dmg --identity=$APPLE_SIGNING_IDENTITY (signed DMG)
  ├─ notarytool submit DMG --wait → staple DMG
  ├─ sentry-cli debug-files upload  (continue-on-error: true)
  ├─ sparkle_generate_appcast.sh (clones Sparkle 2.8.1 from source)
  └─ softprops/action-gh-release upload (DMG + appcast + d11d-* + manifest)

  ↓ workflow_run completed=success
update-homebrew.yml on ubuntu-latest
  ├─ Extract version from workflow_run.head_branch
  ├─ Curl DMG with 5×30s retry; sha256
  ├─ Checkout Stage-11-Agentics/homebrew-c11 via HOMEBREW_TAP_TOKEN
  ├─ Rewrite Casks/c11.rb via heredoc
  ├─ Self-consistency check: regrep cask SHA == actual shasum (gate)
  └─ git push main
```

### Required secrets

| Secret | Used | Failure mode |
|---|---|---|
| `SPARKLE_PRIVATE_KEY` | `release.yml:145, :317` | Loud (`[ -z ... ] && exit 1` in two steps) |
| `APPLE_CERTIFICATE_BASE64` | `release.yml:211-218` | Loud |
| `APPLE_CERTIFICATE_PASSWORD` | `release.yml:212` | Loud |
| `APPLE_SIGNING_IDENTITY` | `release.yml:235, :260` | Loud |
| `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD` / `APPLE_TEAM_ID` | `release.yml:257-259` | Loud |
| `SENTRY_AUTH_TOKEN` | `release.yml:303` | **Silent skip** by design (`continue-on-error: true` + empty-token short-circuit) |
| `HOMEBREW_TAP_TOKEN` | `update-homebrew.yml:83` | Loud-ish (checkout fails on bad token) |
| `GHOSTTY_RELEASE_TOKEN` | **not referenced** | n/a |

### Universal binary — confirmed shipping

The release agent's first-pass P0 flagged `release.yml` for missing `ARCHS="arm64 x86_64"` (which nightly.yml has at `:209-217`). I downloaded the actual shipped DMG and ran `lipo`:

```
$ hdiutil attach /tmp/c11-v0.48.0.dmg ...
$ lipo -archs /tmp/c11-v0.48.0-mount/c11.app/Contents/MacOS/c11
x86_64 arm64
```

Universal. The Xcode project has `ONLY_ACTIVE_ARCH = NO` for Release configs and `ARCHS = $(ARCHS_STANDARD)` (which expands to `arm64 x86_64` on macOS 15). So `release.yml`'s bare `xcodebuild` is fine. Difference vs `nightly.yml` is belt-and-braces, not a bug. **Downgraded from P0 to P3 / "make consistent for clarity."**

### Release asset guard

`scripts/release_asset_guard.js` (47 lines) hardcodes eight immutable asset names (lines 3-12: `c11-macos.dmg`, `appcast.xml`, four `c11d-remote-*` binaries, `c11d-remote-checksums.txt`, `c11d-remote-manifest.json`). Three states:

- **CLEAR** (no overlap with the release's existing assets): proceed.
- **COMPLETE** (all 8 present): `shouldSkipBuildAndUpload = true`. Noop the run.
- **PARTIAL** (some present, some missing): `core.setFailed(...)` with conflict/missing lists, forcing manual resolution.

This is the protection against accidentally re-signing a shipped tag with a different timestamp/cert (which would silently break cached downloads and the Homebrew SHA gate). Worked correctly for v0.48.0.

### Sparkle appcast

- Appcast is shipped as a release asset, not GitHub Pages.
- `SUFeedURL` resolution chain in `Sources/Update/UpdateDelegate.swift:20-37`: env override → bundled Info.plist value → fallback constant at line 5. All three paths point at `https://github.com/Stage-11-Agentics/c11/releases/latest/download/appcast.xml`. No `manaflow-ai/cmux` URLs reachable from runtime code.
- PR #153 (`1e8cae2ae`) fixed `scripts/bump-version.sh:28` to curl `Stage-11-Agentics/c11/releases/latest/download/appcast.xml` for the Sparkle floor. Without that, a developer bumping locally could ship a build number below what's already published and Sparkle clients would refuse the "downgrade." Still **best-effort** — `curl --max-time 8` and a silent regex match. Worth tightening (see P1 #2).
- `scripts/sparkle_generate_appcast.sh` clones `sparkle-project/Sparkle` and builds `generate_appcast` + `sign_update` from source on every release (~2 min). Brittle if sparkle-project goes down or the 2.8.1 tag moves.

### Sparkle observability (PR #169)

`Sources/Update/UpdateController.swift:141-169` schedules a `Timer.scheduledTimer` for hourly appcast checks. Standard `Timer` → main run loop. `updater.checkForUpdateInformation()` is a Sparkle main-thread API. The PR added `sentryBreadcrumb("update.background_probe.tick", ...)` to disambiguate the C11-1 production hang (which appears in SwiftUI AttributeGraph frames, not Sparkle frames).

For the test-host hang specifically: **not interacting** — `updateController.startUpdaterIfNeeded()` is XCTest-gated (`AppDelegate.swift:2516` inside the `!isRunningUnderXCTest` branch at `:2512`). The hourly probe doesn't run in CI. The C11-1 production hang is a separate, real concern.

### Submodule discipline

`git submodule status` from repo root:

| Submodule | Current SHA | On remote `main`? |
|---|---|---|
| `ghostty` | `b4ef0ac2` | Yes (verified via `git merge-base --is-ancestor HEAD stage11/main`) |
| `vendor/bonsplit` | `f765de29` | Yes |
| `homebrew-c11` | `4d9ea33d` | Yes |

The "push submodule before parent" rule was followed for v0.48.0. **Gap:** `release.yml` has no pre-build guard that verifies submodule reachability — a parent commit pointing at an unpushed submodule SHA would fail loudly at `actions/checkout` ("fatal: reference is not a tree"), but only after CI starts. Worth a local pre-push hook (P2).

**Documentation drift:** in the `ghostty` submodule, `origin` is `manaflow-ai/ghostty` and the fork is on `stage11`. CLAUDE.md says push to `manaflow` (a remote name that doesn't exist in this checkout). SHAs land on the right fork; the docs and remote names are out of sync. Quick fix.

---

## 5. Prioritized fixes

### P0 — must fix to make the next release sane

**1. The 32 failing tests in c11Tests.** These are real `XCTestExpectation` 1-second timeouts losing races on shared-tenant CI runners. Two parallel moves:

   - **Triage the failure list.** Pull the names from any of the last 4 CI runs and decide per-test: (a) raise expectation timeout, (b) replace polling for a deterministic notification, (c) quarantine via `XCTSkip`, (d) move to `c11LogicTests` if the test doesn't actually need the host. The reality is most of these probably should be 5-10s timeouts; 1s assumes a much quieter runner than `macos-15-xlarge`-shared.
   - **Quarantine `testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView` with `XCTSkip` while diagnosing.** Removing that one test alone cuts the step from 10:19 to ~8:30 — comfortable margin against the 15-min ceiling — and lets the 32 expectation failures become the conversation. Add a TODO referencing the test back; don't lose it. File: `c11Tests/AppDelegateShortcutRoutingTests.swift:878`.

**2. Bump `ci.yml` build-job `timeout-minutes` from 15 → 25** as a stop-gap. Today's runtime is 3:30 build + 9-10 min tests + 1-2 min GitHub overhead → 14-16 min. The race against 15 is the proximate cause of the "hang" framing. 25 is a comfortable margin without masking a real regression — anything taking 25 min *is* genuinely broken. File: `.github/workflows/ci.yml:92`.

**3. Restore nightly publishing (one-line fix).** `nightly.yml:459` lacks `continue-on-error: true` on the `Upload dSYMs to Sentry` step. `release.yml:301` has it. Result: 15 consecutive nightly runs have failed at the Sentry step, skipping all subsequent publish steps (Sparkle appcast, artifact upload, `Move nightly tag`, `Publish nightly release assets`). No nightly published since 2026-05-04.

   Patch sketch:
   ```diff
    - name: Upload dSYMs to Sentry
      if: needs.decide.outputs.should_publish != 'true' || ...
   +  continue-on-error: true
      env:
        SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}
   ```

   File: `.github/workflows/nightly.yml:459-461`.

### P1 — should fix before the next stretch of release work

**4. Split the c11-unit CI step into two stages.** Keep `c11-logic` as a hard-fail gate; treat the host-bound `c11-unit` as advisory while stabilization is in flight. The point is to keep a *useful* signal green on every PR rather than dragging everyone past a red ✕ that's expected to be red.

   ```yaml
   - name: Logic tests (gate)
     run: xcodebuild ... -scheme c11-logic test
   - name: Host-bound unit tests (advisory)
     continue-on-error: true
     run: xcodebuild ... -scheme c11-unit -only-testing:c11Tests test
   ```

   File: `.github/workflows/ci.yml:186-203`. (Splits because `c11-unit` runs c11LogicTests too, but you don't want to run logic twice.)

**5. Make local `xcodebuild test` safe — runtime guard.** In `Sources/SocketControlSettings.swift:438-462`, add a fall-through after the existing branches: if `XCTestConfigurationFilePath` is in the environment and the resolver would otherwise return `/tmp/c11-debug.sock`, return `/tmp/c11-test-\(getpid()).sock` instead. Six lines, one test in `c11LogicTests`. Makes the "don't run xcodebuild test locally" rule unnecessary; CLAUDE.md can drop it after this lands.

**6. Add scheme env var as belt-and-braces.** In `GhosttyTabs.xcodeproj/xcshareddata/xcschemes/c11-unit.xcscheme`, add `<EnvironmentVariables>` to the `<TestAction>`:
   ```xml
   <EnvironmentVariables>
     <EnvironmentVariable key="CMUX_TAG" value="local-xctest" isEnabled="YES"/>
   </EnvironmentVariables>
   ```
   Self-documenting; survives if anyone bypasses the runtime guard.

**7. `bump-version.sh` Sparkle-floor curl is best-effort.** `scripts/bump-version.sh:28` uses `curl --max-time 8` and silently falls back to `LATEST_RELEASE_BUILD=""` on any failure. On a flaky network during a tag-bound bump, the bumped build number is `local + 1` — which (in the scenario PR #153 was supposed to prevent) might be lower than the published Sparkle floor. Hard-fail when the bump is for a release tag.

**8. `claude.yml` — pin floating tags or delete.** `actions/checkout@v6` and `anthropics/claude-code-action@v1` are the only floating pins in the repo. If `@claude` isn't actively used, deleting is cleaner than keeping a workflow that depends on a missing `CLAUDE_CODE_OAUTH_TOKEN` secret. If it is used, pin the actions to SHAs and add the secret.

**9. `test-e2e.yml` — rename or delete.** `test-e2e.yml:212` references `cmuxUITests` scheme (an artifact of the cmux→c11 rename). Last 3 dispatches failed. Either fix the scheme name and the test-host launch path, or delete.

### P2 — cleanup

**10. `update-homebrew.yml` — add `timeout-minutes: 10`.** Currently inherits the GitHub 6-hour default. Low-impact; prevents a future hang from sitting silently.

**11. `update-homebrew.yml` — the SHA "gate" is self-referential.** Lines 131-140 re-shasum the same file the previous step just downloaded and computed `$SHA256` from. The gate confirms heredoc-substitution correctness, not download integrity (which is gated by the 5-retry size/HTTP loop above). Either rename the step comment ("Verify heredoc substitution") or re-fetch from `releases/download/...` to make it a real integrity check.

**12. `sparkle_generate_appcast.sh` defaults to `manaflow-ai/cmux`.** Lines 19-20 fall back to upstream URLs if `DOWNLOAD_URL_PREFIX` / `RELEASE_NOTES_URL` aren't exported. release.yml does export them, but a human regenerating an appcast locally would silently write the wrong URL. Flip the defaults to `Stage-11-Agentics/c11` or require explicit envs.

**13. `release.yml` could mirror `nightly.yml`'s explicit `ARCHS`/`ONLY_ACTIVE_ARCH` for clarity.** Belt-and-braces — the shipped DMG is universal because of `ONLY_ACTIVE_ARCH = NO` in the pbxproj, but the bare xcodebuild command at `release.yml:158-160` doesn't make this obvious. A reader auditing the workflow has to infer it from the project file.

**14. `cmux.sparkle.automaticChecksMigration.v2` key in `Sources/Update/UpdateController.swift:11`.** Residual `cmux.` prefix in a UserDefaults key, inconsistent with the CLAUDE.md cmux→c11 rename. Carry forward in a future migration cycle (don't rename now without a `cmux.` → `c11.` migration path; live users have the old key set).

**15. Sparkle appcast generator builds from source every release.** `sparkle_generate_appcast.sh:28-47` clones and builds Sparkle 2.8.1. Cache the built binaries on a versioned key.

**16. Release pre-flight: verify submodule SHAs are reachable on remote.** A `git ls-remote --refs <submodule-origin> | grep <SHA>`-style check at the start of `release.yml` would catch the "parent points at unpushed submodule" footgun before the runner starts work. Or a local pre-push hook; either works.

**17. Align ghostty submodule remote naming.** CLAUDE.md says push to `manaflow`, the working remote is `stage11` (pointing at `Stage-11-Agentics/ghostty`). Update CLAUDE.md to match the actual remote layout.

---

## 6. Make tests runnable locally — specific recommendation

The fast path is **two changes** that together let `xcodebuild test -scheme c11-unit` run safely on Hyperion without affecting the operator's c11:

1. Implement P1 #5 (the runtime guard in `Sources/SocketControlSettings.swift`).
2. Until that lands, use this wrapper:

```bash
#!/usr/bin/env bash
# scripts/test-unit-local.sh
set -euo pipefail

# Per-PID socket isolation: keeps the test host out of /tmp/c11-debug.sock
export CMUX_SOCKET_PATH="/tmp/c11-test-${USER}-$$.sock"
export CMUX_ALLOW_SOCKET_OVERRIDE=1
export CMUX_TAG="xctest-${USER}-$$"

exec xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-unit \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build-test-local \
  test "$@"
```

Then:

```bash
chmod +x scripts/test-unit-local.sh
scripts/test-unit-local.sh                       # full c11-unit (c11Tests + c11LogicTests)
scripts/test-unit-local.sh -only-testing:c11Tests/AppDelegateShortcutRoutingTests/testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView
```

The wrapper's env vars push the test host to a per-PID socket path the operator's c11 never touches. The XCTest host still beachballs its own window for ~22s (intrinsic to the launch chain — `LaunchSentinel`, `SurfaceMetricsSampler`, `ThemeManager`, `CrashDiagnostics`, responder swizzles), but the operator's primary c11 is unaffected.

**Diagnostic add-on for the 32 failing tests:** add `-resultBundlePath "$RUNNER_TEMP/c11-unit.xcresult"` to the wrapper and to the CI step, then `xcresulttool get --legacy --format json --path <bundle>` to extract per-test diagnostics, attachments, and the activity log with timestamps. This is what gives you per-frame visibility into the 104-second slow test — sampler-style stack traces inside the XCTest activity log.

To profile the slow test specifically:

```bash
scripts/test-unit-local.sh -only-testing:c11Tests/AppDelegateShortcutRoutingTests/testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView \
  -resultBundlePath /tmp/slow-test.xcresult &
sleep 30  # wait for the test host to be live
sample $(pgrep -n xctest) 5 -file /tmp/c11-unit-sample.txt
```

The sample stack will say whether 100+ seconds is `createMainWindow` (likely SwiftUI scene graph), workspace restore, GhosttyConfig observer chain install, or something else.

---

## 7. Health summary

| Surface | Status | Confidence |
|---|---|---|
| Release / sign / notarize | Healthy | High — v0.48.0 round-trips end-to-end; assets immutable; guard works. |
| Homebrew sync | Healthy | High — cask updated post-v0.48.0; SHA gate works (even if self-referential). |
| Sparkle appcast (stable) | Healthy | High — feed URL correct, signature present, public key derivation works. |
| Sparkle in-app probe | Suspect (production) | Medium — PR #169 instrumentation in place; root cause of C11-1 not yet confirmed. Not a CI issue. |
| Submodule discipline | Healthy at HEAD | High — all three submodule SHAs reachable on remote `main`. |
| build-ghosttykit cache | Healthy | High — checksum-pin workflow round-trips. |
| `ci.yml` build job | Broken | High — 32 real failing tests + 1 slow test + a too-tight timeout. |
| `nightly.yml` publish | Broken (one-line fix) | High — missing `continue-on-error` on Sentry step. |
| `test-e2e.yml` | Bit-rotted | High — wrong scheme name. |
| `claude.yml` | Will fail on first invocation | High — missing secret, floating tags. |
| Local test runnability | Awkward but fixable | High — socket-path resolver + scheme env are the fix surface. |

---

## 8. References

**Failing CI runs:**
- 26056033436 / job 76604384102 — release/v0.48.0 PR (xcodebuild exited; 32 failures)
- 26054336139 / job 76598532322 — release/v0.48.0 PR (timeout-cancelled mid-suite)
- Captured logs: `/tmp/run-latest.log`, `/tmp/run-earlier.log` (on Hyperion)

**Implicated source paths:**
- `c11Tests/AppDelegateShortcutRoutingTests.swift:878-912` — the 104s test
- `c11Tests/AppDelegateShortcutRoutingTests.swift:2323` — first expectation timeout
- `c11Tests/GhosttyConfigTests.swift:1576, 1696` — expectation timeouts
- `c11Tests/TabManagerUnitTests.swift:974` — expectation timeout
- `Sources/AppDelegate.swift:2378-2600` — launch chain (executed under XCTest)
- `Sources/AppDelegate.swift:2486-2517` — `!isRunningUnderXCTest` gating
- `Sources/AppDelegate.swift:2903-2916` — XCTest-only socket start
- `Sources/AppDelegate.swift:6269` — `createMainWindow` (suspect cost center for the slow test)
- `Sources/SocketControlSettings.swift:424-566` — socket path resolver (fix site for P1 #5)
- `Sources/Update/UpdateController.swift:11, 141-169` — Sparkle probe + residual cmux key
- `Sources/Update/UpdateDelegate.swift:5, 20-37` — feed URL resolution

**Workflows:**
- `.github/workflows/ci.yml:92` (timeout), `:186-203` (test step)
- `.github/workflows/release.yml:25-79` (asset guard), `:155-160` (build), `:232-281` (sign + notarize), `:301-312` (Sentry continue-on-error), `:314-325` (appcast generation)
- `.github/workflows/nightly.yml:459-472` (Sentry step missing `continue-on-error`), `:209-217` (universal build)
- `.github/workflows/update-homebrew.yml:6-8` (workflow_run trigger), `:53-76` (DMG fetch), `:131-140` (SHA gate)
- `.github/workflows/build-ghosttykit.yml:35` (push-back checkout ref)
- `.github/workflows/test-e2e.yml:212` (stale `cmuxUITests`)
- `.github/workflows/claude.yml:29, 35` (floating tags), `:37` (missing secret)

**Schemes:**
- `GhosttyTabs.xcodeproj/xcshareddata/xcschemes/c11-logic.xcscheme` (logic-only)
- `GhosttyTabs.xcodeproj/xcshareddata/xcschemes/c11-unit.xcscheme` (host-bound; CI runs this)
- `GhosttyTabs.xcodeproj/xcshareddata/xcschemes/c11-ci.xcscheme` (host-bound + UITests; CI does NOT run this for the unit lane)
- `GhosttyTabs.xcodeproj/project.pbxproj:1118-1196` (targets), `:1816-1895` (test build settings: `TEST_HOST`, `BUNDLE_LOADER`, `LD_RUNPATH_SEARCH_PATHS`)

**Scripts:**
- `scripts/release_asset_guard.js`
- `scripts/sparkle_generate_appcast.sh` (lines 19-20 default URL fallback)
- `scripts/bump-version.sh:28` (Sparkle floor curl)
- `scripts/reload.sh:349-405` (tagged-build isolation)

**Related PRs:**
- #164 (`7e0e0b282`, 2026-05-15) — c11mux drop, triggered the "no local xcodebuild test" rule
- #166 (`b05979184`) — C11-27, split c11Tests into logic + host-bound
- #169 (`132559c90`) — Sparkle observability (production hang instrumentation)
- #153 (`1e8cae2ae`) — bump-version Sparkle floor at Stage-11-Agentics/c11
- #173 (`65946495a`) — default-agent env var + skill rewrite (latest main)

---

*Audit produced 2026-05-18 by Claude (Opus 4.7) against c11 @ 66044e1b1 (release/v0.48.0 + main post-merge). No code changed in this session; per instructions, report-only.*
