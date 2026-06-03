Shipped scripts/reloads.sh changes for items 1, 2, 4, 5 from the v0.49.0 staging chat. Item 3 (skipPackagePluginValidation + skipMacroValidation) was deliberately dropped per operator.

Changes (one commit per item):
- Item 4: COMPILER_INDEX_STORE_ENABLE=NO unconditionally.
- Item 5: SWIFT_COMPILATION_MODE=incremental by default; --wmo opt-out for prod parity.
- Item 1: ARCHS=arm64 ONLY_ACTIVE_ARCH=YES by default; --universal opt-out.
- Item 2: derived-data path keys on tag family (prefix-up-to-first-hyphen); --clean flag; .last-sha/.last-tag breadcrumb files printed on reuse.
- Plus: echo xcodebuild invocation before running it (useful diagnostic).

Wall-clock validated on M4 Max: cold 6m3s, warm 15s, cold-after-clean 2m45s. --universal/--wmo verified via mocked-xcodebuild dry-run (full builds skipped to avoid foreground churn while operator's v0.49.0 staging was being hand-tested).

PR: https://github.com/Stage-11-Agentics/c11/pull/189 (against main).

CI release.yml and nightly.yml untouched.

Follow-up not in this PR: same wins could be lifted to scripts/reload.sh (Debug script).