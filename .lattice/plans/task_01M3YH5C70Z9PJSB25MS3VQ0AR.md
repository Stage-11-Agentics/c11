# C11-314: delete recorded flaky tests

Atin, 2026-10-02: delete flaky tests. No product code. No new tests.

## Recorded cases (c11 1.0 run only)

Delete these methods. Each was red on an unrelated PR or on main controls:

- `WorkspaceRemoteConnectionTests.testRemoteRelayMetadataCleanupScriptPreservesDifferentSocketAddr` — GitHub CI, C11-306 head, `XCTAssertFalse` after 31.3s (C11-306 comment ev_01M3XMZXYGZJC0KVWGEZDG3S7K).
- `WorkspaceRemoteConnectionTests.testRemoteRelayMetadataCleanupScriptRemovesMatchingSocketAddr` — hosted build, C11-263, same assertion after 31.512s (C11-263 comment ev_01M3XSRZ7900E8X6HASDEYMVRY). Same 30s shell hang-guard as its pair.
- `WorkspaceRemoteConnectionTests.testRemoteCommandIsRefusedAfterSuccessfulHandshake` — Atlas logic gate, C11-306, `XCTAssertFalse` after 16.0s (same C11-306 comment).
- `WorkspaceRemoteConnectionTests.testProxyOnlyErrorsKeepSSHWorkspaceConnectedAndLoggedInSidebar` — crashed both Atlas class controls on main (`GhosttyTerminalView` nil unwrap). Named in ev_01M3XMWMYX81JK2SYQHXAXYYVS. Ticket text includes those crashes.
- `MessagesPageTests.testWriterMaxWaitRunsDuringSteadyTraffic` — Batch 2, 30ms `wait` under load (run-state 00:14). One later retry passed. Still the recorded timing flake.

Search of run-state and October ticket comments found no other test recorded as flaky. `ShellGitWatcherTests` PermissionError was waived onto C11-305 and fixed forward (PR 521 merged). `SocketControlPasswordStoreTests` is the Keychain-over-SSH environment exclusion, not a recorded flake. Older flakes (C11-109, C11-170, C11-247) are outside this run.

## Files

- `c11Tests/WorkspaceRemoteConnectionTests.swift`
  - Delete the four methods above.
  - Delete `ProcessRunResult` and `runProcess` (only those timing cases use them) and `import Network` (only the handshake case uses it).
  - Keep `testRemoteCommandRelayDoesNotStartListener` (already deterministic: `start()` throws the ssh-unavailable message, no wait).
  - Keep `testSSHAgentEnvVarsPropagateToSpawnedProcess` (not recorded as flaky; no wall-clock assertion).
- `c11Tests/MessagesPageTests.swift`
  - Delete `testWriterMaxWaitRunsDuringSteadyTraffic` only.

- `c11Tests/SocketControlPasswordStoreTests.swift`
  - Not a recorded flake. Do not delete it.
  - Three lazy-keychain cases pass `fileURL: nil`, so `loadPassword` reads the build host's socket-password file, returns that password, and never calls the injected loader. That is the Atlas exclusion (deterministic on a host that has the file). Point those calls at a missing file so the loader assertions stay hermetic. No product change.

No other file. The Atlas skips are command-line flags, not repo config. Proof omits both `-skip-testing` flags. No product, skill, localization, persistence, or hot-path change.

## Coverage that already exists

- Relay start refusal: `testRemoteCommandRelayDoesNotStartListener` stays.
- No existing non-timing test covers cleanup-script matching vs preserve, post-handshake command refusal, proxy-only sidebar state, or max-wait under steady traffic. Those behaviors are deleted outright. Do not add replacements.

## Acceptance

1. Recorded flake methods are gone. Incident: the four remote failures plus the 30ms messages wait, citations above. Proof: full `c11LogicTests` on Atlas runs the remaining `WorkspaceRemoteConnectionTests` (class not skipped) and passes.
2. No product diff. Proof: `git diff --stat` against origin/main is only the two test files.
3. Logic suite passes on Atlas with neither exclusion (`SocketControlPasswordStoreTests`, `WorkspaceRemoteConnectionTests`). Command: `scripts/remote-build.sh --tag c11-314-flaky --mode test -- -only-testing:c11LogicTests`. Validator scenario is that command: expected `TEST SUCCEEDED`, zero failures, both classes executed.

## Cut line

No product change, no new tests, no CI skip-list edit, no skill sync, no ShellGitWatcher deletion, no Keychain-test deletion. The only password-store edit is the missing-file URL on the three cases that read the host file.

## Dependencies

None. Not on the pre-merge runtime-risk list. The seat brief still requires this Atlas logic proof before handoff.
