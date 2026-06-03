# C11-100: Local test runnability: socket isolation under XCTest

Make `xcodebuild test -scheme c11-unit` safe to run on the operator's Hyperion without stomping their primary c11. Parent: C11-98.

**Root cause** (from audit): the XCTest host launches an untagged `c11 DEV.app` whose bundle id is `com.stage11.c11.debug`. `SocketControlSettings.socketPath()` resolves that to `/tmp/c11-debug.sock` — the same path any debug build the operator is running uses. The test host's `applicationDidFinishLaunching` calls `TerminalController.shared.start(socketPath: ...)` at `Sources/AppDelegate.swift:2903-2916` under XCTest, binding (and on teardown, unlinking) that socket.

**Changes**
1. **Runtime guard** in `Sources/SocketControlSettings.swift:438-462`. After existing branches: if `XCTestConfigurationFilePath` is in env and the resolver would return `/tmp/c11-debug.sock`, return `/tmp/c11-test-\(getpid()).sock` instead. ~6 lines + a test in `c11LogicTests`.
2. **Scheme env var** in `GhosttyTabs.xcodeproj/xcshareddata/xcschemes/c11-unit.xcscheme` TestAction:
   ```xml
   <EnvironmentVariables>
     <EnvironmentVariable key="CMUX_TAG" value="local-xctest" isEnabled="YES"/>
   </EnvironmentVariables>
   ```
   Belt-and-braces; self-documents the isolation.
3. **Wrapper script** `scripts/test-unit-local.sh` (recipe in audit section 6): exports `CMUX_SOCKET_PATH=/tmp/c11-test-${USER}-$$.sock`, `CMUX_ALLOW_SOCKET_OVERRIDE=1`, `CMUX_TAG=xctest-${USER}-$$`, then execs `xcodebuild test`.
4. **Drop the rule.** Update `code/c11/CLAUDE.md` to remove "Don't run xcodebuild test on c11 locally" + the PR #164 reference. Replace with: "Use `scripts/test-unit-local.sh` for local c11-unit iteration."

**Acceptance**
- Operator can run `scripts/test-unit-local.sh` on Hyperion with `/Applications/c11.app` *and* a `c11 DEV.app` running, and neither dies
- The new c11LogicTests case verifies the socket path is per-PID under XCTest
- CLAUDE.md no longer mentions the prohibition

**Not blocking** the stabilization ticket but should land before it; lets the stabilization owner iterate locally.
