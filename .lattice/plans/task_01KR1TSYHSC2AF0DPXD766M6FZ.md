# C11-35: c11Tests runtime failures: 4 latent regressions surfaced by compile unblock

## Summary

PR #145 unblocks the c11Tests target compilation (broken since ~PR #123 because no CI workflow built the unit-test target). Once it compiles, **4 tests fail at runtime** — latent regressions in production code that weren't caught because the target didn't compile.

These are real source-code regressions, not test bugs. Each needs investigation against the production code path it covers.

## Failing tests

### 1. `ThemeManagerLifecycleTests.testDividerColorRoleResolvesAgainstWorkspaceColor` (line 106)

```
XCTAssertNotNil failed
```

When `workspaceColor: nil`, `manager.resolve(.dividers_color, context:)` returns nil. Test asserts: "Without a workspace color, \$workspaceColor falls back to theme defaults; still returns a color."

**Hypothesis:** The fallback path for `\$workspaceColor` formula in dividers_color was changed or removed; the test still expects the old behavior.

### 2. `TomlSubsetParserTests.testParsesStringEscapes`

Failure details not captured in the run log; needs full xctest output.

### 3 + 4. `WorkspaceBlueprintStoreTests.testMDExtensionFilesAreAcceptedByPerUserBlueprintURLs` (line 221) + `testMDExtensionRoundTripsThroughStoreReadWrite`

```
XCTAssertEqual failed: ("Optional(\"blueprint\")") is not equal to ("Optional(\"Markdown Extension\")")
```

The store reads back a blueprint's `title` as "blueprint" (presumably the filename stem) instead of "Markdown Extension" (the field value the test wrote). The .md-extension code path in WorkspaceBlueprintStore appears to not be parsing the markdown frontmatter title field.

## Out of scope

PR #145 ships only the compile fixes + a CI guard that runs `xcodebuild build-for-testing -scheme c11-unit` (compile, no execution). Once these 4 runtime failures are resolved, the CI guard can be promoted from `build-for-testing` to `test` to gate on green tests too.

## Acceptance

- All 4 tests pass.
- The `Compile c11Tests target` CI step in ci.yml gets upgraded from `build-for-testing` to `test` (gate on actual test execution, not just compilation).

## Discovery context

PR #145 (Skip legacy-prefs migration on debug bundle ids) needed to add a new c11Tests file. That file couldn't compile because OTHER c11Tests files didn't compile. While unblocking the compile path, ran the touched test classes and found these 4 runtime failures. Most existing c11Tests classes pass — these 4 are the surfaced regressions.
