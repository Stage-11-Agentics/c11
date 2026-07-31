# C11-189 implementation evidence

- Commit: `2cdc466c04e8cf6a3e1f40e966928ebeb4743305` (`2cdc466c0`)
- Branch: `fix/c11-189-notify-guard`
- PR: https://github.com/Stage-11-Agentics/c11/pull/399
- Review artifact: `art_01KYWPGESTK1X6F5Q5YHK7VDVB` (`PASS`, created 2026-07-31T18:20:43Z)

## Changed paths
- `CLI/c11.swift`
- `Resources/bin/codex`
- `Sources/SocketHandlers/NotificationHandlers.swift`
- `c11Tests/NotificationAndMenuBarTests.swift`
- `tests/test_codex_wrapper_hooks.py`

## Local verification
- `python3 tests/test_codex_wrapper_hooks.py` -> PASS
- `git diff --check` -> clean
- Local `xcodebuild` not run per ticket guardrail; Swift compile/test proof deferred to CI

## Acceptance criteria status
- AC1: covered by `testLegacyCodexNotifyMismatchDoesNotMutateAttention` plus payload-forwarding wrapper regression; mismatched child callbacks on a runtime-captured root surface leave notifications empty, waiting edges empty, and activity `working`
- AC2: covered by `testLegacyCodexNotifyMatchKeepsCurrentCompletionBehavior`; matching thread-id still creates the notification, emits waiting, and settles activity to `idle`
- AC3: covered by `testLegacyCodexNotifyWithoutRuntimeCaptureFallsBackToCurrentBehavior`; uncaptured surfaces keep pre-guard behavior
- AC4: pending operator computer-use approval for the tagged-build smoke check

## CI status at attach time (Friday, July 31, 2026)
- PR #399 open
- `build` check in progress
- `drawbridge-review` check in progress
